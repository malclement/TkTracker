import Foundation

/// A subscription plan's shape, used for the "how much of my allowance is left"
/// gauges and the value multiple.
///
/// **On the limit numbers.** Anthropic and OpenAI express plan limits in terms
/// of messages, prompts and rolling windows — not dollars — and those thresholds
/// move. TkTracker only knows API-equivalent value, so a limit here is an
/// *approximation of your own experience*, not a published figure. The presets
/// are starting points; every field is editable, and the whole feature is off
/// until you pick a plan. Nothing in the app fabricates a limit you didn't set.
struct UsagePlan: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    /// What the plan costs per month, for the value multiple. 0 = pay-as-you-go.
    var monthlyCost: Double
    /// API-equivalent USD per rolling 5-hour block before throttling. 0 = no gauge.
    var blockLimit: Double
    /// API-equivalent USD per rolling 7 days before throttling. 0 = no gauge.
    var weeklyLimit: Double

    var tracksBlock: Bool { blockLimit > 0 }
    var tracksWeekly: Bool { weeklyLimit > 0 }
    var tracksValue: Bool { monthlyCost > 0 }

    static let none = UsagePlan(
        id: "none", name: "Pay-as-you-go / API", monthlyCost: 0, blockLimit: 0, weeklyLimit: 0
    )

    /// Rough starting points, deliberately round — they exist to be adjusted.
    static let presets: [UsagePlan] = [
        .none,
        UsagePlan(id: "pro", name: "Claude Pro", monthlyCost: 20, blockLimit: 20, weeklyLimit: 180),
        UsagePlan(id: "max5", name: "Claude Max 5×", monthlyCost: 100, blockLimit: 100, weeklyLimit: 900),
        UsagePlan(id: "max20", name: "Claude Max 20×", monthlyCost: 200, blockLimit: 400, weeklyLimit: 3600),
        UsagePlan(id: "chatgpt_plus", name: "ChatGPT Plus", monthlyCost: 20, blockLimit: 20, weeklyLimit: 180),
        UsagePlan(id: "chatgpt_pro", name: "ChatGPT Pro", monthlyCost: 200, blockLimit: 400, weeklyLimit: 3600),
        UsagePlan(id: "custom", name: "Custom", monthlyCost: 0, blockLimit: 0, weeklyLimit: 0),
    ]

    static func preset(id: String) -> UsagePlan {
        presets.first { $0.id == id } ?? .none
    }

    // MARK: - Persistence

    /// Stored whole rather than field-by-field so an edited preset keeps its
    /// edits across launches.
    static func load(from defaults: UserDefaults = .standard) -> UsagePlan {
        guard let data = defaults.data(forKey: "usagePlan"),
              let plan = try? JSONDecoder().decode(UsagePlan.self, from: data)
        else { return .none }
        return plan
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "usagePlan")
    }
}

/// How much of a plan allowance a window has consumed.
struct PlanGauge: Codable, Sendable, Equatable {
    var used: Double
    var limit: Double
    var windowEnd: Date?

    var fraction: Double { limit > 0 ? min(1, used / limit) : 0 }
    var remaining: Double { max(0, limit - used) }
    var isNearLimit: Bool { fraction >= 0.8 }
    var isOverLimit: Bool { used >= limit }

    /// When the allowance runs out at the current rate, if it will before the
    /// window closes. nil when idle, already over, or comfortably inside.
    func exhaustion(ratePerHour: Double, now: Date) -> Date? {
        guard ratePerHour > 0.001, limit > 0, used < limit else { return nil }
        let hoursLeft = remaining / ratePerHour
        let projected = now.addingTimeInterval(hoursLeft * 3600)
        if let windowEnd, projected >= windowEnd { return nil }
        return projected
    }
}
