import Testing
import Foundation
@testable import TkTracker

/// Tests for the actor that owns scan state.
///
/// Everything else in the suite tests pure functions. This is the one place with
/// real concurrency — a detached scan whose result lands back on the actor
/// after an unknown delay, a generation counter that has to drop that result if
/// the user reset in the meantime, and a dirty flag deciding what reaches disk.
/// Those are exactly the paths where a bug is invisible until someone's history
/// is wrong.
@Suite("Usage engine")
final class EngineTests {
    private let dir: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("tktracker-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: ScanCore.canonicalPath(raw), isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func assistantLine(id: String, request: String, input: Int = 100) -> String {
        #"{"type":"assistant","timestamp":"2026-07-07T10:00:00.000Z","cwd":"/Users/x/p","requestId":"\#(request)","message":{"id":"\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":\#(input),"output_tokens":50}}}"#
    }

    /// A one-source engine over a scratch root.
    private func makeEngine(root: URL, suffix: String) -> UsageEngine {
        let core = ScanCore(
            source: .claude,
            root: root,
            cacheURL: dir.appendingPathComponent("cache-\(suffix).json")
        )
        let archive = HistoryArchive(url: dir.appendingPathComponent("archive-\(suffix).json"))
        return UsageEngine(pipelines: [(core: core, archive: archive)])
    }

    private func seedSession(root: URL, name: String, id: String, request: String) throws {
        let project = root.appendingPathComponent("-Users-x-p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try (assistantLine(id: id, request: request) + "\n")
            .write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func refreshReportsDigestsAndClaimCount() async throws {
        let root = dir.appendingPathComponent("root-a", isDirectory: true)
        try seedSession(root: root, name: "s1.jsonl", id: "m1", request: "r1")

        let engine = makeEngine(root: root, suffix: "a")
        _ = await engine.bootstrap()
        let report = await engine.refresh(sources: [.claude])

        #expect(report.digests.count == 1)
        #expect(report.claimCount == 1)
        #expect(report.unreadable.isEmpty)
        #expect(!report.cacheWriteFailed)
        #expect(report.duration >= 0)
    }

    @Test func flushPersistsAndClearsDirty() async throws {
        let root = dir.appendingPathComponent("root-b", isDirectory: true)
        try seedSession(root: root, name: "s1.jsonl", id: "m1", request: "r1")

        let engine = makeEngine(root: root, suffix: "b")
        _ = await engine.bootstrap()
        let cacheURL = dir.appendingPathComponent("cache-b.json")
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))

        // `lastSave` starts at .distantPast, so the throttle is already expired
        // on the first refresh and the cache lands immediately — new state is
        // not held in memory for 15 seconds before it is ever durable.
        _ = await engine.refresh(sources: [.claude])
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        // Flushing again is a no-op: the write cleared the dirty flag, so an
        // idle app doesn't rewrite a multi-megabyte cache on every tick.
        let before = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date
        #expect(await engine.flush())
        let after = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date
        #expect(before == after)

        // Round-trips: what was written decodes back to the same claims.
        let written = try JSONDecoder().decode(DigestCache.self, from: try Data(contentsOf: cacheURL))
        #expect(written.version == ScanCore.cacheVersion)
        #expect(written.claims.count == 1)
    }

    @Test func bootstrapReadsWhatFlushWrote() async throws {
        let root = dir.appendingPathComponent("root-c", isDirectory: true)
        try seedSession(root: root, name: "s1.jsonl", id: "m1", request: "r1")

        let first = makeEngine(root: root, suffix: "c")
        _ = await first.bootstrap()
        _ = await first.refresh(sources: [.claude])
        _ = await first.flush()

        // A second engine over the same cache sees the state without rescanning.
        let second = makeEngine(root: root, suffix: "c")
        let booted = await second.bootstrap()
        #expect(booted.digests.count == 1)
        #expect(booted.claimCount == 1)
        #expect(booted.digests.first?.totals.messages == 1)
    }

