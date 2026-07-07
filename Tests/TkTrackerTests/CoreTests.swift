import Testing
import Foundation
@testable import TkTracker

@Suite("TkTracker core")
final class CoreTests {
    private let dir: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("tktracker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // realpath: /var/folders → /private/var/folders, matching enumerator output
        // (URL.resolvingSymlinksInPath deliberately skips the /var alias).
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

    // MARK: helpers

    private func assistantLine(
        id: String,
        request: String,
        model: String = "claude-opus-4-8",
        ts: String = "2026-07-07T10:00:00.000Z",
        input: Int = 100,
        output: Int = 50,
        cacheRead: Int = 0,
        create5m: Int = 0,
        create1h: Int = 0
    ) -> String {
        let creation = create5m + create1h
        return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"\#(request)","cwd":"/tmp/proj","gitBranch":"main","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(creation),"cache_creation":{"ephemeral_5m_input_tokens":\#(create5m),"ephemeral_1h_input_tokens":\#(create1h)}}}}"#
    }

    @discardableResult
    private func write(_ lines: [String], name: String = "session-1.jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    private func scan(_ url: URL, previous: FileDigest? = nil) throws -> FileDigest {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return JSONLParser.scan(
            url: url,
            previous: previous,
            projectDir: "test-proj",
            size: (attrs[.size] as! NSNumber).int64Value,
            mtime: (attrs[.modificationDate] as! Date).timeIntervalSince1970
        )
    }

    // MARK: parsing & dedupe

    @Test func duplicateMessageLinesCountOnce() throws {
        // Multi-block assistant turns repeat the same usage on several JSONL lines.
        let url = try write([
            assistantLine(id: "msg_1", request: "req_1"),
            assistantLine(id: "msg_1", request: "req_1"),
            assistantLine(id: "msg_1", request: "req_2"), // retry: new request, counts again
            assistantLine(id: "msg_2", request: "req_3"),
        ])
        let totals = try scan(url).totals
        #expect(totals.messages == 3)
        #expect(totals.input == 300)
        #expect(totals.output == 150)
    }

    @Test func cacheSplitAndSyntheticSkipped() throws {
        let url = try write([
            assistantLine(id: "msg_1", request: "r1", model: "claude-fable-5",
                          input: 1000, output: 2000, cacheRead: 10_000, create5m: 500, create1h: 1500),
            #"{"type":"assistant","timestamp":"2026-07-07T10:01:00.000Z","message":{"id":"msg_x","model":"<synthetic>","usage":{"input_tokens":999,"output_tokens":999}}}"#,
        ])
        let totals = try scan(url).totals
        #expect(totals.input == 1000)
        #expect(totals.output == 2000)
        #expect(totals.cacheRead == 10_000)
        #expect(totals.cacheWrite5m == 500)
        #expect(totals.cacheWrite1h == 1500)

        // Fable 5: $10 in / $50 out per MTok; read 0.1x, 5m write 1.25x, 1h write 2x.
        let cost = Pricing.cost(model: "claude-fable-5", totals: totals)
        let parts: [Double] = [1000 * 10, 2000 * 50, 10_000 * 1, 500 * 12.5, 1500 * 20]
        let expected: Double = parts.reduce(0, +) / 1_000_000
        #expect(abs(cost - expected) < 1e-9)
    }

    @Test func legacyCacheFieldFallsBackTo5m() throws {
        let line = #"{"type":"assistant","timestamp":"2026-07-07T10:00:00.000Z","requestId":"r","message":{"id":"m","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":700}}}"#
        let url = try write([line])
        let totals = try scan(url).totals
        #expect(totals.cacheWrite5m == 700)
        #expect(totals.cacheWrite1h == 0)
    }

    @Test func incrementalResumeMatchesFullScan() throws {
        let first = [assistantLine(id: "msg_1", request: "r1", ts: "2026-07-07T10:00:00.000Z")]
        let url = try write(first)
        let digest1 = try scan(url)
        #expect(digest1.totals.messages == 1)

        let all = first + [
            assistantLine(id: "msg_1", request: "r1"), // duplicate spanning the resume boundary
            assistantLine(id: "msg_2", request: "r2", ts: "2026-07-07T11:30:00.000Z", input: 7),
        ]
        try write(all)
        let incremental = try scan(url, previous: digest1)
        let full = try scan(url)

        #expect(incremental.totals == full.totals)
        #expect(incremental.totals.messages == 2)
        #expect(incremental.totals.input == 107)
        #expect(incremental.buckets.count == 2) // two distinct hours
        #expect(incremental.offset == full.offset)
    }

