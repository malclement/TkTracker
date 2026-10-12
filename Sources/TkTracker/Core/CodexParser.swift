import Foundation

/// Incremental parser for OpenAI Codex CLI rollout files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
///
/// Usage comes from `event_msg`/`token_count` lines: each carries
/// `last_token_usage` — the token counts of exactly one API call — plus the
/// model's context window. Codex re-sends the previous snapshot unchanged
/// (identical `last_token_usage` *and* `total_token_usage`, usually only the
/// rate limits moved); those repeats are not new calls and are skipped, or
/// Codex usage comes out ~10% high on real data.
///
/// A forked subagent rollout opens with its own `session_meta`, then replays
/// the parent's history stamped with the fork instant (current CLIs also
/// replay the parent's `session_meta`; 0.125.0 replayed two of its
/// `token_count`s). Identity comes from the first header only, and the
/// replayed segment is never counted.
/// `cached_input_tokens` is the cached subset of `input_tokens`, so input is
/// split into uncached input, cache reads and any explicitly reported cache writes.
///
/// The model comes from the most recent `turn_context` line (it can change
/// mid-session). The rare usage seen before any turn context is held back and
/// attributed to the first model the file declares — or left unpriced if the file never names one.
enum CodexParser {
    /// Bumped to 3 for snapshot dedupe, fork-replay skipping and first-header
    /// identity. Older digests are re-parsed from scratch: their records carry
    /// the inflated usage and the parent's branch, which no in-place repair
    /// could undo.
    static let revision = 3
    private static let usageNeedle = Data("\"token_count\"".utf8)
    private static let metaNeedle = Data("\"session_meta\"".utf8)
    private static let turnNeedle = Data("\"turn_context\"".utf8)
    private static let userNeedle = Data("\"user_message\"".utf8)
    /// Current CLIs record prompts as `item_completed` events instead.
    private static let userItemNeedle = Data("\"UserMessage\"".utf8)
    private static let timestampNeedle = Data("\"timestamp\":\"".utf8)

    /// Attribution for usage in a file that never declares its model.
    static let fallbackModel = "unknown-codex"