    @Test func bootstrapPersistsAMigratedCacheOnce() async throws {
        let root = dir.appendingPathComponent("root-d", isDirectory: true)
        try seedSession(root: root, name: "s1.jsonl", id: "m1", request: "r1")

        // Hand-write a v2 cache, the pre-1.5 shape.
        let cacheURL = dir.appendingPathComponent("cache-d.json")
        let legacy = #"{"version":2,"claims":{"m9:r9":"/gone.jsonl"},"digests":{}}"#
        try Data(legacy.utf8).write(to: cacheURL)

        let engine = makeEngine(root: root, suffix: "d")
        _ = await engine.bootstrap()
        // Migration marks the state dirty, so the upgraded shape reaches disk on
        // the next flush rather than being re-migrated on every launch.
        #expect(await engine.flush())

        let text = String(decoding: try Data(contentsOf: cacheURL), as: UTF8.self)
        #expect(text.contains("claimPaths"))
        #expect(!text.contains("\"claims\""))

        let reread = try JSONDecoder().decode(DigestCache.self, from: try Data(contentsOf: cacheURL))
        #expect(reread.version == ScanCore.cacheVersion)
        #expect(!reread.wasMigrated)
        #expect(reread.claims["m9:r9"] == "/gone.jsonl") // the seeded claim survived
    }

    @Test func resetClearsScanCacheButKeepsArchivedHistory() async throws {
        let root = dir.appendingPathComponent("root-e", isDirectory: true)
        try seedSession(root: root, name: "s1.jsonl", id: "m1", request: "r1")

        let engine = makeEngine(root: root, suffix: "e")
        _ = await engine.bootstrap()
        _ = await engine.refresh(sources: [.claude])

        // Claude Code prunes the transcript; its exact usage enters the archive.
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("-Users-x-p/s1.jsonl")
        )
        let pruned = await engine.refresh(sources: [.claude])
        #expect(pruned.digests.first?.missing == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("archive-e.json").path))

