import Foundation

/// Exercises the installed executable with synthetic files and isolated storage.
/// Never reads real session roots or writes the user's caches.
enum SmokeCheck {
    static func run() -> Int32 {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("tktracker-smoke-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let sessions = root.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let file = sessions.appendingPathComponent("rollout-smoke.jsonl")
            let lines = [
                #"{"timestamp":"2026-09-07T10:00:00Z","type":"session_meta","payload":{"id":"smoke","cwd":"/synthetic/project"}}"#,
                #"{"timestamp":"2026-09-07T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-terra","service_tier":"default"}}"#,
                #"{"timestamp":"2026-09-07T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":20000,"output_tokens":1000},"model_context_window":1050000}}}"#
            ].joined(separator: "\n") + "\n"
            try Data(lines.utf8).write(to: file)
            let core = ScanCore(source: .codex, root: sessions, cacheURL: root.appendingPathComponent("cache.json"), profileId: "smoke")
            let archive = HistoryArchive(source: .codex, url: root.appendingPathComponent("archive.json"))
            let initial = core.refreshed(digests: [:], claims: ClaimMap())
            guard initial.digests.count == 1, let digest = initial.digests.values.first,
                  digest.totals.total == 101_000, abs(digest.cost - 0.176) < 0.000001 else {
                throw Failure.check("parsed token counts or cost")
            }
            guard core.saveCache(digests: initial.digests, claims: initial.claims) else { throw Failure.check("cache write") }
            let loaded = core.loadCache()
            guard loaded.digests.values.first?.records?.count == 1 else { throw Failure.check("request-record persistence") }
            try FileManager.default.removeItem(at: file)
            let pruned = core.refreshed(digests: loaded.digests, claims: loaded.claims)
            guard let updated = HistoryArchive.updated(archive.load(), digests: pruned.digests, claims: pruned.claims), archive.save(updated) else { throw Failure.check("archive persistence") }
            let stats = StatsBuilder.build(digests: Array(archive.load().digests.values), range: .all,
                now: Date(timeIntervalSince1970: 1_800_000_000))
            let document = try stats.jsonDocument()
            guard try JSONSerialization.jsonObject(with: Data(document.utf8)) is [String: Any],
                  abs(stats.cost - 0.176) < 0.000001 else { throw Failure.check("dashboard/JSON parity") }
            let csv = CSVExport.dailyByModel(digests: Array(pruned.digests.values), range: .all, now: Date(timeIntervalSince1970: 1_800_000_000))
            guard csv.contains("0.1760") else { throw Failure.check("CSV parity") }
            print("smoke OK: parsing, request records, cache, pruned history, JSON and CSV")
            return 0
        } catch {
            FileHandle.standardError.write(Data("smoke failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
    private enum Failure: LocalizedError {
        case check(String)
        var errorDescription: String? { if case .check(let detail) = self { return detail }; return nil }
    }
}
