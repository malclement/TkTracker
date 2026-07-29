import Foundation

enum Format {
    /// Costs are USD regardless of where you are — they come from vendor list
    /// prices — so the `$` is fixed rather than localized. The *number* is not:
    /// `String(format:)` takes no locale and always emits a `.` separator, which
    /// read wrong in every locale that groups or separates differently. These
    /// helpers format through `NumberFormatter` so a French user sees `4,83` and
    /// a German user `4,83`, while the currency stays honest about its unit.
    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()
    private static let formatterLock = NSLock()

    /// Locale-aware fixed-fraction rendering. `grouping` is off for compact
    /// forms, where width matters more than readability.
    private static func number(
        _ value: Double,
        min: Int,
        max: Int,
        grouping: Bool = true
    ) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        decimal.minimumFractionDigits = min
        decimal.maximumFractionDigits = max
        decimal.usesGroupingSeparator = grouping
        return decimal.string(from: NSNumber(value: value)) ?? String(format: "%.\(max)f", value)
    }
    /// 845 -> "845", 12_400 -> "12.4K", 3_200_000 -> "3.2M", 1_400_000_000 -> "1.4B"
    static func tokens(_ n: Int64) -> String {
        let v = Double(n)
        switch abs(v) {
        case ..<1_000: return String(n)
        case ..<10_000: return trim(v / 1_000, 2) + "K"
        case ..<1_000_000: return trim(v / 1_000, 1) + "K"
        case ..<10_000_000: return trim(v / 1_000_000, 2) + "M"
        case ..<1_000_000_000: return trim(v / 1_000_000, 1) + "M"
        default: return trim(v / 1_000_000_000, 2) + "B"
        }
    }

    /// Adaptive precision: $0.0042, $0.42, $4.83, $48.30, $483, $4.8K
    static func money(_ usd: Double) -> String {
        let a = abs(usd)
        switch a {
        case 0: return "$0"
        case ..<0.01: return "$" + trim(usd, 4)
        case ..<1: return "$" + number(usd, min: 3, max: 3)
        case ..<100: return "$" + number(usd, min: 2, max: 2)
        case ..<1_000: return "$" + number(usd, min: 0, max: 0)
        case ..<100_000: return "$" + trim(usd / 1_000, 2) + "K"
        default: return "$" + trim(usd / 1_000_000, 2) + "M"
        }
    }

    /// Menu-bar variant: stable width matters more than precision, so grouping
    /// separators are suppressed.
    static func moneyCompact(_ usd: Double) -> String {
        let a = abs(usd)
        switch a {
        case ..<10: return "$" + number(usd, min: 2, max: 2, grouping: false)
        case ..<1_000: return "$" + number(usd, min: 0, max: 0, grouping: false)
        default: return "$" + trim(usd / 1_000, 1) + "K"
        }
    }

    static func percent(_ fraction: Double) -> String {
        let p = fraction * 100
        if p > 0, p < 1 { return "<1%" }
        return number(p, min: 0, max: 0) + "%"
    }

    /// "×9.2" — how many times over a subscription paid for itself.
    static func multiple(_ value: Double) -> String {
        value >= 10 ? "×" + number(value, min: 0, max: 0) : "×" + number(value, min: 1, max: 1)
    }

    static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m ago"
        case ..<86_400: return "\(Int(s / 3600))h ago"
        case ..<(86_400 * 7): return "\(Int(s / 86_400))d ago"
        default:
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f.string(from: date)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m)m"
    }

    /// Menu-bar-width variant: "2h05", "31m".
    static func durationCompact(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h\(String(format: "%02d", m))" }
        return "\(m)m"
    }

    /// "+38%" / "-12%".
    static func signedPercent(_ fraction: Double) -> String {
        let value = fraction * 100
        return (value >= 0 ? "+" : "") + number(value, min: 0, max: 0) + "%"
    }

    /// Trailing-zero-trimmed, locale-aware. Trimming happens against the locale's
    /// own decimal separator, so "4,50" trims to "4,5" in fr just as "4.50"
    /// trims to "4.5" in en.
    private static func trim(_ v: Double, _ digits: Int) -> String {
        var s = number(v, min: digits, max: digits, grouping: false)
        let separator = Locale.current.decimalSeparator ?? "."
        guard s.contains(separator) else { return s }
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(separator) { s.removeLast() }
        return s
    }
}