    @Test func truncatedFileRescansFromScratch() throws {
        let url = try write([
            assistantLine(id: "msg_1", request: "r1"),
            assistantLine(id: "msg_2", request: "r2"),
        ])
        let digest = try scan(url)
        try write([assistantLine(id: "msg_9", request: "r9", input: 3)]) // rewritten shorter
        let rescanned = try scan(url, previous: digest)
        #expect(rescanned.totals.messages == 1)
        #expect(rescanned.totals.input == 3)
    }

    @Test func titlesAndMetadata() throws {
        let url = try write([
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>ignored</local-command-caveat>"}}"#,
            #"{"type":"user","cwd":"/Users/x/Documents/Proj","message":{"role":"user","content":"Build me a tracker\nwith details"}}"#,
            assistantLine(id: "msg_1", request: "r1"),
            #"{"type":"ai-title","aiTitle":"Build token tracker","sessionId":"s"}"#,
        ])
        let digest = try scan(url)
        #expect(digest.fallbackTitle == "Build me a tracker")
        #expect(digest.aiTitle == "Build token tracker")
        #expect(digest.title == "Build token tracker")
        #expect(digest.cwd == "/tmp/proj") // last cwd seen wins (assistant line)
        #expect(digest.lastModel == "claude-opus-4-8")
        #expect(digest.lastContextTokens == 100)
    }

    @Test func fastEpochParserMatchesFoundation() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for ts in ["2026-07-07T15:13:16.872Z", "2024-02-29T23:59:59.001Z", "2026-01-01T00:00:00.000Z"] {
            let fast = try #require(JSONLParser.epoch(fromISO8601: ts))
            let reference = try #require(iso.date(from: ts)).timeIntervalSince1970
            #expect(abs(fast - reference) < 0.001, "\(ts)")
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fast = try #require(JSONLParser.epoch(fromISO8601: "2026-07-07T15:13:16Z"))
        let reference = try #require(plain.date(from: "2026-07-07T15:13:16Z")).timeIntervalSince1970
        #expect(abs(fast - reference) < 0.001)
    }

    @Test func crossFileDeduplication() throws {
        // A resumed session copies the original's history lines into a new file;
        // only the original may count them.
        let root = dir.appendingPathComponent("root", isDirectory: true)
        let proj = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)

