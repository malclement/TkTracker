import Foundation

/// Claude Code prunes session transcripts after ~30 days (`cleanupPeriodDays`),
/// but its own aggregate stats file (`~/.claude/stats-cache.json`) survives with
/// per-day input+output tokens per model and lifetime per-model usage splits.
///
/// This importer reconstructs the pruned period as a single synthetic digest:
/// each day's in+out tokens are expanded to full usage using that model's
/// lifetime cache read/write per-io ratios, so pre-cleanup history stays visible
/// in every view. Days covered by real transcripts are excluded — exact data
/// always wins. Clearly labeled as estimated.
enum StatsCacheImport {
    static let syntheticPath = "claude-code://stats-cache-history"
    static let historyProjectDir = "claude-code-stats-history"

    static func defaultURL() -> URL {
        ScanCore.configRoot().appendingPathComponent("stats-cache.json")
    }

    static func historyDigest(
        statsURL: URL = defaultURL(),
        transcriptDigests: [FileDigest],
        calendar: Calendar = .current
    ) -> FileDigest? {
        guard let data = try? Data(contentsOf: statsURL),
              let raw = try? JSONDecoder().decode(RawStatsCache.self, from: data),
              let daily = raw.dailyModelTokens, !daily.isEmpty
        else { return nil }

        // Import only days strictly before the first transcript activity.
        let cutoffDay: String? = transcriptDigests
            .flatMap(\.buckets)
            .map(\.hour)
            .min()
            .map { dayString(epoch: Double($0), calendar: calendar) }

        let splits = makeSplits(raw.modelUsage ?? [:])
        var messagesByDay: [String: Int] = [:]
        for activity in raw.dailyActivity ?? [] {
            if let date = activity.date { messagesByDay[date] = activity.messageCount ?? 0 }
        }

        let dayFormatter = makeDayFormatter(calendar: calendar)
        var buckets: [HourBucket] = []
        var firstTs: Double?
        var lastTs: Double?
        var ioByModel: [String: Int64] = [:]

        for day in daily {
            guard let date = day.date, let byModel = day.tokensByModel, !byModel.isEmpty else { continue }
            if let cutoffDay, date >= cutoffDay { continue }
            guard let parsed = dayFormatter.date(from: date) else { continue }
            // Anchor at local noon so local-day chart grouping lands on the right day.
            let noon = calendar.startOfDay(for: parsed).addingTimeInterval(12 * 3600)
            let hour = Int64(noon.timeIntervalSince1970 / 3600) * 3600

            let dayIO = byModel.values.reduce(Int64(0)) { $0.saturatingAdding($1) }
            let dayMessages = messagesByDay[date] ?? 0
            for (model, io) in byModel where io > 0 {
                let split = splits[model] ?? splits[Self.aggregateKey] ?? .neutral
                var t = TokenTotals()
                t.input = .saturating((Double(io) * split.fIn).rounded())
                t.output = io.saturatingAdding(-t.input) // keep in+out equal to the recorded value
                t.cacheRead = .saturating((Double(io) * split.readPerIO).rounded())
                // TTL split is not recorded; 5m (1.25x) is the conservative assumption.
                t.cacheWrite5m = .saturating((Double(io) * split.writePerIO).rounded())
                t.messages = dayIO > 0
                    ? Int(Int64.saturating((Double(dayMessages) * Double(io) / Double(dayIO)).rounded()))
                    : 0
                buckets.append(HourBucket(hour: hour, model: model, totals: t))
                ioByModel[model, default: 0] = ioByModel[model, default: 0].saturatingAdding(io)
                firstTs = min(firstTs ?? Double(hour), Double(hour))
                lastTs = max(lastTs ?? Double(hour), Double(hour))
            }
        }
        guard !buckets.isEmpty else { return nil }
        buckets.sort { ($0.hour, $0.model) < ($1.hour, $1.model) }

        var digest = FileDigest(
            path: syntheticPath,
            sessionId: "claude-code-history",
            projectDir: historyProjectDir
        )
        digest.aiTitle = "Earlier history (estimated)"
        digest.buckets = buckets
        digest.firstTs = firstTs
        digest.lastTs = lastTs
        digest.lastModel = ioByModel.max { $0.value < $1.value }?.key
        return digest
    }

    // MARK: - Lifetime usage splits

    private static let aggregateKey = ""

    private struct Split {
        let fIn: Double        // input share of in+out
        let readPerIO: Double  // cache-read tokens per in+out token
        let writePerIO: Double // cache-write tokens per in+out token
        static let neutral = Split(fIn: 0.5, readPerIO: 0, writePerIO: 0)
    }

    private static func makeSplits(_ usage: [String: RawModelUsage]) -> [String: Split] {
        var out: [String: Split] = [:]
        var aggIn = 0.0, aggOut = 0.0, aggRead = 0.0, aggWrite = 0.0
        for (model, u) in usage {
            let i = Double(u.inputTokens ?? 0)
            let o = Double(u.outputTokens ?? 0)
            let r = Double(u.cacheReadInputTokens ?? 0)
            let w = Double(u.cacheCreationInputTokens ?? 0)
            aggIn += i; aggOut += o; aggRead += r; aggWrite += w
            let io = i + o
            guard io > 0 else { continue }
            out[model] = Split(fIn: i / io, readPerIO: r / io, writePerIO: w / io)
        }
        let aggIO = aggIn + aggOut
        if aggIO > 0 {
            out[aggregateKey] = Split(fIn: aggIn / aggIO, readPerIO: aggRead / aggIO, writePerIO: aggWrite / aggIO)
        }
        return out
    }

    // MARK: - Dates

    /// Stats-cache day strings are Gregorian regardless of the system calendar —
    /// only the time zone follows the caller (a Buddhist-calendar formatter would
    /// read "2026-06-15" as 1483 CE and anchor history five centuries back).
    private static func makeDayFormatter(calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        f.calendar = gregorian
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private static func dayString(epoch: Double, calendar: Calendar) -> String {
        makeDayFormatter(calendar: calendar).string(from: Date(timeIntervalSince1970: epoch))
    }
}

// MARK: - Raw shapes (all optional; the file's schema is Claude Code's, not ours)

private struct RawStatsCache: Decodable {
    let dailyActivity: [RawDailyActivity]?
    let dailyModelTokens: [RawDailyModelTokens]?
    let modelUsage: [String: RawModelUsage]?
}

private struct RawDailyActivity: Decodable {
    let date: String?
    let messageCount: Int?
}

private struct RawDailyModelTokens: Decodable {
    let date: String?
    let tokensByModel: [String: Int64]?
}

private struct RawModelUsage: Decodable {
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheReadInputTokens: Int64?
    let cacheCreationInputTokens: Int64?
}
