import Foundation

/// Per-day, per-model usage rows for spreadsheets — shared by the CLI (`report --csv`)
/// and the dashboard's export button.
enum CSVExport {
    static let header = "date,model,input_tokens,output_tokens,cache_read_tokens,"
        + "cache_write_5m_tokens,cache_write_1h_tokens,web_searches,messages,cost_usd"

    static func dailyByModel(
        digests: [FileDigest],
        range: StatsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let start = range.start(now: now, calendar: calendar)?.timeIntervalSince1970

        // Dates must stay Gregorian whatever the system calendar (a Buddhist-
        // calendar formatter would emit "2569-…"); only the time zone is local.
        let formatter = DateFormatter()
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        formatter.calendar = gregorian
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        struct Key: Hashable { let day: String; let model: String }
        var rows: [Key: TokenTotals] = [:]
        var dayCache: [Int64: String] = [:]

        for digest in digests {
            for bucket in digest.buckets {
                if let start, Double(bucket.hour) < start { continue }
                let day: String
                if let cached = dayCache[bucket.hour] {
                    day = cached
                } else {
                    day = formatter.string(from: Date(timeIntervalSince1970: Double(bucket.hour)))
                    dayCache[bucket.hour] = day
                }
                rows[Key(day: day, model: bucket.model), default: TokenTotals()].add(bucket.totals)
            }
        }

        var out = header + "\n"
        for (key, t) in rows.sorted(by: { ($0.key.day, $0.key.model) < ($1.key.day, $1.key.model) }) {
            let cost = Pricing.cost(model: key.model, totals: t)
            out += "\(key.day),\(key.model),\(t.input),\(t.output),\(t.cacheRead),"
                + "\(t.cacheWrite5m),\(t.cacheWrite1h),\(t.webSearches),\(t.messages),"
                + String(format: "%.4f", cost) + "\n"
        }
        return out
    }
}