        let original = proj.appendingPathComponent("original.jsonl")
        let resumed = proj.appendingPathComponent("resumed.jsonl")
        try (assistantLine(id: "m1", request: "r1") + "\n")
            .write(to: original, atomically: true, encoding: .utf8)
        try (assistantLine(id: "m1", request: "r1") + "\n"
             + assistantLine(id: "m2", request: "r2", input: 5) + "\n")
            .write(to: resumed, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100)],
            ofItemAtPath: original.path
        )

        let core = ScanCore(root: root, cacheURL: dir.appendingPathComponent("cache.json"))

        // Cold scan: the shared event is counted exactly once, whichever file wins the claim.
        let cold = core.refreshed(digests: [:], claims: [:])
        #expect(cold.digests.values.reduce(0) { $0 + $1.totals.messages } == 2)
        #expect(cold.digests.values.reduce(Int64(0)) { $0 + $1.totals.input } == 105)
        #expect(cold.claims["m1:r1"] != nil)

        // With a persisted claim, ownership is deterministic: the copy skips the shared line.
        let seeded = core.refreshed(digests: [:], claims: ["m1:r1": original.path])
        #expect(seeded.digests[original.path]?.totals.messages == 1)
        #expect(seeded.digests[resumed.path]?.totals.messages == 1)
        #expect(seeded.digests[resumed.path]?.totals.input == 5)
        #expect(seeded.claims["m1:r1"] == original.path)
    }

    // MARK: stats-cache history import

    @Test func statsCacheHistoryImport() throws {
        let statsURL = dir.appendingPathComponent("stats-cache.json")
        try #"""
        {"version":3,
         "dailyActivity":[{"date":"2026-01-10","messageCount":10},{"date":"2026-01-11","messageCount":4}],
         "dailyModelTokens":[
            {"date":"2026-01-10","tokensByModel":{"claude-opus-4-6":1000}},
            {"date":"2026-01-11","tokensByModel":{"claude-opus-4-6":500}}],
         "modelUsage":{"claude-opus-4-6":{"inputTokens":100,"outputTokens":900,"cacheReadInputTokens":10000,"cacheCreationInputTokens":2000,"webSearchRequests":0}}}
        """#.write(to: statsURL, atomically: true, encoding: .utf8)

        // No transcripts: both days imported, io preserved, cache expanded by lifetime ratios.
        let full = try #require(StatsCacheImport.historyDigest(statsURL: statsURL, transcriptDigests: []))
        #expect(full.buckets.count == 2)
        let t = full.totals
        #expect(t.input + t.output == 1500)
        #expect(t.input == 150)          // fIn = 100/1000
        #expect(t.cacheRead == 15_000)   // 10 reads per io token
        #expect(t.cacheWrite5m == 3_000) // 2 writes per io token
        #expect(t.messages == 14)
        #expect(full.lastModel == "claude-opus-4-6")

        // With a transcript on Jan 11, only Jan 10 survives the cutoff.
        let cal = Calendar.current
        let df = DateFormatter()
        df.calendar = cal
        df.timeZone = cal.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let jan11 = cal.startOfDay(for: try #require(df.date(from: "2026-01-11")))
        let jan11Hour = Int64(jan11.addingTimeInterval(12 * 3600).timeIntervalSince1970 / 3600) * 3600

        var transcript = FileDigest(path: "/tmp/t.jsonl", sessionId: "s", projectDir: "p")
        var tt = TokenTotals()
        tt.input = 1
        tt.messages = 1
        transcript.buckets = [HourBucket(hour: jan11Hour, model: "claude-opus-4-8", totals: tt)]

        let cut = try #require(StatsCacheImport.historyDigest(statsURL: statsURL, transcriptDigests: [transcript]))
        #expect(cut.buckets.count == 1)
        #expect(cut.totals.input + cut.totals.output == 1000)

        // Missing file: no digest at all.
        #expect(StatsCacheImport.historyDigest(
            statsURL: dir.appendingPathComponent("nope.json"),
            transcriptDigests: []
        ) == nil)
    }

    // MARK: pricing

    @Test func legacyModelPricing() {
        #expect(Pricing.pricing(for: "claude-opus-4-5-20251101")?.input == 5)
        #expect(Pricing.pricing(for: "claude-sonnet-4-5-20250929")?.input == 3)
        #expect(Pricing.pricing(for: "claude-3-5-sonnet-20241022")?.input == 3)
        #expect(Pricing.pricing(for: "claude-opus-4-1")?.input == 15)
        #expect(Pricing.pricing(for: "claude-3-5-haiku-20241022")?.input == 0.8)
        #expect(Pricing.pricing(for: "claude-haiku-3-5")?.input == 0.8)
        #expect(Pricing.pricing(for: "claude-3-haiku-20240307")?.input == 0.25)
        #expect(Pricing.pricing(for: "claude-2.1")?.input == 8)
        #expect(Pricing.pricing(for: "claude-instant-1.2")?.input == 0.8)
        #expect(Pricing.pricing(for: "us.anthropic.claude-opus-4-8") != nil)
    }

    @Test func unknownModelHasNoPricing() {
        #expect(Pricing.pricing(for: "totally-new-model") == nil)
        var t = TokenTotals()
        t.input = 1_000_000
        #expect(Pricing.cost(model: "totally-new-model", totals: t) == 0)
    }

    @Test func webSearchBilling() {
        var t = TokenTotals()
        t.webSearches = 500
        #expect(abs(Pricing.cost(model: "claude-opus-4-8", totals: t) - 5.0) < 1e-9)
    }

    // MARK: blocks

    @Test func fiveHourBlockSegmentation() throws {
        var t = TokenTotals()
        t.output = 10
        t.messages = 1
        func agg(_ hours: [Int64]) -> [Int64: (TokenTotals, Double)] {
            Dictionary(uniqueKeysWithValues: hours.map { ($0 * 3600, (t, 1.0)) })
        }

        // Activity at hours 0,1,2 then 7,8: second block starts at hour 7.
        let block = try #require(StatsBuilder.currentBlock(hourAll: agg([0, 1, 2, 7, 8]), nowEpoch: 9 * 3600))
        #expect(block.start.timeIntervalSince1970 == 7 * 3600)
        #expect(block.totals.messages == 2)
        #expect(abs(block.cost - 2.0) < 1e-9)
        #expect(block.isActive) // 9h < 7h+5h

        let ended = try #require(StatsBuilder.currentBlock(hourAll: agg([0]), nowEpoch: 6 * 3600))
        #expect(!ended.isActive)

        // Hour 4 is within [0, 5h) even after a 3h gap: same block.
        let sameBlock = try #require(StatsBuilder.currentBlock(hourAll: agg([0, 4]), nowEpoch: 4.5 * 3600))
        #expect(sameBlock.start.timeIntervalSince1970 == 0)
        #expect(sameBlock.totals.messages == 2)
    }

    // MARK: model palette

    @Test func modelVersionParsing() {
        #expect(ModelFamily.version(of: "claude-opus-4-8") == 4.8)
        #expect(ModelFamily.version(of: "claude-fable-5") == 5.0)
        #expect(ModelFamily.version(of: "claude-haiku-4-5-20251001") == 4.5)
        #expect(ModelFamily.version(of: "claude-3-5-sonnet-20241022") == 3.5)
        #expect(ModelFamily.version(of: "claude-opus-4-5-20251101") == 4.5)
    }

    @Test func modelPaletteIsAllTimeAndOrdered() throws {
        var t = TokenTotals()
        t.output = 10
        t.messages = 1
        var digest = FileDigest(path: "/a.jsonl", sessionId: "s", projectDir: "p")
        let oldHour: Int64 = 1_700_000_000 / 3600 * 3600
        let now = Date(timeIntervalSince1970: Double(oldHour) + 40 * 86_400)
        let recentHour = Int64(now.timeIntervalSince1970 / 3600) * 3600
        digest.buckets = [
            HourBucket(hour: oldHour, model: "claude-opus-4-6", totals: t),
            HourBucket(hour: oldHour, model: "claude-sonnet-4-5-20250929", totals: t),
            HourBucket(hour: recentHour, model: "claude-opus-4-8", totals: t),
            HourBucket(hour: recentHour, model: "claude-fable-5", totals: t),
        ].sorted { $0.hour < $1.hour }

        // Palette order: family (fable, sonnet, opus, haiku), then version ascending.
        let all = StatsBuilder.build(digests: [digest], range: .all, now: now)
        #expect(all.modelPalette.map(\.name) == ["Fable 5", "Sonnet 4.5", "Opus 4.6", "Opus 4.8"])

        // Range filter must not change the palette (colors never repaint on filter).
        let today = StatsBuilder.build(digests: [digest], range: .today, now: now)
        #expect(today.modelPalette == all.modelPalette)
    }

    // MARK: chart unit, burn rate, deltas, CSV

    @Test func chartUnitSelection() throws {
        var digest = FileDigest(path: "/a.jsonl", sessionId: "s", projectDir: "p")
        var t = TokenTotals()
        t.output = 10
        t.messages = 1
        let base = try #require(JSONLParser.epoch(fromISO8601: "2026-01-05T12:00:00.000Z"))
        let hour0 = Int64(base / 3600) * 3600
        digest.buckets = [
            HourBucket(hour: hour0, model: "claude-opus-4-8", totals: t),
            HourBucket(hour: hour0 + 86_400, model: "claude-opus-4-8", totals: t), // next day, same week
        ]

        let now = Date(timeIntervalSince1970: base + 180 * 86_400)
        let all = StatsBuilder.build(digests: [digest], range: .all, now: now)
        #expect(all.chartUnit == .week)
        #expect(all.chart.count == 1) // Mon+Tue merge into one weekly bar
        #expect(all.chart.first?.tokens == 20)

        #expect(StatsBuilder.build(digests: [digest], range: .month, now: now).chartUnit == .day)
        #expect(StatsBuilder.build(digests: [digest], range: .today, now: now).chartUnit == .hour)
    }

    @Test func burnRateAndYesterdayDelta() throws {
        // now is 10:30Z; opus-4-8 output-only buckets so cost is output * $25/MTok.
        let nowEpoch = try #require(JSONLParser.epoch(fromISO8601: "2026-07-07T10:30:00.000Z"))
        let nowHour = Int64(nowEpoch / 3600) * 3600
        func bucket(_ hour: Int64, _ outputMTok: Int64) -> HourBucket {
            var t = TokenTotals()
            t.output = outputMTok * 1_000_000
            t.messages = 1
            return HourBucket(hour: hour, model: "claude-opus-4-8", totals: t)
        }
        var digest = FileDigest(path: "/a.jsonl", sessionId: "s", projectDir: "p")
        digest.buckets = [
            bucket(nowHour - 86_400 - 3600, 1), // yesterday 09:00 — full weight ($25)
            bucket(nowHour - 86_400, 1),        // yesterday 10:00 — half elapsed ($12.50)
            bucket(nowHour - 3600, 2),          // 09:00 ($50)
            bucket(nowHour, 1),                 // 10:00 so far ($25)
        ].sorted { $0.hour < $1.hour }

        let stats = StatsBuilder.build(digests: [digest], range: .today, now: Date(timeIntervalSince1970: nowEpoch))
        // Trailing hour: $25 (current) + $50 * 30/60 (previous) = $50/h.
        #expect(abs(stats.burnRatePerHour - 50) < 1e-9)
        // Today $75 vs $37.50 yesterday-by-now: +100%.
        let delta = try #require(stats.todayVsYesterday)
        #expect(abs(delta - 1.0) < 1e-9)
    }

    @Test func csvExport() throws {
        var digest = FileDigest(path: "/a.jsonl", sessionId: "s", projectDir: "p")
        var t = TokenTotals()
        t.input = 100
        t.output = 50
        t.messages = 1
        let epoch = try #require(JSONLParser.epoch(fromISO8601: "2026-07-07T12:00:00.000Z"))
        let hour = Int64(epoch / 3600) * 3600
        digest.buckets = [HourBucket(hour: hour, model: "claude-opus-4-8", totals: t)]

        let csv = CSVExport.dailyByModel(
            digests: [digest],
            range: .all,
            now: Date(timeIntervalSince1970: epoch + 3600)
        )
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == Substring(CSVExport.header))

        let df = DateFormatter()
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = Calendar.current.timeZone
        df.calendar = gregorian
        df.timeZone = Calendar.current.timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let day = df.string(from: Date(timeIntervalSince1970: Double(hour)))
        #expect(lines[1].hasPrefix("\(day),claude-opus-4-8,100,50,0,0,0,0,1,"))
    }

    // MARK: stats

    @Test func statsBuilderAggregates() throws {
        let url = try write([
            assistantLine(id: "m1", request: "r1", model: "claude-opus-4-8", ts: "2026-07-07T10:00:00.000Z"),
            assistantLine(id: "m2", request: "r2", model: "claude-fable-5", ts: "2026-07-07T11:00:00.000Z"),
        ])
        let digest = try scan(url)
        let now = try #require(JSONLParser.epoch(fromISO8601: "2026-07-07T12:00:00.000Z"))
        let stats = StatsBuilder.build(
            digests: [digest],
            range: .all,
            now: Date(timeIntervalSince1970: now)
        )
        #expect(stats.totals.messages == 2)
        #expect(stats.models.count == 2)
        #expect(stats.sessions.count == 1)
        #expect(stats.projects.count == 1)
        #expect(stats.projects.first?.name == "proj")
        #expect(stats.chart.count == 2) // one day x two families
        let shareSum = stats.models.reduce(0) { $0 + $1.share }
        #expect(abs(shareSum - 1.0) < 1e-9)
    }

    // MARK: robustness & environment

    @Test func hugeTokenCountsClampInsteadOfTrapping() throws {
        // Token counts are untrusted input: near-Int64.max values across lines
        // must clamp at the bounds, never trap and crash-loop every scan.
        let big = Int64.max - 10
        func hugeLine(_ id: String, _ req: String) -> String {
            #"{"type":"assistant","timestamp":"2026-07-07T10:00:00.000Z","requestId":"\#(req)","message":{"id":"\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":\#(big),"output_tokens":\#(big),"cache_read_input_tokens":\#(big),"cache_creation_input_tokens":\#(big)}}}"#
        }
        let url = try write([hugeLine("m1", "r1"), hugeLine("m2", "r2")])
        let digest = try scan(url)
        #expect(digest.totals.input == .max)
        #expect(digest.totals.total == .max)
        #expect(digest.lastContextTokens == .max)
        #expect(digest.totals.messages == 2)
    }

    @Test func statsCacheHugeValuesDoNotTrap() throws {
        let statsURL = dir.appendingPathComponent("stats-huge.json")
        try #"""
        {"dailyModelTokens":[{"date":"2026-01-10","tokensByModel":{"m":9223372036854775800,"n":9223372036854775800}}],
         "modelUsage":{"m":{"inputTokens":1,"outputTokens":1,"cacheReadInputTokens":9223372036854775800,"cacheCreationInputTokens":9223372036854775800}}}
        """#.write(to: statsURL, atomically: true, encoding: .utf8)
        let digest = try #require(StatsCacheImport.historyDigest(statsURL: statsURL, transcriptDigests: []))
        #expect(digest.totals.total == .max) // clamped, not crashed
    }

    @Test func contextWindows() {
        #expect(Pricing.contextWindow(for: "claude-opus-4-8") == 200_000)
        #expect(Pricing.contextWindow(for: "claude-fable-5") == 200_000)
        #expect(Pricing.contextWindow(for: "claude-sonnet-4-5[1m]") == 1_000_000)
    }

    @Test func csvDatesStayGregorianOnNonGregorianSystems() throws {
        var digest = FileDigest(path: "/a.jsonl", sessionId: "s", projectDir: "p")
        var t = TokenTotals()
        t.input = 1
        t.messages = 1
        let epoch = try #require(JSONLParser.epoch(fromISO8601: "2026-07-07T12:00:00.000Z"))
        digest.buckets = [HourBucket(hour: Int64(epoch / 3600) * 3600, model: "claude-opus-4-8", totals: t)]

        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = try #require(TimeZone(identifier: "UTC"))
        let csv = CSVExport.dailyByModel(
            digests: [digest], range: .all,
            now: Date(timeIntervalSince1970: epoch), calendar: buddhist
        )
        #expect(csv.contains("\n2026-07-07,")) // not Buddhist year 2569
    }

    @Test func statsCacheImportParsesGregorianOnNonGregorianSystems() throws {
        let statsURL = dir.appendingPathComponent("stats-cal.json")
        try #"""
        {"dailyModelTokens":[{"date":"2026-01-10","tokensByModel":{"claude-opus-4-6":1000}}]}
        """#.write(to: statsURL, atomically: true, encoding: .utf8)

        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = try #require(TimeZone(identifier: "UTC"))
        let digest = try #require(StatsCacheImport.historyDigest(
            statsURL: statsURL, transcriptDigests: [], calendar: buddhist))

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = try #require(TimeZone(identifier: "UTC"))
        let jan10 = try #require(DateComponents(
            calendar: gregorian, timeZone: gregorian.timeZone, year: 2026, month: 1, day: 10
        ).date)
        let expectedHour = Int64(jan10.addingTimeInterval(12 * 3600).timeIntervalSince1970 / 3600) * 3600
        #expect(digest.buckets.first?.hour == expectedHour) // 2026 CE, not 1483 CE
    }

    @Test func claudeConfigDirResolution() {
        let defaultEnv: [String: String] = [:]
        #expect(ScanCore.configRoot(environment: defaultEnv).path.hasSuffix("/.claude"))
        #expect(ScanCore.defaultRoot(environment: defaultEnv).path.hasSuffix("/.claude/projects"))
        #expect(ScanCore.defaultCacheURL(environment: defaultEnv).lastPathComponent == "scan-cache.json")

        let custom = ["CLAUDE_CONFIG_DIR": "/tmp/other-claude"]
        #expect(ScanCore.configRoot(environment: custom).path == "/tmp/other-claude")
        #expect(ScanCore.defaultRoot(environment: custom).path == "/tmp/other-claude/projects")

        // A custom profile gets its own scan cache, stable per root, distinct across roots.
        let customCache = ScanCore.defaultCacheURL(environment: custom).lastPathComponent
        #expect(customCache.hasPrefix("scan-cache-") && customCache != "scan-cache.json")
        #expect(ScanCore.defaultCacheURL(environment: custom).lastPathComponent == customCache)
        #expect(ScanCore.defaultCacheURL(environment: ["CLAUDE_CONFIG_DIR": "/tmp/third"])
            .lastPathComponent != customCache)
    }
}
