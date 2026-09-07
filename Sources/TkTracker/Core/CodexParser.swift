import Foundation

/// Incremental parser for OpenAI Codex CLI rollout files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
///
/// Usage comes from `event_msg`/`token_count` lines: each carries
/// `last_token_usage` — the token counts of exactly one API call — plus the
/// model's context window. Summing those per-call counts is exactly-once by
/// construction (verified on real data: resumes, forks and subagent threads
/// never replay another file's token events), and unlike the cumulative
/// `total_token_usage` it is immune to the rebase that compaction applies.
/// `cached_input_tokens` is the cached subset of `input_tokens`, so input is
/// split into uncached input + cache reads; OpenAI bills no cache writes.
///
/// The model comes from the most recent `turn_context` line (it can change
/// mid-session). The rare usage seen before any turn context is held back and
/// attributed to the first model the file declares — or to "gpt-5" if the file
/// never names one, so a handful of tokens still price at the family rate.
enum CodexParser {
    private static let usageNeedle = Data("\"token_count\"".utf8)
    private static let metaNeedle = Data("\"session_meta\"".utf8)
    private static let turnNeedle = Data("\"turn_context\"".utf8)
    private static let userNeedle = Data("\"user_message\"".utf8)

    /// Attribution for usage in a file that never declares its model.
    static let fallbackModel = "unknown-codex"

    static func scan(
        url: URL,
        previous: FileDigest?,
        size: Int64,
        mtime: Double
    ) -> FileDigest {
        var digest: FileDigest
        if let prev = previous, size >= prev.offset, prev.parserRevision == 2 {
            digest = prev
        } else {
            // New file, or truncated/rewritten below our offset: parse from scratch.
            digest = FileDigest(path: url.path, sessionId: fallbackSessionId(url: url), projectDir: "")
        }
        digest.source = .codex
        digest.missing = false
        digest.parserRevision = 2
        if digest.records == nil { digest.records = [] }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return previous ?? digest }
        defer { try? handle.close() }

        var state = ScanState(digest: digest)
        JSONLChunker.forEachLine(
            handle: handle,
            from: digest.offset,
            onLine: { processLine($0, state: &state) },
            commit: { state.digest.offset = $0 }
        )

