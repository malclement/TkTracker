import Testing
import Foundation
@testable import TkTracker

@Suite("Codex source")
final class CodexTests {
    private let dir: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("tktracker-codex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(raw.path, &buffer) != nil {
            dir = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
        } else {
            dir = raw
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: fixtures — shaped like real rollout lines (April→June 2026 CLI versions)

    private func meta(
        id: String = "019f03e2-0773-7891-a355-b056f10fc200",
        cwd: String = "/Users/x/Documents/Proj",
        branch: String? = "main",
        ts: String = "2026-07-07T10:00:00.000Z"
    ) -> String {
        let git = branch.map { #","git":{"commit_hash":"abc","branch":"\#($0)","repository_url":"https://example.com/r.git"}"# } ?? ""
        return #"{"timestamp":"\#(ts)","type":"session_meta","payload":{"id":"\#(id)","timestamp":"\#(ts)","cwd":"\#(cwd)"\#(git),"originator":"codex-tui","cli_version":"0.142.2","source":"cli","model_provider":"openai"}}"#
    }

    private func turnContext(model: String, ts: String = "2026-07-07T10:00:01.000Z") -> String {
        #"{"timestamp":"\#(ts)","type":"turn_context","payload":{"turn_id":"t","cwd":"/Users/x/Documents/Proj","approval_policy":"on-request","model":"\#(model)","personality":"pragmatic"}}"#
    }

    private func tokenCount(
        input: Int, cached: Int = 0, output: Int,
        ts: String = "2026-07-07T10:00:02.000Z",
        window: Int = 258_400
    ) -> String {
        let total = input + output
        let usage = #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(total)}"#
        return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(usage),"last_token_usage":\#(usage),"model_context_window":\#(window)},"rate_limits":{"limit_id":"codex","primary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1776849578}}}}"#
    }

    private func nullInfoTokenCount(ts: String = "2026-07-07T10:00:03.000Z") -> String {
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex"}}}"#
    }

    private func userMessage(_ text: String, ts: String = "2026-07-07T10:00:00.500Z") -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"user_message","message":"\#(escaped)"}}"#
    }

    @discardableResult
    private func write(_ lines: [String], name: String = "rollout-2026-07-07T10-00-00-019f03e2-0773-7891-a355-b056f10fc200.jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    private func scan(_ url: URL, previous: FileDigest? = nil) throws -> FileDigest {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return CodexParser.scan(
            url: url,
            previous: previous,
            size: (attrs[.size] as! NSNumber).int64Value,
            mtime: (attrs[.modificationDate] as! Date).timeIntervalSince1970
        )
    }

    // MARK: parsing

    @Test func basicParseSplitsCachedInput() throws {
        let url = try write([
            meta(),
            userMessage("Add a codex tab\nwith details"),
            turnContext(model: "gpt-5.5"),
            tokenCount(input: 12_102, cached: 5_504, output: 246),
            nullInfoTokenCount(),
            tokenCount(input: 20_000, cached: 18_000, output: 1_000, ts: "2026-07-07T10:05:00.000Z"),
        ])
        let digest = try scan(url)

        #expect(digest.source == .codex)
        #expect(digest.sessionId == "019f03e2-0773-7891-a355-b056f10fc200")
        #expect(digest.cwd == "/Users/x/Documents/Proj")
        #expect(digest.projectDir == "-Users-x-Documents-Proj") // merges with Claude's encoding
        #expect(digest.gitBranch == "main")
        #expect(digest.fallbackTitle == "Add a codex tab")
        #expect(digest.lastModel == "gpt-5.5")
        #expect(digest.contextWindow == 258_400)
        #expect(digest.lastContextTokens == 20_000) // raw prompt size, cached included

        let totals = digest.totals
        #expect(totals.messages == 2) // null-info line is a rate-limit update, not a call
        #expect(totals.input == (12_102 - 5_504) + (20_000 - 18_000))
        #expect(totals.cacheRead == 5_504 + 18_000)
        #expect(totals.output == 246 + 1_000)
        #expect(totals.cacheWrite == 0)
        #expect(digest.buckets.allSatisfy { $0.model == "gpt-5.5" })
    }

    @Test func modelSwitchAttributesPerTurnContext() throws {
        let url = try write([
            meta(),
            turnContext(model: "gpt-5.4"),
            tokenCount(input: 100, output: 10, ts: "2026-07-07T10:00:02.000Z"),
            turnContext(model: "gpt-5.5", ts: "2026-07-07T11:00:00.000Z"),
            tokenCount(input: 200, output: 20, ts: "2026-07-07T11:00:02.000Z"),
        ])
        let digest = try scan(url)
        let byModel = Dictionary(grouping: digest.buckets, by: \.model)
        #expect(byModel["gpt-5.4"]?.reduce(Int64(0)) { $0 + $1.totals.output } == 10)
        #expect(byModel["gpt-5.5"]?.reduce(Int64(0)) { $0 + $1.totals.output } == 20)
        #expect(digest.lastModel == "gpt-5.5")
    }

    @Test func usageBeforeTurnContextFlushesToFirstModel() throws {
        // Some rollouts (forks) carry token counts before their first turn_context.
        let url = try write([
            meta(),
            tokenCount(input: 100, output: 10),
            turnContext(model: "gpt-5.5", ts: "2026-07-07T10:00:05.000Z"),
            tokenCount(input: 50, output: 5, ts: "2026-07-07T10:00:06.000Z"),
        ])
        let digest = try scan(url)
        #expect(digest.buckets.count == 1)
        #expect(digest.buckets.first?.model == "gpt-5.5")
        #expect(digest.totals.output == 15)
    }

    @Test func fileWithoutAnyModelFallsBackToFamilyDefault() throws {
        let url = try write([
            meta(),
            tokenCount(input: 100, output: 10),
        ])
        let digest = try scan(url)
        #expect(digest.buckets.first?.model == CodexParser.fallbackModel)
        #expect(Pricing.pricing(for: CodexParser.fallbackModel) != nil) // priced, not dropped
        // The attribution is provisional: recorded for reversal, and the model
        // stays unknown so a later turn_context can still claim the usage.
        #expect(digest.pendingBuckets?.isEmpty == false)
        #expect(digest.lastModel == nil)
    }

    @Test func scanBoundaryBeforeFirstTurnContextConverges() throws {
        // The FSEvents scan can land between a fork's first token_count and its
        // first turn_context. The provisional fallback attribution must be
        // reversed on the next scan, so the incremental sequence ends up
        // identical to a full rescan of the finished file.
        let first = [
            meta(),
            tokenCount(input: 100, cached: 30, output: 10),
        ]
        let url = try write(first)
        let boundary = try scan(url)
        #expect(boundary.buckets.first?.model == CodexParser.fallbackModel) // shown provisionally

        try write(first + [
            turnContext(model: "gpt-5.5", ts: "2026-07-07T10:00:05.000Z"),
            tokenCount(input: 50, output: 5, ts: "2026-07-07T10:00:06.000Z"),
        ])
        let incremental = try scan(url, previous: boundary)
        let full = try scan(url)

        #expect(incremental.buckets == full.buckets)
        #expect(incremental.totals == full.totals)
        #expect(incremental.pendingBuckets == nil)
        #expect(incremental.buckets.map(\.model) == ["gpt-5.5"]) // no fallback residue
        #expect(incremental.totals.output == 15)
        #expect(incremental.lastModel == "gpt-5.5")
    }

    @Test func projectDirEncodingMatchesClaudeCodeUTF16Semantics() {
        #expect(CodexParser.encodeProjectDir("/Users/x/Documents/Proj") == "-Users-x-Documents-Proj")
        #expect(CodexParser.encodeProjectDir("/Users/x/my.app_v2") == "-Users-x-my-app-v2")
        // Claude Code's regex works per UTF-16 unit: a surrogate pair (emoji)
        // becomes TWO dashes, an accented BMP char one.
        #expect(CodexParser.encodeProjectDir("/x/🚀app") == "-x---app")
        #expect(CodexParser.encodeProjectDir("/x/café") == "-x-caf-")
    }

    @Test func titlesSkipTagWrappedMessages() throws {
        let url = try write([
            meta(),
            userMessage("<environment_context>ignored</environment_context>"),
            userMessage("Real first prompt"),
            turnContext(model: "gpt-5.5"),
            tokenCount(input: 1, output: 1),
        ])
        #expect(try scan(url).fallbackTitle == "Real first prompt")
    }

    @Test func incrementalResumeMatchesFullScan() throws {
        // The model context must survive the resume boundary: the appended
        // lines carry only token counts, no turn_context.
        let first = [
            meta(),
            turnContext(model: "gpt-5.5"),
            tokenCount(input: 100, cached: 40, output: 10),
        ]
        let url = try write(first)
        let digest1 = try scan(url)
        #expect(digest1.totals.messages == 1)

        try write(first + [
            tokenCount(input: 200, cached: 150, output: 20, ts: "2026-07-07T11:30:00.000Z"),
        ])
        let incremental = try scan(url, previous: digest1)
        let full = try scan(url)

        #expect(incremental.totals == full.totals)
        #expect(incremental.buckets == full.buckets)
        #expect(incremental.offset == full.offset)
        #expect(incremental.totals.messages == 2)
        #expect(incremental.buckets.count == 2) // two distinct hours
        #expect(incremental.buckets.allSatisfy { $0.model == "gpt-5.5" })
    }

    @Test func truncatedFileRescansFromScratch() throws {
        let url = try write([
            meta(),
            turnContext(model: "gpt-5.5"),
            tokenCount(input: 100, output: 10),
            tokenCount(input: 200, output: 20, ts: "2026-07-07T10:10:00.000Z"),
        ])
        let digest = try scan(url)
        try write([
            meta(),
            turnContext(model: "gpt-5.4"),
            tokenCount(input: 3, output: 1),
        ])
        let rescanned = try scan(url, previous: digest)
        #expect(rescanned.totals.messages == 1)
        #expect(rescanned.totals.input == 3)
        #expect(rescanned.buckets.first?.model == "gpt-5.4")
    }

    @Test func hugeTokenCountsClampInsteadOfTrapping() throws {
        let big = Int64.max - 10
        let usage = #"{"input_tokens":\#(big),"cached_input_tokens":5,"output_tokens":\#(big),"total_tokens":\#(big)}"#
        let line = #"{"timestamp":"2026-07-07T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":\#(usage),"model_context_window":258400}}}"#
        let url = try write([meta(), turnContext(model: "gpt-5.5"), line, line])
        let digest = try scan(url)
        #expect(digest.totals.total == .max)
        #expect(digest.totals.messages == 2)
    }

    // MARK: scan pipeline

    @Test func scanCoreWalksDateFoldersAndStampsSource() throws {
        let root = dir.appendingPathComponent("sessions", isDirectory: true)
        let day = root.appendingPathComponent("2026/07/07", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-2026-07-07T10-00-00-019f03e2-0773-7891-a355-b056f10fc200.jsonl")
        try ([meta(), turnContext(model: "gpt-5.5"), tokenCount(input: 100, cached: 40, output: 10)]
            .joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let cacheURL = dir.appendingPathComponent("codex-cache.json")
        let core = ScanCore(source: .codex, root: root, cacheURL: cacheURL)
        let result = core.refreshed(digests: [:], claims: [:])
        let digest = try #require(result.digests[file.path])
        #expect(digest.source == .codex)
        #expect(digest.totals.output == 10)
        #expect(result.claims.isEmpty) // no claim table needed: codex never replays events

        // Round-trip: source isn't persisted; loading the codex cache stamps it back.
        core.saveCache(digests: result.digests, claims: result.claims)
        let loaded = core.loadCache()
        #expect(loaded.digests[file.path]?.source == .codex)
        #expect(loaded.digests[file.path]?.contextWindow == 258_400)
    }

    @Test func legacyClaudeCacheEntriesStillDecode() throws {
        // A pre-1.4 cache entry: no `source`, no `contextWindow`.
        let legacy = #"{"version":2,"claims":{},"digests":{"/a.jsonl":{"path":"/a.jsonl","size":1,"mtime":1,"offset":1,"sessionId":"s","projectDir":"p","lastContextTokens":0,"missing":false,"buckets":[],"recentKeys":[]}}}"#
        let cache = try JSONDecoder().decode(DigestCache.self, from: Data(legacy.utf8))
        let digest = try #require(cache.digests["/a.jsonl"])
        #expect(digest.source == .claude)
        #expect(digest.contextWindow == nil)

        // And `source` never leaks into the encoding.
        let encoded = String(decoding: try JSONEncoder().encode(digest), as: UTF8.self)
        #expect(!encoded.contains("\"source\""))
    }

    @Test func codexRootResolution() {
        let defaultEnv: [String: String] = [:]
        #expect(ScanCore.defaultRoot(for: .codex, environment: defaultEnv).path.hasSuffix("/.codex/sessions"))
        #expect(ScanCore.defaultCacheURL(for: .codex, environment: defaultEnv).lastPathComponent == "scan-cache-codex.json")
        #expect(HistoryArchive.defaultURL(for: .codex, environment: defaultEnv).lastPathComponent == "history-archive-codex.json")

        let custom = ["CODEX_HOME": "/tmp/other-codex"]
        #expect(ScanCore.defaultRoot(for: .codex, environment: custom).path == "/tmp/other-codex/sessions")
        let customCache = ScanCore.defaultCacheURL(for: .codex, environment: custom).lastPathComponent
        #expect(customCache.hasPrefix("scan-cache-codex-") && customCache != "scan-cache-codex.json")

        // Claude resolution is untouched by CODEX_HOME.
        #expect(ScanCore.defaultRoot(for: .claude, environment: custom).path.hasSuffix("/.claude/projects"))
    }

    // MARK: pricing & naming

    @Test func openAIPricing() throws {
        let p55 = try #require(Pricing.pricing(for: "gpt-5.5"))
        #expect(p55.input == 5 && p55.output == 30 && p55.cacheRead == 0.5)
        #expect(p55.cacheWrite5m == 0 && p55.cacheWrite1h == 0)
        #expect(Pricing.pricing(for: "gpt-5.4")?.input == 2.5)
        #expect(Pricing.pricing(for: "gpt-5.4-mini")?.input == 0.75)
        #expect(Pricing.pricing(for: "gpt-5.3-codex")?.input == 1.75)
        #expect(Pricing.pricing(for: "gpt-5.2")?.input == 0.875)
        #expect(Pricing.pricing(for: "gpt-5.1-codex-mini")?.input == 0.25)
        #expect(Pricing.pricing(for: "codex-mini-latest")?.input == 1.5)
        #expect(Pricing.pricing(for: "gpt-5.1-codex-max")?.input == 1.25)
        #expect(Pricing.pricing(for: "gpt-5")?.input == 1.25)
        #expect(Pricing.pricing(for: "gpt-6") == nil) // unknown generation: flagged, never guessed

        // Cached input bills at a tenth: 1M uncached in + 1M cached + 1M out on gpt-5.5.
        var t = TokenTotals()
        t.input = 1_000_000
        t.cacheRead = 1_000_000
        t.output = 1_000_000
        #expect(abs(Pricing.cost(model: "gpt-5.5", totals: t) - (5 + 0.5 + 30)) < 1e-9)
    }

    @Test func gptNamesVersionsAndFamily() {
        #expect(ModelFamily(model: "gpt-5.5") == .gpt)
        #expect(ModelFamily(model: "codex-mini-latest") == .gpt)
        #expect(ModelFamily.shortName(for: "gpt-5.5") == "GPT-5.5")
        #expect(ModelFamily.shortName(for: "gpt-5.4") == "GPT-5.4")
        #expect(ModelFamily.shortName(for: "gpt-5.3-codex") == "Codex 5.3")
        #expect(ModelFamily.shortName(for: "gpt-5.1-codex-mini") == "Codex Mini 5.1")
        #expect(ModelFamily.shortName(for: "codex-mini-latest") == "Codex Mini")
        #expect(ModelFamily.version(of: "gpt-5.5") == 5.5)
        #expect(ModelFamily.version(of: "gpt-5.3-codex") == 5.3)
        // Claude parsing is untouched.
        #expect(ModelFamily.version(of: "claude-opus-4-8") == 4.8)
        #expect(ModelFamily.shortName(for: "claude-fable-5") == "Fable 5")
        #expect(ModelFamily.displayOrder.firstIndex(of: .gpt) != nil)
        #expect(Pricing.contextWindow(for: "gpt-5.5") == 272_000)
    }

    // MARK: aggregation

    @Test func statsCarrySourceAndObservedContextWindow() throws {
        let url = try write([
            meta(),
            turnContext(model: "gpt-5.5"),
            tokenCount(input: 100, cached: 40, output: 10),
        ])
        let codexDigest = try scan(url)

        var claudeDigest = FileDigest(path: "/c.jsonl", sessionId: "c", projectDir: "-Users-x-Documents-Proj")
        claudeDigest.cwd = "/Users/x/Documents/Proj"
        claudeDigest.lastModel = "claude-opus-4-8"
        var t = TokenTotals()
        t.input = 50
        t.messages = 1
        claudeDigest.buckets = [HourBucket(
            hour: codexDigest.buckets[0].hour, model: "claude-opus-4-8", totals: t
        )]
        claudeDigest.lastTs = codexDigest.lastTs

        let now = Date(timeIntervalSince1970: Double(codexDigest.buckets[0].hour) + 3600)
        let stats = StatsBuilder.build(digests: [codexDigest, claudeDigest], range: .all, now: now)

        let codexRow = try #require(stats.sessions.first { $0.source == .codex })
        #expect(codexRow.contextLimit == 258_400) // observed, not the table fallback
        let claudeRow = try #require(stats.sessions.first { $0.source == .claude })
        #expect(claudeRow.contextLimit == 200_000)

        // Same cwd from both tools folds into one project row.
        #expect(stats.projects.count == 1)
        #expect(stats.projects.first?.sessions == 2)

        // Per-source split adds up to the range cost.
        let split = stats.costBySource.values.reduce(0, +)
        #expect(abs(split - stats.cost) < 1e-9)
        #expect(stats.cost(for: .codex) > 0)
        #expect(stats.cost(for: .claude) > 0)
    }

    @Test func csvIncludesSourceColumn() throws {
        let url = try write([
            meta(),
            turnContext(model: "gpt-5.5"),
            tokenCount(input: 100, cached: 40, output: 10),
        ])
        let digest = try scan(url)
        let csv = CSVExport.dailyByModel(
            digests: [digest],
            range: .all,
            now: Date(timeIntervalSince1970: (digest.lastTs ?? 0) + 60)
        )
        let lines = csv.split(separator: "\n")
        #expect(lines[0].hasPrefix("date,source,model,"))
        #expect(lines[1].contains(",codex,gpt-5.5,60,10,40,"))
    }
}
