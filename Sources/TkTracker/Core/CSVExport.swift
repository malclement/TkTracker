import Foundation

/// Per-day, per-source, per-model usage rows for spreadsheets — shared by the
/// CLI (`report --csv`) and the dashboard's export button.
enum CSVExport {
    static func escape(_ text: String) -> String {
        let safe = ["=", "+", "-", "@"].contains(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))) || text.hasPrefix("\t") ? "'" + text : text
        if !safe.contains(","), !safe.contains("\""), !safe.contains("\n"), !safe.contains("\r") { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static let header = "date,source,model,input_tokens,output_tokens,cache_read_tokens,"
        + "cache_write_5m_tokens,cache_write_1h_tokens,web_searches,messages,cost_usd,pricing_status"

    static func dailyByModel(
        digests: [FileDigest],
        range: StatsRange,
        now: Date = Date(),
        calendar: Calendar = .current,
        filter: ReportFilter? = nil
    ) -> String {
        let interval = filter?.interval(now: now, calendar: calendar)
        let start = interval?.start.timeIntervalSince1970 ?? range.start(now: now, calendar: calendar)?.timeIntervalSince1970
        let end = min(interval?.end.timeIntervalSince1970 ?? now.timeIntervalSince1970 + 1, now.timeIntervalSince1970 + 1)

        // Dates must stay Gregorian whatever the system calendar (a Buddhist-
        // calendar formatter would emit "2569-…"); only the time zone is local.
        let formatter = DateFormatter()
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        formatter.calendar = gregorian
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        struct Key: Hashable { let day: String; let source: String; let model: String }
        var rows: [Key: TokenTotals] = [:]
        var costs: [Key: Double] = [:]
        var unpriced = Set<Key>()
        var dayCache: [Int64: String] = [:]

        for digest in filter?.apply(to: digests) ?? digests {
            let source = digest.source.rawValue
            for bucket in digest.accountingBuckets {
                if let start, bucket.epoch < start { continue }
                if bucket.epoch >= end { continue }
                let day: String
                if let cached = dayCache[Int64(bucket.epoch / 60)] {
                    day = cached
                } else {
                    day = formatter.string(from: Date(timeIntervalSince1970: bucket.epoch))
                    dayCache[Int64(bucket.epoch / 60)] = day
                }
                let key = Key(day: day, source: source, model: bucket.model)
                rows[key, default: TokenTotals()].add(bucket.totals)
                costs[key, default: 0] += bucket.cost
                if PricingCatalog.shared.pricing(for: bucket.model, context: bucket.context) == nil { unpriced.insert(key) }
            }
        }

        var out = header + "\n"
        for (key, t) in rows.sorted(by: { ($0.key.day, $0.key.source, $0.key.model) < ($1.key.day, $1.key.source, $1.key.model) }) {
            let cost = costs[key] ?? 0
            out += "\(key.day),\(key.source),\(escape(key.model)),\(t.input),\(t.output),\(t.cacheRead),"
                + "\(t.cacheWrite5m),\(t.cacheWrite1h),\(t.webSearches),\(t.messages),"
                + String(format: "%.4f", cost) + "," + (unpriced.contains(key) ? "partial" : "estimated") + "\n"
        }
        return out
    }
}
