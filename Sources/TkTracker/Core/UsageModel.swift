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

    var cacheWrite: Int64 { cacheWrite5m.saturatingAdding(cacheWrite1h) }
    var total: Int64 {
        input.saturatingAdding(output).saturatingAdding(cacheRead).saturatingAdding(cacheWrite)
    }
    var isEmpty: Bool { total == 0 && messages == 0 && webSearches == 0 }

    // Keep seven overflow checks outside callers' aggregation loops. Inlining
    // this body makes Swift's LICM alias analysis stall in FileDigest.totals.
    @inline(never)
    mutating func add(_ other: TokenTotals) {
        input = input.saturatingAdding(other.input)
        output = output.saturatingAdding(other.output)
        cacheRead = cacheRead.saturatingAdding(other.cacheRead)
        cacheWrite5m = cacheWrite5m.saturatingAdding(other.cacheWrite5m)
        cacheWrite1h = cacheWrite1h.saturatingAdding(other.cacheWrite1h)
        messages = messages.saturatingAdding(other.messages)
        webSearches = webSearches.saturatingAdding(other.webSearches)
    }

    /// Exact inverse of `add` for amounts previously added (used to reverse a
    /// provisional attribution); clamps like everything else on this type.
    mutating func subtract(_ other: TokenTotals) {
        input = input.saturatingSubtracting(other.input)
        output = output.saturatingSubtracting(other.output)
        cacheRead = cacheRead.saturatingSubtracting(other.cacheRead)
        cacheWrite5m = cacheWrite5m.saturatingSubtracting(other.cacheWrite5m)
        cacheWrite1h = cacheWrite1h.saturatingSubtracting(other.cacheWrite1h)
        messages = messages.saturatingSubtracting(other.messages)
        webSearches = webSearches.saturatingSubtracting(other.webSearches)
    }
}

/// Token counts come from untrusted files (transcripts, Claude Code's stats
/// cache); arithmetic on them clamps at the integer bounds instead of trapping
/// so one corrupt or crafted line can never crash a scan.
extension FixedWidthInteger {
    func saturatingSubtracting(_ other: Self) -> Self {
        let (result, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other < 0 ? .max : .min) : result
    }

    func saturatingAdding(_ other: Self) -> Self {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other < 0 ? .min : .max) : sum
    }
}

extension Int64 {
    /// Double → Int64 without the trap on out-of-range values; NaN maps to 0.
    static func saturating(_ value: Double) -> Int64 {
        guard !value.isNaN else { return 0 }
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }
}

/// Per-file usage aggregated by (UTC hour, model id) — fine enough for daily charts,
/// 5h billing blocks and range filters, compact enough to persist for every session.
struct HourBucket: Codable, Sendable, Equatable {
    var hour: Int64 // unix epoch seconds floored to the hour
    var model: String
    var totals: TokenTotals
    var timestamp: Double?
    var branch: String?
    var context: PricingContext?
    var contextTokens: Int64?
    var epoch: Double { timestamp ?? Double(hour) }
    var cost: Double { Pricing.cost(model: model, totals: totals, context: context) }
}

struct HourModelKey: Hashable, Sendable {
    let hour: Int64
    let model: String
}

/// Everything TkTracker remembers about one session file. Persisted in the scan cache,
/// so unchanged files are never re-read and deleted sessions keep their history.
struct FileDigest: Codable, Sendable, Identifiable, Equatable {
    var path: String
    var size: Int64 = 0
    var mtime: Double = 0
    /// Byte offset of the first unparsed line; appended lines are parsed incrementally.
    var offset: Int64 = 0

    /// Not persisted: each source keeps its own cache/archive files, and the
    /// pipeline that loads or parses a digest stamps it. Keeping it out of the
    /// encoding leaves the pre-source Claude cache format untouched.
    var source: UsageSource = .claude

    var sessionId: String
    var projectDir: String // Claude Code's encoded-cwd folder name; Codex digests encode cwd the same way so shared projects merge
    var cwd: String?
    var gitBranch: String?
    var aiTitle: String?
    var fallbackTitle: String?
    var firstTs: Double?
    var lastTs: Double?
    var lastModel: String?
    /// Prompt-side tokens of the most recent request — approximates live context size.
    var lastContextTokens: Int64 = 0
    /// Context window observed in the session's own usage events (Codex reports
    /// one per call); nil falls back to the per-model table.
    var contextWindow: Int64?
    /// Codex usage seen before the file has named a model, shown provisionally
    /// under the fallback model but kept re-attributable: the next scan reverses
    /// the provisional buckets and re-attributes once a turn_context arrives, so
    /// incremental scans always converge to what a full rescan would produce.
    var pendingBuckets: [HourBucket]?
    /// File no longer on disk; totals are retained as history.
    var missing: Bool = false