    static func scan(
        url: URL,
        previous: FileDigest?,
        size: Int64,
        mtime: Double
    ) -> FileDigest {
        var digest: FileDigest
        if let prev = previous, size >= prev.offset, prev.parserRevision == revision {
            digest = prev
        } else {
            // New file, or truncated/rewritten below our offset: parse from scratch.
            digest = FileDigest(path: url.path, sessionId: fallbackSessionId(url: url), projectDir: "")
        }
        digest.source = .codex
        digest.missing = false
        digest.parserRevision = revision
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
    static func fallbackSessionId(url: URL) -> String {
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
        /// Only the file's first `session_meta` describes this thread.
        var hasSessionMetadata: Bool
        /// Set by a forked spawn's header: the lines that follow replay the
        /// parent until the timestamp moves off the fork instant.
        var replaying = false
        var replayStamp: Data?
        /// (last, total) of the previous usage snapshot, to skip re-sends.
        var lastUsageKey: String?
        var buckets: [HourModelKey: TokenTotals]
        var currentModel: String?
        /// Usage seen before the file names a model, keyed by hour.
        var pending: [Int64: TokenTotals] = [:]
        let decoder = JSONDecoder()

        init(digest: FileDigest) {
            self.digest = digest
            // A committed offset means the header (and any fork replay, which
            // Codex writes in one burst at spawn) was already consumed.
            hasSessionMetadata = digest.offset > 0
            lastUsageKey = digest.recentKeys.last
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
            d.recentKeys = lastUsageKey.map { [$0] } ?? []
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

        if state.replaying {
            // Only a handful of lines; the stamp leads every line.
            let stamp = timestamp(in: line)
            if state.replayStamp == nil { state.replayStamp = stamp }
            if stamp != nil, stamp == state.replayStamp {
                // Replayed usage still moves the re-send key: 0.125.0 re-sent
                // the parent's last snapshot as the child's first event.
                if line.prefix(512).range(of: usageNeedle) != nil { processLine(line, state: &state, replayed: true) }
                return
            }
            state.replaying = false
        }
        processLine(line, state: &state, replayed: false)
    }

    /// `{"timestamp":"<iso>",…` — the raw stamp bytes, compared verbatim.
    private static func timestamp(in line: Data) -> Data? {
        let head = line.prefix(96)
        guard let open = head.range(of: timestampNeedle) else { return nil }
        guard let close = head[open.upperBound...].firstIndex(of: 0x22) else { return nil }
        return Data(head[open.upperBound..<close])
    }

    private static func processLine(_ line: Data, state: inout ScanState, replayed: Bool) {
        // Rollout lines put the discriminating type fields right after the
        // timestamp — within the first ~80 bytes on every CLI version observed
        // (512 leaves 6× headroom). Bounding the needle search matters here:
        // response_item lines can run to megabytes, and scanning them whole
        // made cold scans an order of magnitude slower.
        let head = line.prefix(512)
        let hasUsage = head.range(of: usageNeedle) != nil
        let hasMeta = head.range(of: metaNeedle) != nil
        let hasTurn = head.range(of: turnNeedle) != nil
        let wantsUserLine = state.digest.fallbackTitle == nil
            && (head.range(of: userNeedle) != nil || head.range(of: userItemNeedle) != nil)
        let compaction = head.range(of: Data("context_compacted".utf8)) != nil
        guard hasUsage || hasMeta || hasTurn || wantsUserLine || compaction else { return }

        guard let raw = try? state.decoder.decode(RawCodexLine.self, from: Data(line)),
              let payload = raw.payload
        else {
            // An undecodable first header still claims the slot: otherwise a
            // replayed parent header would become this thread's identity.
            if hasMeta, (try? state.decoder.decode(RawCodexType.self, from: Data(line)))?.type == "session_meta" {
                state.hasSessionMetadata = true
            }
            return
        }

        switch raw.type {
        case "session_meta":
            guard !state.hasSessionMetadata else { return }
            state.hasSessionMetadata = true
            // Only agents the lead spawned are its subagents. /review and the
            // auto-approval guardian also carry a parent_thread_id, but they
            // are helpers, not delegated work.
            if let spawn = payload.source?.spawn {
                state.digest.parentSessionId = spawn.parent_thread_id ?? payload.parent_thread_id
                if payload.forked_from_id != nil { state.replaying = true }
            }
            // The filename UUID stays the fallback; never `session_id`, which
            // names the root of the spawn tree.
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
                // is the per-call delta. A snapshot equal to the previous one
                // in both counters is a re-send, not a call.
                guard let usage = payload.info?.lastTokenUsage else { return }
                if let total = payload.info?.totalTokenUsage {
                    let key = "\(usage.key)|\(total.key)"
                    if key == state.lastUsageKey { return }
                    state.lastUsageKey = key
                }
                guard !replayed else { return }
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
            case "user_message", "item_completed":
                let prompt = payload.type == "user_message" ? payload.message?.text
                    : payload.item.flatMap { $0.type == "UserMessage" ? $0.text : nil }
                guard state.digest.fallbackTitle == nil, let text = prompt else { return }
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
    let parent_thread_id: String?
    let forked_from_id: String?
    let cwd: String?
    let git: RawCodexGit?
    // turn_context
    let model: String?
    // event_msg
    let type: String?
    let message: RawCodexText?
    let item: RawCodexItem?
    let info: RawCodexTokenInfo?
    let service_tier: String?
    let speed: String?
    let git_branch: String?
    let source: RawCodexOrigin?
    let rate_limits: RawQuota?
}

private struct RawCodexType: Decodable {
    let type: String?
}

/// `item_completed` payloads; only a UserMessage's text is read.
private struct RawCodexItem: Decodable {
    var type: String?
    var text: String?

    init(from decoder: Decoder) throws {
        struct Part: Decodable { var text: String? }
        enum Keys: String, CodingKey { case type, content }
        let c = try? decoder.container(keyedBy: Keys.self)
        type = try? c?.decodeIfPresent(String.self, forKey: .type)
        let parts = try? c?.decodeIfPresent([Part].self, forKey: .content)
        text = parts?.compactMap(\.text).first
    }
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
    let totalTokenUsage: RawCodexUsage?
    let modelContextWindow: Int64?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case totalTokenUsage = "total_token_usage"
        case modelContextWindow = "model_context_window"
    }
}

private struct RawCodexUsage: Decodable {
    let inputTokens: Int64?
    let cachedInputTokens: Int64?
    let outputTokens: Int64?
    let cacheWriteTokens: Int64?
    let cacheCreationInputTokens: Int64?
    let reasoningOutputTokens: Int64?
    let totalTokens: Int64?

    var key: String {
        [inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens, totalTokens]
            .map { $0.map(String.init) ?? "-" }.joined(separator: ",")
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

/// `source` is `"cli"`, `{"subagent":"review"}`, `{"subagent":{"other":"guardian"}}`
/// or `{"subagent":{"thread_spawn":{…}}}` (`spawn` on older CLIs); tolerate all.
private struct RawCodexOrigin: Decodable {
    struct Spawn: Decodable { var parent_thread_id: String? }
    var spawn: Spawn?
    init(from decoder: Decoder) throws {
        struct Origin: Decodable {
            struct Subagent: Decodable {
                var spawn: Spawn?
                var thread_spawn: Spawn?
            }
            var subagent: Subagent?
        }
        let subagent = (try? Origin(from: decoder))?.subagent
        spawn = subagent?.thread_spawn ?? subagent?.spawn
    }
}
