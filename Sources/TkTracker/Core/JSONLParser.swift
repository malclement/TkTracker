import Foundation

/// Incremental parser for Claude Code session JSONL files.
///
/// Only lines that can carry usage or titles are JSON-decoded (cheap byte-needle
/// pre-filter), and parsing resumes from the digest's byte offset so a growing
/// session costs only its appended bytes. Assistant messages that span several
/// JSONL lines repeat the same usage payload — deduped by (messageId, requestId).
enum JSONLParser {
    // Claude Code writes compact JSON, so needles can include the colon.
    private static let usageNeedle = Data("\"usage\":".utf8)
    private static let titleNeedle = Data("\"aiTitle\":".utf8)
    private static let userNeedle = Data("\"type\":\"user\"".utf8)

    private static let dedupeWindow = 400
    private static let dedupePersisted = 250

    static func scan(
        url: URL,
        previous: FileDigest?,
        projectDir: String,
        size: Int64,
        mtime: Double,
        claims: ClaimTable? = nil
    ) -> FileDigest {
        let sessionId = url.deletingPathExtension().lastPathComponent
        var digest: FileDigest
        if let prev = previous, size >= prev.offset {
            digest = prev
        } else {
            // New file, or truncated/rewritten below our offset: parse from scratch.
            digest = FileDigest(path: url.path, sessionId: sessionId, projectDir: projectDir)
        }
        digest.missing = false

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            digest.size = size
            digest.mtime = mtime
            return digest
        }
        defer { try? handle.close() }