    /// Optional for backward compatibility. Old archives keep their exact token
    /// totals; only surviving transcripts are re-read to recover request timing.
    var records: [HourBucket]?
    var parentSessionId: String?
    var markers: [SessionMarker]?
    var serviceTier: ServiceTier?
    var parserRevision: Int?
    var profileId: String?
    var quota: QuotaSnapshot?

    var buckets: [HourBucket] = []
    /// Tail of recently seen (messageId:requestId) keys so incremental parses
    /// keep deduping streamed duplicates across the resume boundary.
    var recentKeys: [String] = []

    enum CodingKeys: String, CodingKey {
        // `source` deliberately absent — see its comment.
        case path, size, mtime, offset, sessionId, projectDir, cwd, gitBranch
        case aiTitle, fallbackTitle, firstTs, lastTs, lastModel, lastContextTokens
        case contextWindow, pendingBuckets, missing, buckets, recentKeys
        case records, parentSessionId, markers, serviceTier, parserRevision, profileId, quota
    }

    var id: String { path }
    var title: String? { aiTitle ?? fallbackTitle }
    var accountingBuckets: [HourBucket] { records ?? buckets }
    var projectKey: String { cwd.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? projectDir }

    var totals: TokenTotals {
        var t = TokenTotals()
        for b in buckets { t.add(b.totals) }
        return t
    }

    var cost: Double {
        accountingBuckets.reduce(0) { $0 + $1.cost }
    }
}

struct DigestCache: Codable, Sendable {
    var version: Int
    var digests: [String: FileDigest]
    /// Global (messageId:requestId) → owning file. See `ClaimMap` for why entries
    /// are never pruned and why the owner paths are interned.
    var claims: ClaimMap

    /// Set when this was read from an older on-disk format and upgraded in
    /// memory. Not persisted — `version` is normalized to current on load so the
    /// value is safe to write straight back, and this is the only remaining
    /// signal that the upgraded shape has not reached disk yet.
    var wasMigrated = false

    /// Set when a file existed but this build declined to read it — a format
    /// from a *newer* build. Not persisted.
    ///
    /// Without this, declining to read was worse than reading badly: `load()`
    /// returned an empty cache, and the caller went on to fold freshly-pruned
    /// digests into that empty cache and `save()` it straight back over the file
    /// it had just refused. For the history archive that is unrecoverable —
    /// those digests describe transcripts that no longer exist. Anything
    /// carrying this flag must never be written.
    var isUnwritable = false

    init(version: Int, digests: [String: FileDigest], claims: ClaimMap) {
        self.version = version
        self.digests = digests
        self.claims = claims
    }

    enum CodingKeys: String, CodingKey {
        case version, digests
        case claims // v2: [key: ownerPath]
        case claimPaths, claimOwners // v3: interned
    }

    /// Reads both cache generations. v2 (`claims` as a path-valued dictionary) is
    /// migrated in memory and rewritten in the v3 shape on the next save — it is
    /// never discarded, because the history archive shares this format and
    /// dropping it would permanently downgrade pruned sessions to estimates.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        digests = try container.decodeIfPresent([String: FileDigest].self, forKey: .digests) ?? [:]
        if let paths = try container.decodeIfPresent([String].self, forKey: .claimPaths) {
            let owners = try container.decodeIfPresent([String: Int32].self, forKey: .claimOwners) ?? [:]
            claims = ClaimMap(paths: paths, owners: owners)
        } else if let legacy = try container.decodeIfPresent([String: String].self, forKey: .claims) {
            claims = ClaimMap(legacy: legacy)
        } else {
            claims = ClaimMap()
        }
    }

    /// Writes whichever claim shape `version` implies.
    ///
    /// v2 keeps the path-valued dictionary so a file written here stays readable
    /// by TkTracker 1.4 and earlier. That matters for the history archive
    /// specifically: it is the only copy of usage for transcripts the vendor has
    /// already deleted, and an older build that cannot parse it *discards* it.
    /// So the archive stays on v2, while the disposable — and far larger — scan
    /// cache moves to the interned v3 shape.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(digests, forKey: .digests)
        if version >= 3 {
            try container.encode(claims.paths, forKey: .claimPaths)
            try container.encode(claims.owners, forKey: .claimOwners)
        } else {
            try container.encode(claims.legacyDictionary, forKey: .claims)
        }
    }
}
