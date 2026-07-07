import Foundation

/// Token counts for one aggregation bucket.
struct TokenTotals: Codable, Sendable, Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite5m: Int64 = 0
    var cacheWrite1h: Int64 = 0
    var messages: Int = 0
    var webSearches: Int = 0

    var cacheWrite: Int64 { cacheWrite5m + cacheWrite1h }
    var total: Int64 { input + output + cacheRead + cacheWrite }
    var isEmpty: Bool { total == 0 && messages == 0 }

    mutating func add(_ other: TokenTotals) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        messages += other.messages
        webSearches += other.webSearches
    }
}

/// Per-file usage aggregated by (UTC hour, model id) — fine enough for daily charts,
/// 5h billing blocks and range filters, compact enough to persist for every session.
struct HourBucket: Codable, Sendable, Equatable {
    var hour: Int64 // unix epoch seconds floored to the hour
    var model: String
    var totals: TokenTotals
}

struct HourModelKey: Hashable, Sendable {
    let hour: Int64
    let model: String
}

/// Everything TkTracker remembers about one session file. Persisted in the scan cache,
/// so unchanged files are never re-read and deleted sessions keep their history.
struct FileDigest: Codable, Sendable, Identifiable {
    var path: String
    var size: Int64 = 0
    var mtime: Double = 0
    /// Byte offset of the first unparsed line; appended lines are parsed incrementally.
    var offset: Int64 = 0

    var sessionId: String
    var projectDir: String // encoded folder name under ~/.claude/projects
    var cwd: String?
    var gitBranch: String?
    var aiTitle: String?
    var fallbackTitle: String?
    var firstTs: Double?
    var lastTs: Double?
    var lastModel: String?
    /// Prompt-side tokens of the most recent request — approximates live context size.
    var lastContextTokens: Int64 = 0
    /// File no longer on disk; totals are retained as history.
    var missing: Bool = false

    var buckets: [HourBucket] = []
    /// Tail of recently seen (messageId:requestId) keys so incremental parses
    /// keep deduping streamed duplicates across the resume boundary.
    var recentKeys: [String] = []

    var id: String { path }
    var title: String? { aiTitle ?? fallbackTitle }

    var totals: TokenTotals {
        var t = TokenTotals()
        for b in buckets { t.add(b.totals) }
        return t
    }

    var cost: Double {
        buckets.reduce(0) { $0 + Pricing.cost(model: $1.model, totals: $1.totals) }
    }
}

struct DigestCache: Codable, Sendable {
    var version: Int
    var digests: [String: FileDigest]
    /// Global (messageId:requestId) → owning file path. Session resumes/forks copy
    /// history lines into new files; the claim table keeps each API call counted once.
    var claims: [String: String]
}