        digest = state.finalized()
        digest.size = size
        digest.mtime = mtime
        return digest
    }

    /// Rollout file names end in the thread UUID (`rollout-<timestamp>-<uuid>`);
    /// used until the session_meta line supplies the id directly.
    private static func fallbackSessionId(url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if stem.count >= 36 {
            let candidate = String(stem.suffix(36))
            if UUID(uuidString: candidate) != nil { return candidate }
        }
        return stem
    }

    /// Claude Code's project-folder encoding: its JS regex replaces every
    /// non-alphanumeric UTF-16 code unit with "-" (so a surrogate pair becomes
    /// two dashes). Codex digests must reproduce that exactly, or the same
    /// directory worked on with both tools splits into two project rows.
    static func encodeProjectDir(_ cwd: String) -> String {
        String(cwd.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: // 0-9 A-Z a-z
                return Character(UnicodeScalar(unit)!)
            default:
                return "-"
            }
        })
    }

    // MARK: - Per-line processing

    private struct ScanState {
        var digest: FileDigest
        var buckets: [HourModelKey: TokenTotals]
        var currentModel: String?
        /// Usage seen before the file names a model, keyed by hour.
        var pending: [Int64: TokenTotals] = [:]
        let decoder = JSONDecoder()

        init(digest: FileDigest) {
            self.digest = digest
            var b: [HourModelKey: TokenTotals] = [:]
            for bucket in digest.buckets {
                b[HourModelKey(hour: bucket.hour, model: bucket.model)] = bucket.totals
            }
            // A previous scan ended before the file named a model: reverse its
            // provisional fallback attribution and put the usage back in
            // pending, so this scan can still hand it to the real model. This
            // keeps every incremental scan sequence convergent with a full
            // rescan of the finished file.
            if let provisional = digest.pendingBuckets {
                for bucket in provisional {
                    let key = HourModelKey(hour: bucket.hour, model: CodexParser.fallbackModel)
                    if var reduced = b[key] {
                        reduced.subtract(bucket.totals)
                        if reduced.isEmpty { b[key] = nil } else { b[key] = reduced }
                    }
                    pending[bucket.hour, default: TokenTotals()].add(bucket.totals)
                }
            }
            self.buckets = b
            // Across incremental scans the last known model carries the state.
            self.currentModel = digest.lastModel
        }

        mutating func adopt(model: String) {
            currentModel = model
            digest.lastModel = model
            if !pending.isEmpty, let records = digest.records {
                digest.records = records.map { record in
                    var r = record
                    if r.model == CodexParser.fallbackModel { r.model = model }
                    return r
                }
            }
            guard !pending.isEmpty else { return }
            for (hour, totals) in pending {
                buckets[HourModelKey(hour: hour, model: model), default: TokenTotals()].add(totals)
            }
            pending = [:]
        }

        mutating func add(hour: Int64, totals: TokenTotals) {
            if let model = currentModel {
                buckets[HourModelKey(hour: hour, model: model), default: TokenTotals()].add(totals)
            } else {
                pending[hour, default: TokenTotals()].add(totals)
            }
        }

        func finalized() -> FileDigest {
            var d = digest
            var all = buckets
            // The file hasn't named a model (yet): show the stray usage under
            // the family default rather than dropping it, but keep it recorded
            // in pendingBuckets — the attribution stays provisional and the
            // next scan reverses it, so `lastModel` is deliberately NOT set.
            for (hour, totals) in pending {
                all[HourModelKey(hour: hour, model: CodexParser.fallbackModel), default: TokenTotals()].add(totals)
            }
            d.pendingBuckets = pending.isEmpty ? nil : pending
                .map { HourBucket(hour: $0.key, model: CodexParser.fallbackModel, totals: $0.value) }
                .sorted { $0.hour < $1.hour }
            d.buckets = all
                .map { HourBucket(hour: $0.key.hour, model: $0.key.model, totals: $0.value) }
                .sorted { ($0.hour, $0.model) < ($1.hour, $1.model) }
            return d
        }
    }

    private static func processLine(_ slice: Data, state: inout ScanState) {
        var line = slice
        if line.last == 0x0D { line = line.dropLast() } // CRLF safety
        guard !line.isEmpty else { return }

        // Rollout lines put the discriminating type fields right after the
        // timestamp — within the first ~80 bytes on every CLI version observed
        // (512 leaves 6× headroom). Bounding the needle search matters here:
        // response_item lines can run to megabytes, and scanning them whole
        // made cold scans an order of magnitude slower.
        let head = line.prefix(512)
        let hasUsage = head.range(of: usageNeedle) != nil
        let hasMeta = head.range(of: metaNeedle) != nil
        let hasTurn = head.range(of: turnNeedle) != nil
        let wantsUserLine = state.digest.fallbackTitle == nil && head.range(of: userNeedle) != nil
        let compaction = head.range(of: Data("context_compacted".utf8)) != nil
        guard hasUsage || hasMeta || hasTurn || wantsUserLine || compaction else { return }

        guard let raw = try? state.decoder.decode(RawCodexLine.self, from: Data(line)),
              let payload = raw.payload
        else { return }

        switch raw.type {
        case "session_meta":
            state.digest.parentSessionId = payload.source?.parentThreadId
            if let id = payload.id, !id.isEmpty { state.digest.sessionId = id }
            if let cwd = payload.cwd, !cwd.isEmpty {
                state.digest.cwd = cwd
                if state.digest.projectDir.isEmpty {
                    state.digest.projectDir = encodeProjectDir(cwd)
                }
            }
            if let branch = payload.git?.branch, !branch.isEmpty { state.digest.gitBranch = branch }

        case "turn_context":
            if let branch = payload.git?.branch ?? payload.git_branch { state.digest.gitBranch = branch }
            state.digest.serviceTier = ServiceTier(observed: payload.service_tier ?? payload.speed)
            if let model = payload.model, !model.isEmpty { state.adopt(model: model) }
            if let cwd = payload.cwd, !cwd.isEmpty {
                state.digest.cwd = cwd
                if state.digest.projectDir.isEmpty {
                    state.digest.projectDir = encodeProjectDir(cwd)
                }
            }

        case "event_msg":
            switch payload.type {
            case "token_count":
                if let quota = payload.rate_limits, !quota.windows.isEmpty,
                   let timestamp = raw.timestamp.flatMap(JSONLParser.epoch(fromISO8601:)) {
                    state.digest.quota = QuotaSnapshot(observedAt: Date(timeIntervalSince1970: timestamp), origin: "Local session", windows: quota.windows)
                }
                // `info` is null on rate-limit-only updates; `last_token_usage`
                // is the per-call delta (the cumulative counter rebases on
                // compaction and would undercount).
                guard let usage = payload.info?.lastTokenUsage else { return }
                if let window = payload.info?.modelContextWindow, window > 0 {
                    state.digest.contextWindow = window
                }
                let rawInput = max(usage.inputTokens ?? 0, 0)
                let cached = min(max(usage.cachedInputTokens ?? 0, 0), max(rawInput, 0))
                var t = TokenTotals()
                let writes = min(max(usage.cacheWriteTokens ?? usage.cacheCreationInputTokens ?? 0, 0), rawInput - cached)
                t.input = rawInput - cached - writes
                t.cacheWrite5m = writes
                t.cacheRead = cached
                t.output = max(usage.outputTokens ?? 0, 0)
                guard t.total > 0 else { return }
                t.messages = 1

                let ts = raw.timestamp.flatMap(JSONLParser.epoch(fromISO8601:))
                    ?? state.digest.lastTs ?? Date().timeIntervalSince1970
                let hour = Int64(ts / 3600) * 3600
                state.add(hour: hour, totals: t)
                state.digest.records?.append(HourBucket(hour: hour, model: state.currentModel ?? fallbackModel, totals: t,
                    timestamp: raw.timestamp.flatMap(JSONLParser.epoch(fromISO8601:)), branch: state.digest.gitBranch,
                    context: PricingContext(date: Date(timeIntervalSince1970: ts),
                        tier: payload.service_tier.map(ServiceTier.init(observed:)) ?? state.digest.serviceTier ?? .unknown,
                        promptTokens: rawInput), contextTokens: rawInput))

                state.digest.firstTs = min(state.digest.firstTs ?? ts, ts)
                state.digest.lastTs = max(state.digest.lastTs ?? ts, ts)
                if let model = state.currentModel { state.digest.lastModel = model }
                state.digest.lastContextTokens = max(rawInput, 0)

            case "context_compacted":
                if let ts = raw.timestamp.flatMap(JSONLParser.epoch(fromISO8601:)) {
                    if state.digest.markers == nil { state.digest.markers = [] }
                    state.digest.markers?.append(SessionMarker(timestamp: ts, kind: "Compaction"))
                }
            case "user_message":
                guard state.digest.fallbackTitle == nil, let text = payload.message?.text else { return }
                let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                    .first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !firstLine.isEmpty, !firstLine.hasPrefix("<") {
                    state.digest.fallbackTitle = String(firstLine.prefix(120))
                }

            default:
                break
            }

        default:
            break
        }
    }
}

