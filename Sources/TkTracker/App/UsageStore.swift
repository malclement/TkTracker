import SwiftUI
import Observation
import ServiceManagement

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case cost, tokens, block, icon
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cost: return "Today's cost"
        case .tokens: return "Today's tokens"
        case .block: return "Current 5h block"
        case .icon: return "Icon only"
        }
    }
}

@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var stats: DashboardStats = .empty
    private(set) var colorScale = ModelColorScale(palette: [])
    private(set) var isScanning = false
    private(set) var hasScanned = false
    /// Result of the last scan — surfaced in the UI when something went wrong,
    /// and dumped verbatim by Settings → Copy diagnostics.
    private(set) var scanHealth = ScanHealth()

    var range: StatsRange {
        didSet {
            UserDefaults.standard.set(range.rawValue, forKey: "range")
            rebuild()
        }
    }

    var menuBarDisplay: MenuBarDisplay {
        didSet { UserDefaults.standard.set(menuBarDisplay.rawValue, forKey: "menuBarDisplay") }
    }

    /// Blend Claude Code's aggregate stats cache in for the period whose
    /// transcripts were pruned (estimated, clearly labeled).
    var includeHistory: Bool {
        didSet {
            UserDefaults.standard.set(includeHistory, forKey: "includeHistory")
            rebuild()
        }
    }

    /// Which sources TkTracker scans and shows. Off = not scanned, not shown
    /// (already-cached history stays on disk and returns when re-enabled).
    var trackClaude: Bool {
        didSet {
            UserDefaults.standard.set(trackClaude, forKey: "trackClaude")
            sourcesChanged()
        }
    }

    var trackCodex: Bool {
        didSet {
            UserDefaults.standard.set(trackCodex, forKey: "trackCodex")
            sourcesChanged()
        }
    }

    /// View filter over the tracked sources — one lens for the menu bar figure,
    /// popover, dashboard, CSV export and budget alike.
    var sourceScope: SourceScope {
        didSet {
            UserDefaults.standard.set(sourceScope.rawValue, forKey: "sourceScope")
            rebuild()
        }
    }

    var trackedSources: Set<UsageSource> {
        var set = Set<UsageSource>()
        if trackClaude { set.insert(.claude) }
        if trackCodex { set.insert(.codex) }
        return set.intersection(Set(profiles.filter(\.enabled).map(\.source)))
    }

    /// Sources the UI is currently showing: the scope, clipped to what's
    /// tracked. A scope pointing at an untracked source falls back to all.
    var visibleSources: Set<UsageSource> {
        let visible = sourceScope.sources.intersection(trackedSources)
        return visible.isEmpty ? trackedSources : visible
    }

    /// The scope switcher only earns its place when there is a choice to make:
    /// both sources tracked, and both actually present on this machine (a data
    /// directory or cached history).
    var showsSourceScope: Bool {
        trackClaude && trackCodex && claudePresent && codexPresent
    }

    private var claudePresent = false
    private var codexPresent = false

    /// Daily spend threshold in USD; 0 disables.
    var dailyBudget: Double {
        didSet {
            if !dailyBudget.isFinite || dailyBudget < 0 { dailyBudget = oldValue; return }
            UserDefaults.standard.set(dailyBudget, forKey: "dailyBudget")
        }
    }

    /// Subscription plan, for the allowance gauges and the value multiple.
    /// Defaults to `.none` so no limit is ever shown that the user didn't set.
    var profiles: [SourceProfile] {
        didSet {
            SourceProfile.save(profiles)
            if oldValue.map({ "\($0.id)|\($0.rootPath)|\($0.enabled)" }) == profiles.map({ "\($0.id)|\($0.rootPath)|\($0.enabled)" }) { rebuild(); return }
            quotaSnapshots.removeAll()
            guard started else { return }
            Task {
                apply(await engine.configure(profiles: profiles))
                startWatchers()
                await refreshNow()
            }
        }
    }
    // Compatibility for aggregate intents: an allowance belongs to one account.
    var plan: UsagePlan {
        let visible = profiles.filter { $0.enabled && visibleSources.contains($0.source) }
        return visible.count == 1 ? visible[0].plan : .none
    }
    var reportFilter = ReportFilter() { didSet { rebuild() } }
    var savedFilters: [ReportFilter] = []
    var selectedSession: String?
    var budgetRules: [BudgetRule] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(budgetRules) { UserDefaults.standard.set(data, forKey: "budgetRules") }
            rebuild()
        }
    }
    var budgetProgress: [BudgetProgress] = []
    var anomalyAlerts = UserDefaults.standard.bool(forKey: "anomalyAlerts") {
        didSet { UserDefaults.standard.set(anomalyAlerts, forKey: "anomalyAlerts") }
    }
    var privacyPolicy = PrivacyPolicy.load() {
        didSet {
            if let data = try? JSONEncoder().encode(privacyPolicy) { UserDefaults.standard.set(data, forKey: "privacyPolicy") }
            Task { do { apply(try await engine.applyPrivacy(privacyPolicy)) } catch { operationError = error.localizedDescription } }
        }
    }
    var quotaAlertsEnabled = UserDefaults.standard.bool(forKey: "quotaAlertsEnabled") {
        didSet { UserDefaults.standard.set(quotaAlertsEnabled, forKey: "quotaAlertsEnabled") }
    }
    func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TkTracker-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { try await engine.backup().write(to: url) } catch { operationError = error.localizedDescription } }
    }
    func restoreBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { let backup = try ArchiveBackup.read(url); apply(try await engine.restore(backup)); await refreshNow() }
            catch { operationError = error.localizedDescription }
        }
    }
    var quotaSnapshots: [String: QuotaSnapshot] = [:]
    var quotaError: String?
    var quotaRefreshing = false
    var liveQuotasEnabled = UserDefaults.standard.bool(forKey: "liveQuotasEnabled") {
        didSet {
            UserDefaults.standard.set(liveQuotasEnabled, forKey: "liveQuotasEnabled")
            if liveQuotasEnabled { Task { await refreshQuotas() } }
        }
    }
    var codexExecutable = UserDefaults.standard.string(forKey: "codexExecutable") ?? "/opt/homebrew/bin/codex" {
        didSet { UserDefaults.standard.set(codexExecutable, forKey: "codexExecutable") }
    }
    func refreshQuotas() async {
        guard liveQuotasEnabled, !quotaRefreshing else { return }
        quotaRefreshing = true
        defer { quotaRefreshing = false }
        quotaError = nil
        for profile in profiles where profile.enabled && profile.source == .codex {
            do {
                let snapshot = try await CodexQuotaClient.fetch(executable: URL(fileURLWithPath: codexExecutable), configRoot: profile.root.deletingLastPathComponent())
                guard liveQuotasEnabled else { return }
                quotaSnapshots[profile.id] = snapshot
            } catch { quotaError = error.localizedDescription }
        }
    }
    var operationError: String?
    var allDigests: [FileDigest] { digests }
    var allModels: [String] { Array(Set(digests.flatMap { $0.buckets.map(\.model) })).sorted() }

    func saveCurrentFilter() {
        var copy = reportFilter
        copy.id = UUID().uuidString
        savedFilters.append(copy)
        if let data = try? JSONEncoder().encode(savedFilters) { UserDefaults.standard.set(data, forKey: "savedFilters") }
    }

    /// Opt-in release check. Off by default; see `UpdateChecker`.
    var checksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(checksForUpdates, forKey: "checksForUpdates")
            if checksForUpdates {
                Task { await updateChecker.checkIfDue(enabled: true) }
            } else {
                updateChecker.reset()
            }
        }
    }

    let updateChecker = UpdateChecker()

    /// Today's spend across ALL tracked sources — the budget is a standing
    /// commitment about total spend, so a transient view filter must never
    /// disarm it (the visible `stats.todayCost` follows the filter; this
    /// doesn't).
    private(set) var trackedTodayCost: Double = 0

    var isOverBudget: Bool { dailyBudget > 0 && trackedTodayCost > dailyBudget }

    // Dashboard navigation (project rows drill into the sessions table).
    var dashboardSection: DashboardSection? = .overview
    var sessionSearch = ""

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // Not running from an installed bundle — revert silently.
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var dataRoot: URL { profiles.first { $0.source == .claude }?.root ?? ScanCore.defaultRoot() }
    var codexDataRoot: URL { profiles.first { $0.source == .codex }?.root ?? ScanCore.defaultRoot(for: .codex) }

    private var digests: [FileDigest] = []
    private var historyDigests: [FileDigest] = []
    private let engine = UsageEngine()
    private var watchers: [ProjectsWatcher] = []
    private var started = false
    private var refreshing = false
    private var refreshQueued = false
    private var pendingRefresh: Task<Void, Never>?
    private var minuteLoop: Task<Void, Never>?
    private var minuteCount = 0

    init() {
        let d = UserDefaults.standard
        range = d.string(forKey: "range").flatMap(StatsRange.init(rawValue:)) ?? .today
        menuBarDisplay = d.string(forKey: "menuBarDisplay").flatMap(MenuBarDisplay.init(rawValue:)) ?? .cost
        includeHistory = d.object(forKey: "includeHistory") as? Bool ?? true
        trackClaude = d.object(forKey: "trackClaude") as? Bool ?? true
        trackCodex = d.object(forKey: "trackCodex") as? Bool ?? true
        sourceScope = d.string(forKey: "sourceScope").flatMap(SourceScope.init(rawValue:)) ?? .all
        dailyBudget = d.double(forKey: "dailyBudget")
        profiles = SourceProfile.load(from: d)
        if let data = d.data(forKey: "budgetRules"), let rules = try? JSONDecoder().decode([BudgetRule].self, from: data) { budgetRules = rules }
        if let data = d.data(forKey: "savedFilters"), let saved = try? JSONDecoder().decode([ReportFilter].self, from: data) { savedFilters = saved }
        checksForUpdates = d.bool(forKey: "checksForUpdates") // absent = false = opted out
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var menuBarTitle: String? {
        switch menuBarDisplay {
        case .icon: return nil
        case .cost: return Format.moneyCompact(stats.todayCost)
        case .tokens: return Format.tokens(stats.todayTotals.total)
        case .block:
            guard let block = stats.block, block.isActive else {
                return Format.moneyCompact(stats.todayCost)
            }
            let remaining = Format.durationCompact(block.end.timeIntervalSince(stats.generatedAt))
            return "\(Format.moneyCompact(block.cost)) · \(remaining)"
        }
    }

    /// Spoken form of the menu bar figure — the compact "$4.83 · 2h05" reads as
    /// noise otherwise.
    var menuBarAccessibilityValue: String {
        var parts: [String] = []
        switch menuBarDisplay {
        case .icon:
            parts.append("\(Format.money(stats.todayCost)) today")
        case .cost:
            parts.append("\(Format.money(stats.todayCost)) today")
        case .tokens:
            parts.append("\(Format.tokens(stats.todayTotals.total)) tokens today")
        case .block:
            if let block = stats.block, block.isActive {
                let left = Format.duration(block.end.timeIntervalSince(stats.generatedAt))
                parts.append("\(Format.money(block.cost)) this block, \(left) remaining")
            } else {
                parts.append("\(Format.money(stats.todayCost)) today")
            }
        }
        if stats.activeSessions > 0 { parts.append("\(stats.activeSessions) live sessions") }
        if isOverBudget { parts.append("over daily budget") }
        return parts.joined(separator: ", ")
    }

    var dataDirExists: Bool { FileManager.default.fileExists(atPath: dataRoot.path) }
    var codexDataDirExists: Bool { FileManager.default.fileExists(atPath: codexDataRoot.path) }

    /// True when at least one source the user is viewing has a data directory.
    var visibleDataDirExists: Bool {
        profiles.contains { $0.enabled && visibleSources.contains($0.source) && FileManager.default.fileExists(atPath: $0.root.path) }
    }

    /// (name, path) rows for the empty state — the tracked roots being watched.
    var trackedRoots: [(name: String, path: String)] {
        profiles.filter { $0.enabled && trackedSources.contains($0.source) }.map { ($0.name, $0.root.path) }
    }

    func startIfNeeded() async {
        guard !started else { return }
        started = true

        Diagnostics.app.info("starting TkTracker \(AppVersion.current, privacy: .public)")
        apply(await engine.bootstrap())
        if !digests.isEmpty { rebuild() }

        await refreshNow()
        startWatchers()
        if liveQuotasEnabled { Task { await refreshQuotas() } }
        await updateChecker.checkIfDue(enabled: checksForUpdates)

        minuteLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.minuteTick()
            }
        }
    }

    private func startWatchers() {
        for watcher in watchers { watcher.stop() }
        watchers = profiles.filter { $0.enabled && trackedSources.contains($0.source) }.map { profile in
            let root = profile.root
            let watcher = ProjectsWatcher(path: root.path) { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            watcher.start()
            return watcher
        }
    }

    private func sourcesChanged() {
        guard started else { return }
        startWatchers()
        rebuild()
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.pendingRefresh = nil
            await self?.refreshNow()
        }
    }

    func refreshNow() async {
        guard !refreshing else {
            refreshQueued = true
            return
        }
        refreshing = true
        if !hasScanned { isScanning = true }
        apply(await engine.refresh(sources: trackedSources))
        hasScanned = true
        isScanning = false
        refreshing = false
        if refreshQueued {
            refreshQueued = false
            scheduleRefresh()
        }
    }

    func resetCacheAndRescan() async {
        isScanning = true
        apply(await engine.reset(rescanning: trackedSources))
        isScanning = false
    }

    /// Fold a scan result into the store: digests, health, and everything derived.
    private func apply(_ report: UsageEngine.RefreshReport) {
        digests = report.digests
        scanHealth = ScanHealth(
            lastScan: Date(),
            lastScanDuration: report.duration,
            digestCount: report.digests.count,
            claimCount: report.claimCount,
            unreadableFiles: report.unreadable,
            cacheWriteFailed: report.cacheWriteFailed
        )
        for digest in digests {
            if let quota = digest.quota {
                let id = digest.profileId ?? digest.source.rawValue
                if quota.observedAt > (quotaSnapshots[id]?.observedAt ?? .distantPast) { quotaSnapshots[id] = quota }
            }
        }
        rebuildHistoryDigest()
        rebuild()
    }

    /// The imported pre-cleanup estimate is Claude-only; its cutoff must come
    /// from Claude transcripts alone or older Codex data would clip it.
    private func rebuildHistoryDigest() {
        historyDigests = StatsCacheImport.historyDigests(profiles: profiles, transcriptDigests: digests)
    }

    func flush() async {
        await engine.flush()
    }

    nonisolated func flushBlocking(timeout: TimeInterval = 1.5) {
        let semaphore = DispatchSemaphore(value: 0)
        let engine = self.engineForFlush
        Task.detached {
            await engine.flush()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private nonisolated var engineForFlush: UsageEngine {
        // Engine reference is immutable after init; safe to read off-actor.
        MainActor.assumeIsolated { engine }
    }

    private func minuteTick() async {
        minuteCount += 1
        if liveQuotasEnabled { Task { await refreshQuotas() } }
        // A watcher can start unarmed when its directory and every acceptable
        // parent are missing (Codex never installed, say). Retry cheaply so the
        // source goes live when it appears instead of waiting for a relaunch.
        for watcher in watchers where !watcher.isArmed {
            watcher.start()
        }
        if minuteCount % 5 == 0 {
            await refreshNow() // safety net behind FSEvents
        } else {
            rebuild() // roll "today", block countdown, live windows
        }
    }

    private func rebuild() {
        claudePresent = dataDirExists || digests.contains { $0.source == .claude }
        codexPresent = codexDataDirExists || digests.contains { $0.source == .codex }
        stats = StatsBuilder.build(digests: visibleDigests(), range: range, plan: plan, filter: reportFilter, profiles: profiles.filter { visibleSources.contains($0.source) })
        colorScale = ModelColorScale(palette: stats.modelPalette)
        trackedTodayCost = trackedTodayCostNow()
        let tracked = digests.filter { trackedSources.contains($0.source) }
        budgetProgress = BudgetAnalysis.progress(rules: budgetRules, digests: tracked)
        for progress in budgetProgress { BudgetNotifier.notifyMonthly(progress) }
        if anomalyAlerts, let multiple = BudgetAnalysis.unusualSpend(digests: tracked, multiplier: 3) { BudgetNotifier.notifyAnomaly(multiple: multiple) }
        for (id, quota) in quotaSnapshots where quotaAlertsEnabled && !quota.isStale() { BudgetNotifier.notifyQuota(quota, accountId: id) }
        BudgetNotifier.notifyIfCrossed(todayCost: trackedTodayCost, budget: dailyBudget)
        // Alerts follow the same rule as the budget: they are standing
        // commitments about real spend, so a transient view filter must never
        // quiet one. `stats` is filtered by `sourceScope`; these are not.
        for account in AccountUsage.build(profiles: profiles.filter { trackedSources.contains($0.source) }, digests: digests) {
            if let gauge = account.block, let end = gauge.windowEnd {
                BudgetNotifier.notifyBlockNearLimit(gauge: gauge, blockStart: end.addingTimeInterval(-5 * 3600), accountId: account.id)
            }
            if let gauge = account.weekly { BudgetNotifier.notifyWeeklyNearLimit(gauge: gauge, accountId: account.id) }
        }
    }

    /// Today's cost over all tracked sources, ignoring the view filter (the
    /// imported pre-cleanup estimate never covers today, so transcripts and
    /// archived digests are the whole picture).
    private func trackedTodayCostNow() -> Double {
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var cost = 0.0
        for digest in digests where trackedSources.contains(digest.source) {
            // Buckets are sorted by hour; today's sit at the tail.
            for bucket in digest.accountingBuckets where bucket.epoch >= todayStart && bucket.epoch <= Date().timeIntervalSince1970 { cost += bucket.cost }
        }
        return cost
    }

    private func visibleDigests() -> [FileDigest] {
        let visible = visibleSources
        var all = digests.filter { visible.contains($0.source) }
        if includeHistory, visible.contains(.claude) { all += historyDigests }
        return all
    }

    /// Stats for an explicitly requested range and scope, independent of what the
    /// dashboard happens to be showing.
    ///
    /// Shortcuts must mean what they say: asking for "all sources" has to answer
    /// for all sources even if the window is currently filtered to one. The
    /// user's `includeHistory` preference still applies — that is a statement
    /// about which data is trustworthy, not a transient lens.
    func stats(range: StatsRange, scope: SourceScope) -> DashboardStats {
        let wanted = scope.sources.intersection(trackedSources)
        let visible = wanted.isEmpty ? trackedSources : wanted
        var selected = digests.filter { visible.contains($0.source) }
        if includeHistory, visible.contains(.claude) { selected += historyDigests }
        return StatsBuilder.build(digests: selected, range: range, plan: plan, profiles: profiles.filter { visible.contains($0.source) })
    }

    /// Recompute everything derived from the current digests without rescanning.
    /// Used when something outside the scan changes the numbers — a pricing
    /// override, for instance.
    func refreshDerived() {
        rebuild()
    }

    func csvForCurrentRange() -> String {
        CSVExport.dailyByModel(digests: visibleDigests(), range: range, filter: reportFilter)
    }

    /// The full dashboard stats — the same document `report --json` emits, via
    /// the same encoder (`DashboardStats.jsonDocument`).
    func jsonForCurrentRange() throws -> String {
        try stats.jsonDocument()
    }

    func showSessions(filteredBy projectName: String) {
        sessionSearch = projectName
        dashboardSection = .sessions
    }
}
