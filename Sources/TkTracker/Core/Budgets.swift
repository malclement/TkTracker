import Foundation

struct BudgetRule: Codable, Sendable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String = "Monthly budget"
    /// Empty means every tracked project.
    var project: String = ""
    var monthlyLimit: Double = 0
    var warningFraction: Double = 0.8
}

struct BudgetProgress: Identifiable, Sendable {
    var rule: BudgetRule
    var used: Double
    var projected: Double?
    var cycle: String
    var id: String { rule.id }
    var fraction: Double { rule.monthlyLimit > 0 ? used / rule.monthlyLimit : 0 }
}

enum BudgetAnalysis {
    static func progress(rules: [BudgetRule], digests: [FileDigest], now: Date = Date(), calendar: Calendar = .current) -> [BudgetProgress] {
        guard let month = calendar.dateInterval(of: .month, for: now) else { return [] }
        let day = calendar.component(.day, from: now)
        let days = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let cycle = String(Int(month.start.timeIntervalSince1970))
        return rules.filter { $0.monthlyLimit.isFinite && $0.monthlyLimit > 0 }.map { rule in
            var used = 0.0
            for digest in digests where rule.project.isEmpty || rule.project == digest.projectKey {
                for b in digest.accountingBuckets where b.epoch >= month.start.timeIntervalSince1970 && b.epoch <= now.timeIntervalSince1970 { used += b.cost }
            }
            let elapsed = Double(day - 1) + now.timeIntervalSince(calendar.startOfDay(for: now)) / max(1, calendar.dateInterval(of: .day, for: now)?.duration ?? 86400)
            return BudgetProgress(rule: rule, used: used, projected: elapsed >= 3 ? used / elapsed * Double(days) : nil, cycle: cycle)
        }
    }

    static func unusualSpend(digests: [FileDigest], multiplier: Double, now: Date = Date(), calendar: Calendar = .current) -> Double? {
        guard multiplier.isFinite, multiplier >= 1.5 else { return nil }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -14, to: today) ?? today
        var byDay: [Date: Double] = [:]
        for digest in digests {
            for b in digest.accountingBuckets where b.epoch >= start.timeIntervalSince1970 && b.epoch <= now.timeIntervalSince1970 {
                byDay[calendar.startOfDay(for: Date(timeIntervalSince1970: b.epoch)), default: 0] += b.cost
            }
        }
        let history = byDay.filter { $0.key < today && $0.value > 0 }.map(\.value).sorted()
        guard history.count >= 5 else { return nil }
        let median = history[history.count / 2]
        let spend = byDay[today] ?? 0
        return spend > max(1, median * multiplier) ? spend / median : nil
    }
}
