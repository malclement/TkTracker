import Foundation

struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var usedPercent: Double
    var durationMinutes: Int
    var resetsAt: Date
    var id: String { name }
    var label: String {
        let duration = durationMinutes % 1440 == 0 ? "\(durationMinutes / 1440)-day" : (durationMinutes % 60 == 0 ? "\(durationMinutes / 60)-hour" : "\(durationMinutes)-minute")
        let group = name.components(separatedBy: " · ").first ?? ""
        return (group == "codex" ? "" : group + " · ") + duration + " window"
    }
    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

struct QuotaSnapshot: Codable, Sendable, Equatable {
    var observedAt: Date
    var origin: String
    var windows: [QuotaWindow]
    func isStale(at now: Date = Date()) -> Bool {
        observedAt.timeIntervalSince(now) > 60 || now.timeIntervalSince(observedAt) > 5 * 60 || windows.contains { $0.resetsAt <= now }
    }

    static func parse(_ object: [String: Any], at now: Date, origin: String) -> QuotaSnapshot {
        var windows: [QuotaWindow] = []
        let groups = object["rateLimitsByLimitId"] as? [String: [String: Any]]
            ?? ["codex": object["rateLimits"] as? [String: Any] ?? object]
        for (id, group) in groups.sorted(by: { $0.key < $1.key }) {
            for name in ["primary", "secondary"] {
                guard let raw = group[name] as? [String: Any],
                      let used = (raw["usedPercent"] ?? raw["used_percent"]) as? NSNumber,
                      let duration = (raw["windowDurationMins"] ?? raw["window_minutes"]) as? NSNumber,
                      let reset = (raw["resetsAt"] ?? raw["resets_at"]) as? NSNumber,
                      used.doubleValue.isFinite, used.doubleValue >= 0,
                      duration.doubleValue.isFinite, duration.doubleValue >= 1, duration.doubleValue <= 525600, reset.doubleValue.isFinite, reset.doubleValue > 0, reset.doubleValue <= 253402300799 else { continue }
                windows.append(QuotaWindow(name: "\(id) · \(name)", usedPercent: min(used.doubleValue, 100),
                    durationMinutes: duration.intValue, resetsAt: Date(timeIntervalSince1970: reset.doubleValue)))
            }
        }
        return QuotaSnapshot(observedAt: now, origin: origin, windows: windows)
    }
}

/// Lenient JSON wrapper for optional metadata. Unknown fields cannot break the
/// usage decoder; model traffic remains local even when quota reads are disabled.
struct RawQuota: Decodable {
    var windows: [QuotaWindow] = []
    init(from decoder: Decoder) throws {
        struct Window: Decodable { var used_percent: Double?; var window_minutes: Int?; var resets_at: Double? }
        struct Limits: Decodable { var primary: Window?; var secondary: Window?; var limit_id: String? }
        guard let raw = try? Limits(from: decoder) else { return }
        for (name, w) in [("primary", raw.primary), ("secondary", raw.secondary)] {
            guard let w, let used = w.used_percent, used.isFinite, used >= 0,
                  let minutes = w.window_minutes, minutes > 0, minutes <= 525600, let reset = w.resets_at, reset.isFinite, reset > 0, reset <= 253402300799 else { continue }
            windows.append(QuotaWindow(name: "\(raw.limit_id ?? "codex") · \(name)", usedPercent: min(100, used),
                durationMinutes: minutes, resetsAt: Date(timeIntervalSince1970: reset)))
        }
    }
}