        var state = ScanState(digest: digest, claims: claims)
        do {
            try handle.seek(toOffset: UInt64(digest.offset))
            var remainder = Data()
            var consumed = digest.offset
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                var work: Data
                if remainder.isEmpty {
                    work = chunk
                } else {
                    work = remainder
                    work.append(chunk)
                    remainder = Data()
                }
                var cursor = work.startIndex
                while let nl = work[cursor...].firstIndex(of: 0x0A) {
                    consumed += Int64(nl - cursor + 1)
                    processLine(work[cursor..<nl], state: &state)
                    cursor = work.index(after: nl)
                }
                if cursor < work.endIndex { remainder = Data(work[cursor...]) }
                // Commit per chunk so a read error mid-file never leaves parsed
                // buckets ahead of the offset (which would double count on retry).
                // A trailing partial line (no newline yet) is a write in progress —
                // `consumed` never advances past the last complete line.
                state.digest.offset = consumed
            }
        } catch {
            // Keep whatever was parsed; offset only advanced past complete lines.
        }

        digest = state.finalized()
        digest.size = size
        digest.mtime = mtime
        return digest
    }

    // MARK: - Per-line processing

    private struct ScanState {
        var digest: FileDigest
        var buckets: [HourModelKey: TokenTotals]
        var seen: Set<String>
        var seenOrder: [String]
        let claims: ClaimTable?
        let decoder = JSONDecoder()

        init(digest: FileDigest, claims: ClaimTable?) {
            self.digest = digest
            self.claims = claims
            var b: [HourModelKey: TokenTotals] = [:]
            for bucket in digest.buckets {
                b[HourModelKey(hour: bucket.hour, model: bucket.model)] = bucket.totals
            }
            self.buckets = b
            self.seen = Set(digest.recentKeys)
            self.seenOrder = digest.recentKeys
        }

        func finalized() -> FileDigest {
            var d = digest
            d.buckets = buckets
                .map { HourBucket(hour: $0.key.hour, model: $0.key.model, totals: $0.value) }
                .sorted { ($0.hour, $0.model) < ($1.hour, $1.model) }
            d.recentKeys = Array(seenOrder.suffix(JSONLParser.dedupePersisted))
            return d
        }
    }

    private static func processLine(_ slice: Data, state: inout ScanState) {
        var line = slice
        if line.last == 0x0D { line = line.dropLast() } // CRLF safety
        guard !line.isEmpty else { return }

        let hasUsage = line.range(of: usageNeedle) != nil
        let hasTitle = line.range(of: titleNeedle) != nil
        let wantsUserLine = state.digest.fallbackTitle == nil && line.range(of: userNeedle) != nil
        guard hasUsage || hasTitle || wantsUserLine else { return }

        guard let raw = try? state.decoder.decode(RawLine.self, from: Data(line)) else { return }

        if let cwd = raw.cwd, !cwd.isEmpty { state.digest.cwd = cwd }
        if let branch = raw.gitBranch, !branch.isEmpty { state.digest.gitBranch = branch }

        if let title = raw.aiTitle, !title.isEmpty {
            state.digest.aiTitle = title
        }

        if wantsUserLine, raw.type == "user", raw.isMeta != true, raw.isSidechain != true,
           let text = raw.message?.content?.text {
            let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !firstLine.isEmpty, !firstLine.hasPrefix("<") {
                state.digest.fallbackTitle = String(firstLine.prefix(120))
            }
        }

        guard hasUsage, let message = raw.message, let usage = message.usage,
              let model = message.model, !model.isEmpty, !model.lowercased().contains("synthetic")
        else { return }

        var t = TokenTotals()
        t.input = usage.inputTokens ?? 0
        t.output = usage.outputTokens ?? 0
        t.cacheRead = usage.cacheReadInputTokens ?? 0
        if let nested = usage.cacheCreation, (nested.ephemeral5m ?? 0) + (nested.ephemeral1h ?? 0) > 0 {
            t.cacheWrite5m = nested.ephemeral5m ?? 0
            t.cacheWrite1h = nested.ephemeral1h ?? 0
        } else {
            // Older format: no 5m/1h split — 5m is the historical default TTL.
            t.cacheWrite5m = usage.cacheCreationInputTokens ?? 0
        }
        t.webSearches = usage.serverToolUse?.webSearchRequests ?? 0
        guard t.total > 0 || t.webSearches > 0 else { return }
        t.messages = 1

        if let id = message.id {
            let key = "\(id):\(raw.requestId ?? "")"
            if state.seen.contains(key) { return } // same turn, multiple content-block lines
            if let claims = state.claims, !claims.claim(key, owner: state.digest.path) {
                return // history copied from another session file (resume/fork)
            }
            state.seen.insert(key)
            state.seenOrder.append(key)
            if state.seenOrder.count > dedupeWindow {
                state.seen.remove(state.seenOrder.removeFirst())
            }
        }

        let ts = raw.timestamp.flatMap(epoch(fromISO8601:)) ?? state.digest.lastTs ?? Date().timeIntervalSince1970
        let hour = Int64(ts / 3600) * 3600
        state.buckets[HourModelKey(hour: hour, model: model), default: TokenTotals()].add(t)

        state.digest.firstTs = min(state.digest.firstTs ?? ts, ts)
        state.digest.lastTs = max(state.digest.lastTs ?? ts, ts)
        state.digest.lastModel = model
        state.digest.lastContextTokens = t.input.saturatingAdding(t.cacheRead)
            .saturatingAdding(t.cacheWrite5m).saturatingAdding(t.cacheWrite1h)
    }

    // MARK: - Timestamps

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fast path for the fixed "yyyy-MM-ddTHH:mm:ss(.SSS)Z" layout Claude Code writes;
    /// anything else falls back to ISO8601DateFormatter.
    static func epoch(fromISO8601 ts: String) -> Double? {
        let b = Array(ts.utf8)
        guard b.count >= 20, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A,
              b.last == 0x5A // 'Z'
        else { return slowEpoch(ts) }

        func digits(_ range: Range<Int>) -> Int? {
            var v = 0
            for i in range {
                let d = Int(b[i]) - 0x30
                guard (0...9).contains(d) else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              let hh = digits(11..<13), let mm = digits(14..<16), let ss = digits(17..<19)
        else { return slowEpoch(ts) }

        var frac = 0.0
        if b.count > 20, b[19] == 0x2E {
            var scale = 0.1
            var i = 20
            while i < b.count - 1 {
                let d = Int(b[i]) - 0x30
                guard (0...9).contains(d) else { return slowEpoch(ts) }
                frac += Double(d) * scale
                scale /= 10
                i += 1
            }
        } else if b.count != 20 {
            return slowEpoch(ts)
        }

        // Days-from-civil (Howard Hinnant) — integer math, no Calendar allocation per line.
        var y = year
        if month <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Double(days) * 86_400 + Double(hh * 3600 + mm * 60 + ss) + frac
    }

    private static func slowEpoch(_ ts: String) -> Double? {
        (isoFractional.date(from: ts) ?? isoPlain.date(from: ts))?.timeIntervalSince1970
    }
}

// MARK: - Raw line shapes (lenient: everything optional)

private struct RawLine: Decodable {
    let type: String?
    let timestamp: String?
    let cwd: String?
    let gitBranch: String?
    let requestId: String?
    let isSidechain: Bool?
    let isMeta: Bool?
    let aiTitle: String?
    let message: RawMessage?
}

private struct RawMessage: Decodable {
    let id: String?
    let model: String?
    let usage: RawUsage?
    let content: RawContent?
}

/// `content` is a string on plain user prompts, an array of blocks elsewhere.
private enum RawContent: Decodable {
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

private struct RawUsage: Decodable {
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheCreationInputTokens: Int64?
    let cacheReadInputTokens: Int64?
    let cacheCreation: RawCacheCreation?
    let serverToolUse: RawServerToolUse?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
        case serverToolUse = "server_tool_use"
    }
}

private struct RawCacheCreation: Decodable {
    let ephemeral5m: Int64?
    let ephemeral1h: Int64?

    enum CodingKeys: String, CodingKey {
        case ephemeral5m = "ephemeral_5m_input_tokens"
        case ephemeral1h = "ephemeral_1h_input_tokens"
    }
}

private struct RawServerToolUse: Decodable {
    let webSearchRequests: Int?

    enum CodingKeys: String, CodingKey {
        case webSearchRequests = "web_search_requests"
    }
}