// MARK: - Raw line shapes (lenient: everything optional)

private struct RawCodexLine: Decodable {
    let timestamp: String?
    let type: String?
    let payload: RawCodexPayload?
}

private struct RawCodexPayload: Decodable {
    // session_meta
    let id: String?
    let cwd: String?
    let git: RawCodexGit?
    // turn_context
    let model: String?
    // event_msg
    let type: String?
    let message: RawCodexText?
    let info: RawCodexTokenInfo?
    let service_tier: String?
    let speed: String?
    let git_branch: String?
    let source: RawCodexOrigin?
    let rate_limits: RawQuota?
}

private struct RawCodexGit: Decodable {
    let branch: String?
}

/// `message` is a plain string on user prompts; tolerate anything else.
private enum RawCodexText: Decodable {
    case text(String)
    case other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s) } else { self = .other }
    }

    var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

private struct RawCodexTokenInfo: Decodable {
    let lastTokenUsage: RawCodexUsage?
    let modelContextWindow: Int64?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case modelContextWindow = "model_context_window"
    }
}

private struct RawCodexUsage: Decodable {
    let inputTokens: Int64?
    let cachedInputTokens: Int64?
    let outputTokens: Int64?
    let cacheWriteTokens: Int64?
    let cacheCreationInputTokens: Int64?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

private struct RawCodexOrigin: Decodable {
    var parentThreadId: String?
    init(from decoder: Decoder) throws {
        struct Origin: Decodable {
            struct Subagent: Decodable {
                struct Spawn: Decodable { var parent_thread_id: String? }
                var spawn: Spawn?
            }
            var subagent: Subagent?
        }
        parentThreadId = (try? Origin(from: decoder))?.subagent?.spawn?.parent_thread_id
    }
}
