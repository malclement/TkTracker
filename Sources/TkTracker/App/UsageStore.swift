import SwiftUI
import Observation
import ServiceManagement

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case cost, tokens, icon
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cost: return "Today's cost"
        case .tokens: return "Today's tokens"
        case .icon: return "Icon only"
        }
    }
}

@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var stats: DashboardStats = .empty
    private(set) var isScanning = false
    private(set) var hasScanned = false

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

    let dataRoot = ScanCore.defaultRoot()

    private var digests: [FileDigest] = []
    private var historyDigest: FileDigest?
    private let engine = UsageEngine()
    private var watcher: ProjectsWatcher?
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var menuBarTitle: String? {
        switch menuBarDisplay {
        case .icon: return nil
        case .cost: return Format.moneyCompact(stats.todayCost)
        case .tokens: return Format.tokens(stats.todayTotals.total)
        }
    }

    var dataDirExists: Bool { FileManager.default.fileExists(atPath: dataRoot.path) }

    func startIfNeeded() async {
        guard !started else { return }
        started = true

        digests = await engine.bootstrap()
        historyDigest = StatsCacheImport.historyDigest(transcriptDigests: digests)
        if !digests.isEmpty { rebuild() }

        await refreshNow()

        let watcher = ProjectsWatcher(path: dataRoot.path) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        watcher.start()
        self.watcher = watcher

        minuteLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.minuteTick()
            }
        }
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
        digests = await engine.refresh()
        historyDigest = StatsCacheImport.historyDigest(transcriptDigests: digests)
        rebuild()
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
        digests = await engine.reset()
        historyDigest = StatsCacheImport.historyDigest(transcriptDigests: digests)
        rebuild()
        isScanning = false
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
        if minuteCount % 5 == 0 {
            await refreshNow() // safety net behind FSEvents
        } else {
            rebuild() // roll "today", block countdown, live windows
        }
    }

    private func rebuild() {
        var all = digests
        if includeHistory, let historyDigest { all.append(historyDigest) }
        stats = StatsBuilder.build(digests: all, range: range)
    }
}