        // "Rescan everything" must not lose it — the file can never be re-read.
        let afterReset = await engine.reset(rescanning: [.claude])
        #expect(afterReset.digests.count == 1)
        #expect(afterReset.digests.first?.missing == true)
        #expect(afterReset.digests.first?.totals.input == 100)
        // The archived claim is seeded back, so a resume cannot re-count it.
        #expect(afterReset.claimCount == 1)
    }

    @Test func resetDropsAnInFlightScanInsteadOfResurrectingIt() async throws {
        // A refresh whose scan started before a reset must discard its result, or
        // "Rescan everything" would silently undo itself.
        //
        // Racing two calls cannot produce that interleaving reliably, so this
        // drives it through the engine's interleave seam. The setup is arranged so
        // the stale result and the correct one differ observably: the session file
        // is deleted *during* the in-flight scan, so a reset sees an empty
        // directory while the scan already in progress still holds the session.
        // Applying the stale result would resurrect it.
        let root = dir.appendingPathComponent("root-f", isDirectory: true)
        try seedSession(root: root, name: "s1.jsonl", id: "m1", request: "r1")
        let file = root.appendingPathComponent("-Users-x-p/s1.jsonl")

        let engine = makeEngine(root: root, suffix: "f")
        _ = await engine.bootstrap()
        let before = await engine.refresh(sources: [.claude])
        #expect(before.digests.count == 1) // the session is known

        await engine.setScanInterleaveHook { [engine] in
            // Runs while the next scan's result is pending.
            try? FileManager.default.removeItem(at: file)
            _ = await engine.reset(rescanning: [.claude])
        }

        let stale = await engine.refresh(sources: [.claude])
        // The purge stands: no digest, because the file was gone at reset time and
        // nothing had archived it yet. Without the generation guard the in-flight
        // scan's snapshot would have written the session back here.
        #expect(stale.digests.isEmpty, "stale scan result must not survive a reset")
        #expect(stale.claimCount == 0)

        // And the state is genuinely settled, not merely empty for one call.
        let after = await engine.refresh(sources: [.claude])
        #expect(after.digests.isEmpty)
    }

    @Test func cacheWriteFailureIsReported() async throws {
        // ScanHealth.cacheWriteFailed drives the UI's "cache could not be saved"
        // banner. Nothing exercised the failing path, so the whole chain from
        // saveCache -> flush -> RefreshReport -> ScanHealth was unverified.
        let root = dir.appendingPathComponent("root-h", isDirectory: true)
        try seedSession(root: root, name: "s1.jsonl", id: "m1", request: "r1")

        // Point the cache at a path that cannot be created: an existing *file*
        // stands where the parent directory would have to be.
        let blocker = dir.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let core = ScanCore(
            source: .claude,
            root: root,
            cacheURL: blocker.appendingPathComponent("nested/cache.json")
        )
        let archive = HistoryArchive(url: dir.appendingPathComponent("archive-h.json"))
        let engine = UsageEngine(pipelines: [(core: core, archive: archive)])

        _ = await engine.bootstrap()
        let report = await engine.refresh(sources: [.claude])
        #expect(report.cacheWriteFailed, "an unwritable cache path must be reported")
        #expect(!report.digests.isEmpty, "the scan itself still succeeds")

        // And it reaches the UI-facing summary.
        let health = ScanHealth(
            lastScan: Date(), lastScanDuration: report.duration,
            digestCount: report.digests.count, claimCount: report.claimCount,
            unreadableFiles: report.unreadable, cacheWriteFailed: report.cacheWriteFailed
        )
        #expect(health.hasProblem)
        #expect(health.problemSummary == "cache could not be saved")

        // Flush keeps reporting failure rather than silently marking state clean.
        #expect(!(await engine.flush()))
    }

    @Test func staleProjectAttributionIsRepairedWithoutReparsing() async throws {
        // The symlinked-root fix computes projectDir during discovery but only
        // stored it when a file was parsed — and unchanged files are never
        // re-parsed, so an existing install would have kept its wrong project
        // names forever.
        let root = dir.appendingPathComponent("root-i", isDirectory: true)
        try seedSession(root: root, name: "s1.jsonl", id: "m1", request: "r1")
        let path = root.appendingPathComponent("-Users-x-p/s1.jsonl").path

        let core = ScanCore(
            source: .claude,
            root: root,
            cacheURL: dir.appendingPathComponent("cache-i.json")
        )
        let first = core.refreshed(digests: [:], claims: ClaimMap())
        #expect(first.digests[path]?.projectDir == "-Users-x-p")

        // Simulate a cache written by the buggy build: right digest, wrong project.
        var damaged = try #require(first.digests[path])
        damaged.projectDir = "private"
        let repaired = core.refreshed(digests: [path: damaged], claims: first.claims)

        #expect(repaired.digests[path]?.projectDir == "-Users-x-p")
        #expect(repaired.changed, "a repair must mark the cache dirty so it persists")
        // Repaired in place — the file was not re-read, so the offset is untouched.
        #expect(repaired.digests[path]?.offset == damaged.offset)
        #expect(repaired.digests[path]?.totals.messages == 1)
    }

    @Test func symlinkedRootStillAttributesProjectsCorrectly() throws {
        // The original defect: when the root path did not literally prefix the
        // enumerated file path, every project name became the first component of
        // the absolute path ("private").
        // The realistic shape is a symlinked *ancestor*, which is how /var ->
        // /private/var and a symlinked CLAUDE_CONFIG_DIR both present: the root
        // itself is a real directory, but the path used to reach it is not the
        // path the enumerator reports back.
        let realParent = dir.appendingPathComponent("real-parent", isDirectory: true)
        let realRoot = realParent.appendingPathComponent("projects", isDirectory: true)
        let project = realRoot.appendingPathComponent("-Users-x-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try (assistantLine(id: "m1", request: "r1") + "\n")
            .write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let linkedParent = dir.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        let rootViaLink = linkedParent.appendingPathComponent("projects", isDirectory: true)

        let core = ScanCore(
            source: .claude,
            root: rootViaLink, // same directory, reached through a symlinked parent
            cacheURL: dir.appendingPathComponent("cache-link.json")
        )
        let result = core.refreshed(digests: [:], claims: ClaimMap())
        let digest = try #require(result.digests.values.first)
        #expect(digest.projectDir == "-Users-x-proj")
        #expect(digest.projectDir != "private")
    }

    @Test func unreadableFilesAreReportedNotSwallowed() async throws {
        let root = dir.appendingPathComponent("root-g", isDirectory: true)
        try seedSession(root: root, name: "s1.jsonl", id: "m1", request: "r1")
        let file = root.appendingPathComponent("-Users-x-p/s1.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let engine = makeEngine(root: root, suffix: "g")
        _ = await engine.bootstrap()
        let report = await engine.refresh(sources: [.claude])

        // The old behaviour was for this to vanish into a `try?` and show up
        // only as a smaller number.
        #expect(report.unreadable.count == 1)
        #expect(report.unreadable.first?.hasSuffix("s1.jsonl") == true)
    }

    @Test func scanHealthSummarizesProblemsForTheUI() {
        var health = ScanHealth()
        #expect(!health.hasProblem)
        #expect(health.problemSummary == nil)

        health.unreadableFiles = ["/a.jsonl"]
        #expect(health.hasProblem)
        #expect(health.problemSummary == "1 session file could not be read")

        health.unreadableFiles = ["/a.jsonl", "/b.jsonl"]
        health.cacheWriteFailed = true
        #expect(health.problemSummary == "2 session files could not be read · cache could not be saved")
    }
}
