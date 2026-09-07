import Foundation
import Testing
@testable import TkTracker

@Suite("Production accounting and recovery")
struct ProductionTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tktracker-production-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func digest(_ records: [HourBucket], path: String = "/session", profile: String = "claude") -> FileDigest {
        var d = FileDigest(path: path, sessionId: path, projectDir: "-project")
        d.cwd = "/work/project"; d.profileId = profile
        d.records = records; d.buckets = records
        d.firstTs = records.first?.epoch; d.lastTs = records.last?.epoch
        return d
    }
    private func record(_ at: Date, model: String = "gpt-5.6-terra", tier: ServiceTier = .standard, input: Int64 = 100_000) -> HourBucket {
        HourBucket(hour: Int64(at.timeIntervalSince1970 / 3600) * 3600, model: model,
            totals: TokenTotals(input: input, output: 1000, messages: 1), timestamp: at.timeIntervalSince1970,
            context: PricingContext(date: at, tier: tier, promptTokens: input), contextTokens: input)
    }
    @Test func canonicalVariantsNeverCollapse() {
        #expect(ModelIdentity.canonical("us.anthropic.claude-opus-4-8-20260701-v1:0") == "claude-opus-4-8")
        #expect(ModelIdentity.canonical("openai/gpt-5.6") == "gpt-5.6-sol")
        #expect(ModelIdentity.displayName("gpt-5.4-mini") != ModelIdentity.displayName("gpt-5.4"))
        #expect(ModelIdentity.displayName("gpt-5.1-codex-max") != ModelIdentity.displayName("gpt-5.1-codex"))
        #expect(ModelIdentity.displayName("claude-mythos-5-1") == "Mythos 5.1")
    }
    @Test func newRatesAndExceptions() {
        let c = PricingCatalog(document: .init(schema: 2, webSearchPer1000: 0, contextWindows: [], defaultContextWindow: 1, rules: []), overrides: [:])
        #expect(c.pricing(for: "gpt-5.6-sol") == nil)
        let catalog = PricingCatalog(document: PricingCatalog.builtIn, overrides: [:])
        #expect(catalog.pricing(for: "gpt-6-astra")?.input == 10)
        #expect(catalog.pricing(for: "gpt-5.6")?.output == 20)
        #expect(catalog.pricing(for: "gpt-5.6-terra")?.cacheWrite5m == 2.5)
        #expect(catalog.pricing(for: "gpt-5.6-luna")?.output == 1.2)
        #expect(catalog.pricing(for: "claude-sonnet-5")?.input == 2)
        #expect(catalog.pricing(for: "claude-fable-5-1")?.cacheRead == 0.25)
        #expect(catalog.pricing(for: "codex-mini-latest")?.cacheRead == 0.375)
        #expect(catalog.pricing(for: "gpt-5.6-unknown") == nil)
    }
    @Test func longPromptThresholdAndFastCompose() throws {
        let c = PricingCatalog(document: PricingCatalog.builtIn, overrides: [:])
        let short = try #require(c.pricing(for: "gpt-6-astra", context: PricingContext(tier: .fast, promptTokens: 272_000)))
        let long = try #require(c.pricing(for: "gpt-6-astra", context: PricingContext(tier: .fast, promptTokens: 272_001)))
        #expect(short.input == 20); #expect(short.output == 100)
        #expect(long.input == 40); #expect(long.output == 150); #expect(long.cacheWrite5m == 50)
        #expect(c.pricing(for: "claude-opus-4-7", context: PricingContext(tier: .fast)) == nil)
        #expect(c.pricing(for: "claude-sonnet-5", context: PricingContext(tier: .flex)) == nil)
    }
    @Test func overridesAreIsolatedValidatedAndDurable() throws {
        let url = try scratch().appendingPathComponent("rates.json")
        let c = PricingCatalog(document: PricingCatalog.builtIn, overrides: [:], overridesURL: url)
        c.setOverride(PricingOverride(input: 8, output: 40), forShortName: "gpt-5.6-sol")
        #expect(c.pricing(for: "gpt-5.6-sol")?.cacheWrite5m == 10)
        #expect(c.pricing(for: "gpt-5.6-terra")?.input == 2)
        c.setOverride(PricingOverride(input: -.infinity, output: 0), forShortName: "gpt-5.6-sol")
        #expect(c.lastError != nil)
        #expect(c.pricing(for: "gpt-5.6-sol")?.input == 8)
        let reload = PricingCatalog(document: PricingCatalog.builtIn, overridesURL: url)
        #expect(reload.pricing(for: "gpt-5.6-sol")?.cacheWrite5m == 10)
    }
    @Test func failedOverrideSaveRetainsPreviousRates() throws {
        let root = try scratch()
        let c = PricingCatalog(document: PricingCatalog.builtIn, overrides: [:], overridesURL: root)
        c.setOverride(PricingOverride(input: 900, output: 900), forShortName: "gpt-5.6-sol")
        #expect(c.lastError != nil)
        #expect(c.overrideCount == 0)
        #expect(c.pricing(for: "gpt-5.6-sol")?.input == 4)
    }
    @Test func exactDatesWorkAcrossHalfHourTimezones() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let start = date("2026-09-06T18:30:00Z"), now = date("2026-09-07T12:00:00Z")
        let d = digest([record(start.addingTimeInterval(-1)), record(start), record(now.addingTimeInterval(120))])
        let filter = ReportFilter(start: start, end: now)
        let stats = StatsBuilder.build(digests: [d], range: .all, now: now, calendar: calendar, filter: filter)
        #expect(stats.totals.messages == 1)
        #expect(abs(stats.cost - 0.212) < 0.000001)
        let csv = CSVExport.dailyByModel(digests: [d], range: .all, now: now, calendar: calendar, filter: filter)
        #expect(csv.contains("2026-09-07,codex") == false) // source is supplied by the profile, never inferred from model
        #expect(csv.contains("2026-09-07,claude,gpt-5.6-terra"))
        #expect(csv.contains("0.2120"))
    }
    @Test func unpricedAndMissingTierCoverage() {
        let now = Date()
        let stats = StatsBuilder.build(digests: [digest([record(now, model: "future-model"), record(now, tier: .unknown)])], range: .all, now: now)
        #expect(stats.coverage.isIncomplete)
        #expect(stats.coverage.unpricedRequests == 1)
        #expect(stats.coverage.assumedTierRequests >= 1)
        #expect(stats.models.first(where: { $0.model == "future-model" })?.hasPricing == false)
    }
    @Test func branchChangesAndSameBasenameRemainSeparate() {
        let now = Date()
        var a = record(now); a.branch = "main"
        var b = record(now); b.branch = "feature"
        let first = digest([a,b])
        var second = digest([a], path: "/second"); second.cwd = "/another/project"
        let stats = StatsBuilder.build(digests: [first,second], range: .all, now: now)
        #expect(stats.projects.count == 2)
        #expect(stats.branches.count == 3)
        #expect(Set(stats.branches.map(\.id)).count == 3)
    }
    @Test func filterUsesCanonicalModelAndProjectPath() {
        let now = Date()
        let d = digest([record(now, model: "gpt-5.6-sol-20260825"), record(now)])
        let f = ReportFilter(project: "/work/project", model: "gpt-5.6")
        #expect(f.apply(to: [d]).first?.accountingBuckets.count == 1)
        #expect(ReportFilter(project: "project").apply(to: [d]).isEmpty)
    }
    @Test func hugeTokensRemainFiniteInDashboard() {
        let now = Date()
        var b = record(now); b.totals = TokenTotals(input: .max, output: .max, cacheRead: .max, cacheWrite5m: .max, cacheWrite1h: .max)
        let stats = StatsBuilder.build(digests: [digest([b,b])], range: .all, now: now)
        #expect(stats.cost.isFinite)
        #expect(stats.cacheSavings.isFinite)
        #expect(stats.totals.total == .max)
    }
    @Test func accountAllowancesNeverMix() {
        let now = Date()
        var plan = UsagePlan.none; plan.monthlyCost = 20; plan.weeklyLimit = 100
        let profiles = [SourceProfile(id: "personal", name: "Personal", source: .codex, rootPath: "/a", plan: plan), SourceProfile(id: "work", name: "Work", source: .codex, rootPath: "/b", plan: plan)]
        let accounts = AccountUsage.build(profiles: profiles, digests: [digest([record(now)], profile: "personal")], now: now)
        #expect(accounts[0].rollingValue > 0)
        #expect(accounts[1].rollingValue == 0)
        #expect(accounts[0].weekly?.windowEnd == nil)
        #expect(SourceProfile.unique([profiles[0], profiles[0]]).count == 1)
    }
    @Test func quotaParsingAndFreshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let raw: [String: Any] = ["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 82.5, "windowDurationMins": 300, "resetsAt": 1_800_001_000]]]]
        let snapshot = QuotaSnapshot.parse(raw, at: now, origin: "test")
        #expect(snapshot.windows.first?.remainingPercent == 17.5)
        #expect(snapshot.isStale(at: now) == false)
        #expect(snapshot.isStale(at: now.addingTimeInterval(301)))
        #expect(snapshot.isStale(at: now.addingTimeInterval(1001)))
    }
    @Test func quotaWithoutTokenInfoDoesNotLoseWindow() throws {
        let root = try scratch(), file = root.appendingPathComponent("quota.jsonl")
        let raw = #"{"timestamp":"2026-09-07T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":1800001000}}}}"# + "\n"
        try Data(raw.utf8).write(to: file)
        let d = CodexParser.scan(url: file, previous: nil, size: Int64(raw.utf8.count), mtime: 1)
        #expect(d.quota?.windows.first?.usedPercent == 10)
        #expect(d.totals.isEmpty)
    }
    @Test func metadataRetentionPreservesMoneyAndTokens() {
        let now = Date(), old = now.addingTimeInterval(-100 * 86400)
        var d = digest([record(old)])
        d.aiTitle = "Private title"; d.markers = [SessionMarker(timestamp: old.timeIntervalSince1970, kind: "compact")]
        let retained = PrivacyPolicy(detailRetentionDays: 30).apply(d, now: now)
        #expect(retained.title == nil); #expect(retained.markers == nil)
        #expect(retained.records?.first?.contextTokens == nil)
        #expect(retained.cost == d.cost); #expect(retained.totals == d.totals)
        #expect(PrivacyPolicy(omitTitles: true).apply(d).title == nil)
    }
    @Test func backupRoundTripMergeAndReset() async throws {
        let root = try scratch(), cache = root.appendingPathComponent("cache.json"), archive = root.appendingPathComponent("archive.json")
        let engine = UsageEngine(pipelines: [(ScanCore(root: root.appendingPathComponent("missing"), cacheURL: cache, profileId: "personal"), HistoryArchive(url: archive))])
        let now = Date()
        let d = digest([record(now)], profile: "personal")
        let original = ArchiveBackup(entries: [.init(profileId: "personal", source: .claude, rootPath: root.appendingPathComponent("missing").path,
            cache: DigestCache(version: 2, digests: [d.path: d], claims: ["m:r": d.path]))])
        let file = root.appendingPathComponent("backup.json")
        try original.write(to: file)
        let decoded = try ArchiveBackup.read(file)
        let once = try await engine.restore(decoded)
        let twice = try await engine.restore(decoded)
        #expect(once.digests.count == 1); #expect(twice.digests.count == 1)
        #expect(twice.digests.first?.cost == d.cost)
        let reset = await engine.reset(rescanning: [.claude])
        #expect(reset.digests.count == 1); #expect(reset.claimCount == 1)
        #expect(reset.digests.first?.source == .claude)
    }
    @Test func invalidBackupDoesNotModifyHistory() async throws {
        let root = try scratch(), engine = UsageEngine(pipelines: [])
        let backup = ArchiveBackup(entries: [.init(profileId: "absent", source: .claude, rootPath: root.path, cache: DigestCache(version: 2, digests: [:], claims: ClaimMap()))])
        await #expect(throws: ArchiveBackup.Failure.self) { try await engine.restore(backup) }
        #expect(await engine.snapshot().digests.isEmpty)
    }
    @Test func budgetsUseCalendarMonthAndStableProjectKey() {
        let now = date("2026-09-15T12:00:00Z")
        let d = digest([record(now), record(date("2026-08-31T00:00:00Z"))])
        let rules = [BudgetRule(project: d.projectKey, monthlyLimit: 10), BudgetRule(project: "/other/project", monthlyLimit: 10)]
        let progress = BudgetAnalysis.progress(rules: rules, digests: [d], now: now)
        #expect(abs(progress[0].used - 0.212) < 0.000001)
        #expect(progress[0].projected != nil); #expect(progress[1].used == 0)
    }
    @Test func csvEscapesUntrustedModelNames() {
        #expect(CSVExport.escape("=1+1") == "'=1+1")
        #expect(CSVExport.escape("a,b\"c") == "\"a,b\"\"c\"")
    }
    @Test func malformedCLIFiltersFailBeforeScanning() {
        #expect(CLIReport.run(arguments: ["--from", "2026-02-31", "--to", "2026-03-01"]) == 2)
        #expect(CLIReport.run(arguments: ["--from", "2026-09-07"]) == 2)
        #expect(CLIReport.run(arguments: ["--to"]) == 2)
    }
}

