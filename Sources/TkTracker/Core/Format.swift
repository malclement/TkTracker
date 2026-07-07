import Foundation

enum Format {
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
        case ..<1: return "$" + String(format: "%.3f", usd)
        case ..<100: return "$" + String(format: "%.2f", usd)
        case ..<1_000: return "$" + String(format: "%.0f", usd)
        case ..<100_000: return "$" + trim(usd / 1_000, 2) + "K"
        default: return "$" + trim(usd / 1_000_000, 2) + "M"
        }
    }

    /// Menu-bar variant: stable width matters more than precision.
    static func moneyCompact(_ usd: Double) -> String {
        let a = abs(usd)
        switch a {
        case ..<10: return "$" + String(format: "%.2f", usd)
        case ..<1_000: return "$" + String(format: "%.0f", usd)
        default: return "$" + trim(usd / 1_000, 1) + "K"
        }
    }

    static func percent(_ fraction: Double) -> String {
        let p = fraction * 100
        if p > 0, p < 1 { return "<1%" }
        return String(format: "%.0f%%", p)
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
        String(format: "%+.0f%%", fraction * 100)
    }

    private static func trim(_ v: Double, _ digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
