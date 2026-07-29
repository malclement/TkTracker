import Testing
import Foundation
@testable import TkTracker

/// `CLIReport.scan` is the single source of truth for `report`, `--watch` and the
/// Shortcuts intents, and the JSON document is a published contract. Both were
/// asserted in comments and untested.
@Suite("Scan entry point and exports")
final class ScanAndExportTests {
    private let dir: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("tktracker-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: ScanCore.canonicalPath(raw), isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func assistantLine(id: String, request: String) -> String {
        #"{"type":"assistant","timestamp":"2026-07-07T10:00:00.000Z","cwd":"/Users/x/p","requestId":"\#(request)","message":{"id":"\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":1000000}}}"#
    }

    /// Roots under the scratch dir, so nothing touches real data or Application
    /// Support.
    private func pipelines(
        claudeExists: Bool,
        codexExists: Bool
    ) throws -> [(core: ScanCore, archive: HistoryArchive)] {
        let claudeRoot = dir.appendingPathComponent("claude", isDirectory: true)
        let codexRoot = dir.appendingPathComponent("codex", isDirectory: true)
        if claudeExists {
            let project = claudeRoot.appendingPathComponent("-Users-x-p", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try (assistantLine(id: "m1", request: "r1") + "\n")
                .write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        }
        if codexExists {
            try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        }
        return [
            (
                core: ScanCore(source: .claude, root: claudeRoot,
                               cacheURL: dir.appendingPathComponent("c.json")),
                archive: HistoryArchive(url: dir.appendingPathComponent("ca.json"))
            ),
            (
                core: ScanCore(source: .codex, root: codexRoot,
                               cacheURL: dir.appendingPathComponent("x.json")),
                archive: HistoryArchive(source: .codex, url: dir.appendingPathComponent("xa.json"))
            ),
        ]
    }

    // MARK: - scan()

    @Test func scanReturnsDigestsAndPersistsByDefault() throws {
        let pipes = try pipelines(claudeExists: true, codexExists: true)
        let outcome = CLIReport.scan(sources: Set(UsageSource.allCases), includeHistory: false, pipelines: pipes)
        guard case .success(let digests, let notes) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(digests.count == 1)
        #expect(notes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.json").path))
    }

    @Test func scanWithPersistFalseWritesNothing() throws {
        // The Shortcuts path uses this: answering a question must not take
        // ownership of cache state the running app also writes.
        let pipes = try pipelines(claudeExists: true, codexExists: true)
        let outcome = CLIReport.scan(
            sources: Set(UsageSource.allCases), includeHistory: false, persist: false, pipelines: pipes
        )
        guard case .success(let digests, _) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(digests.count == 1) // the scan still produces real data
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ca.json").path))
    }

    @Test func anExplicitlyRequestedMissingSourceIsAnError() throws {
        // Silently reporting zero for a source the user named would be worse than
        // failing: they would read it as "I spent nothing".
        let pipes = try pipelines(claudeExists: true, codexExists: false)
        let outcome = CLIReport.scan(
            sources: [.codex], explicitSource: .codex, includeHistory: false, pipelines: pipes
        )
        guard case .failure(let message, let code) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(code == 1)
        #expect(message.contains("no Codex data"))
    }

    @Test func anImplicitlyMissingSourceBecomesANoteNotAFailure() throws {
        // Default is both sources; one absent is normal, not an error — but it
        // must be reported so the totals are not read as covering both.
        let pipes = try pipelines(claudeExists: true, codexExists: false)
        let outcome = CLIReport.scan(
            sources: Set(UsageSource.allCases), includeHistory: false, pipelines: pipes
        )
        guard case .success(let digests, let notes) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(digests.count == 1)
        #expect(notes.count == 1)
        #expect(notes[0].contains("Codex"))
    }

    @Test func everySourceMissingIsAFailure() throws {
        let pipes = try pipelines(claudeExists: false, codexExists: false)
        let outcome = CLIReport.scan(
            sources: Set(UsageSource.allCases), includeHistory: false, pipelines: pipes
        )
        guard case .failure(_, let code) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(code == 1)
    }

    // MARK: - JSON contract

    @Test func jsonDocumentIsDeterministicAndRoundTrips() throws {
        var totals = TokenTotals()
        totals.input = 1_000_000
        totals.output = 1_000_000
        totals.messages = 1
        var digest = FileDigest(path: "/a.jsonl", sessionId: "s", projectDir: "-Users-x-p")
        digest.cwd = "/Users/x/p"
        digest.gitBranch = "main"
        digest.firstTs = 1_783_000_000
        digest.lastTs = 1_783_003_600
        digest.buckets = [HourBucket(hour: 1_783_000_000 / 3600 * 3600, model: "claude-opus-4-8", totals: totals)]

        var plan = UsagePlan.preset(id: "max20")
        plan.blockLimit = 100
        plan.weeklyLimit = 500
        let stats = StatsBuilder.build(
            digests: [digest], range: .all,
            now: Date(timeIntervalSince1970: 1_783_010_000), plan: plan
        )

        let first = try stats.jsonDocument()
        let second = try stats.jsonDocument()
        #expect(first == second, "sortedKeys must make the document stable")

        // Paths stay readable rather than escaped as \/ — the drift that existed
        // between the GUI and CLI encoders.
        #expect(first.contains("/Users/x/p"))
        #expect(!first.contains("\\/"))

        // Decodes back to the same figures, so consumers can rely on the schema.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DashboardStats.self, from: Data(first.utf8))
        #expect(decoded.totals.total == stats.totals.total)
        #expect(abs(decoded.cost - stats.cost) < 1e-9)
        #expect(decoded.branches.count == stats.branches.count)
        #expect(decoded.heatmap.count == stats.heatmap.count)
        #expect(decoded.blockGauge?.limit == 100)
        #expect(decoded.weeklyGauge?.limit == 500)
    }

    @Test func planIsAppliedToTheJSONDocument() throws {
        // The CLI used to build stats with no plan while the GUI applied one, so
        // the two "interchangeable" documents disagreed about gauges.
        var totals = TokenTotals()
        totals.output = 4_000_000 // Opus 4.8 at $25/MTok = $100
        totals.messages = 1
        var digest = FileDigest(path: "/a.jsonl", sessionId: "s", projectDir: "p")
        let now = Date(timeIntervalSince1970: 1_783_010_000)
        digest.buckets = [HourBucket(
            hour: Int64(now.timeIntervalSince1970) / 3600 * 3600,
            model: "claude-opus-4-8", totals: totals
        )]

        var plan = UsagePlan.preset(id: "max20")
        plan.blockLimit = 200
        plan.weeklyLimit = 0

        let withPlan = StatsBuilder.build(digests: [digest], range: .all, now: now, plan: plan)
        let withoutPlan = StatsBuilder.build(digests: [digest], range: .all, now: now, plan: .none)

        #expect(withPlan.blockGauge != nil)
        #expect(withoutPlan.blockGauge == nil)
        // Same spend either way — only the gauge differs.
        #expect(abs(withPlan.cost - withoutPlan.cost) < 1e-9)
        #expect(abs((withPlan.blockGauge?.fraction ?? 0) - 0.5) < 1e-9)
    }

    // MARK: - Heatmap bucketing

    @Test func heatmapBucketsIntoLocalWeekdayAndHour() throws {
        // Buckets are stored as UTC hours but the grid is meant to answer "when do
        // I work", so conversion goes through the injected calendar. A timezone far
        // from UTC makes an off-by-one obvious.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")! // UTC+9, no DST
        calendar.firstWeekday = 1

        // 2026-07-07T20:00Z is 2026-07-08T05:00 in Tokyo — a different day *and*
        // a different weekday.
        let utcHour: Int64 = 1_783_454_400 // 2026-07-07T20:00:00Z
        var totals = TokenTotals()
        totals.output = 1_000_000
        totals.messages = 1
        var digest = FileDigest(path: "/a.jsonl", sessionId: "s", projectDir: "p")
        digest.buckets = [HourBucket(hour: utcHour, model: "claude-opus-4-8", totals: totals)]

        let stats = StatsBuilder.build(
            digests: [digest], range: .all,
            now: Date(timeIntervalSince1970: 1_783_600_000), calendar: calendar
        )
        let cell = try #require(stats.heatmap.first)
        #expect(stats.heatmap.count == 1)

        // Cross-check against the calendar rather than restating the arithmetic.
        let expected = calendar.dateComponents(
            [.weekday, .hour], from: Date(timeIntervalSince1970: Double(utcHour))
        )
        #expect(cell.weekday == expected.weekday)
        #expect(cell.hour == expected.hour)
        #expect(cell.hour == 5) // 05:00 local
        #expect(cell.tokens == 1_000_000)
        #expect(abs(cell.cost - 25) < 1e-9)

        // Cell ids must be unique per (weekday, hour) or the grid would collide.
        #expect(cell.id == cell.weekday * 100 + cell.hour)
    }

    @Test func heatmapAggregatesRepeatedSlotsAndRespectsTheRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        func bucket(_ hour: Int64, output: Int64) -> HourBucket {
            var t = TokenTotals()
            t.output = output
            t.messages = 1
            return HourBucket(hour: hour, model: "claude-opus-4-8", totals: t)
        }

        let base: Int64 = 1_783_454_400 // 2026-07-07T20:00:00Z, a Tuesday
        var digest = FileDigest(path: "/a.jsonl", sessionId: "s", projectDir: "p")
        digest.buckets = [
            bucket(base, output: 1_000_000),
            bucket(base + 7 * 86_400, output: 1_000_000), // same weekday+hour, next week
            bucket(base + 3600, output: 1_000_000),       // adjacent hour
        ].sorted { $0.hour < $1.hour }

        let now = Date(timeIntervalSince1970: Double(base + 8 * 86_400))
        let all = StatsBuilder.build(digests: [digest], range: .all, now: now, calendar: calendar)
        // Two distinct slots; the same weekday+hour a week apart merges.
        #expect(all.heatmap.count == 2)
        let merged = try #require(all.heatmap.first { $0.hour == 20 })
        #expect(merged.tokens == 2_000_000)

        // Range-filtered: only the most recent week is in scope.
        let week = StatsBuilder.build(digests: [digest], range: .week, now: now, calendar: calendar)
        let weekSlot = try #require(week.heatmap.first { $0.hour == 20 })
        #expect(weekSlot.tokens == 1_000_000, "the older occurrence is out of range")
    }
}