@Suite("Codex quota process")
struct QuotaProcessTests {
    @Test func initializesBeforeReadingQuotas() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tktracker-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex")
        let code = #"""
        #!/bin/sh
        read first
        printf '%s\n' '{"id":1,"result":{"userAgent":"test"}}'
        read initialized
        read request
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800001000}}}}'
        read finished
        """#
        try Data(code.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = try await CodexQuotaClient.fetch(executable: script, configRoot: root, timeout: 2)
        #expect(result.windows.first?.remainingPercent == 75)
    }
    @Test func unresponsiveCLITimesOutAndCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tktracker-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nread first\nread second\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        await #expect(throws: CodexQuotaClient.Failure.self) {
            try await CodexQuotaClient.fetch(executable: script, configRoot: root, timeout: 0.05)
        }
    }
}

@Suite("Profile history isolation")
struct ProfileHistoryTests {
    @Test func historyReadsOnlyTheConfiguredAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tktracker-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = #"{"dailyModelTokens":[{"date":"2026-01-01","tokensByModel":{"claude-opus-4-8":1000}}]}"#
        try Data(raw.utf8).write(to: root.appendingPathComponent("stats-cache.json"))
        let profile = SourceProfile(id: "custom", name: "Custom", source: .claude, rootPath: root.appendingPathComponent("projects").path)
        let imports = StatsCacheImport.historyDigests(profiles: [profile], transcriptDigests: [])
        #expect(imports.count == 1)
        #expect(imports.first?.profileId == "custom")
        #expect(imports.first?.path == StatsCacheImport.syntheticPath + "/custom")
        var disabled = profile; disabled.enabled = false
        #expect(StatsCacheImport.historyDigests(profiles: [disabled], transcriptDigests: []).isEmpty)
    }
    @Test func nestedProfilesCannotDoubleCount() {
        let outer = SourceProfile(id: "a", name: "A", source: .codex, rootPath: "/sessions")
        let inner = SourceProfile(id: "b", name: "B", source: .codex, rootPath: "/sessions/2026")
        #expect(SourceProfile.unique([outer,inner]).count == 1)
    }
}

@Suite("Custom report presentation")
struct CustomReportPresentationTests {
    @Test func customDatesOverrideTodayPresentationAndAreExported() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let filter = ReportFilter(start: now.addingTimeInterval(-7 * 86400), end: now)
        let stats = StatsBuilder.build(digests: [], range: .today, now: now, filter: filter)
        #expect(!stats.isTodayView)
        #expect(stats.chartUnit == .day)
        #expect(stats.rangeLabel != "Today")
        let encoded = try stats.jsonDocument()
        let decoded = try JSONDecoder().decode(DashboardStats.self, from: JSONEncoder().encode(stats))
        #expect(encoded.contains("reportFilter"))
        #expect(decoded.reportFilter?.start == filter.start)
    }
    @Test func quotaLabelDescribesActualWindowLength() {
        let window = QuotaWindow(name: "codex · primary", usedPercent: 12, durationMinutes: 10080, resetsAt: Date())
        #expect(window.label == "7-day window")
    }
}
