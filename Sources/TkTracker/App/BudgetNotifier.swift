import Foundation
import UserNotifications

/// Local notifications for spend and plan thresholds.
///
/// Each alert fires at most once per its own window (per day for the budget, per
/// block for the block gauge, per week for the plan allowance). Authorization is
/// requested lazily, on the first alert TkTracker actually wants to post.
enum BudgetNotifier {
    /// In-flight windows, so a second attempt cannot start before the first has
    /// resolved. `rebuild()` runs on every filesystem event — several times a
    /// second while a session streams — and the persisted mark is only written
    /// once `center.add` succeeds, which is asynchronous. Without this the guard
    /// would let a burst of rebuilds queue several identical notifications.
    @MainActor private static var pending: Set<String> = []

    /// Marks the window spent only once the notification is genuinely handed to
    /// the system, while still enforcing at-most-once *synchronously*.
    ///
    /// The mark used to be written before the authorization callback resolved, so
    /// declining the very first permission prompt silently consumed that day's
    /// alert. Moving it to the completion fixed that but dropped the mutual
    /// exclusion, hence `pending`.
    @MainActor
    private static func post(
        key: String,
        window: String,
        identifier: String,
        title: String,
        body: String
    ) {
        // UNUserNotificationCenter requires a real bundle; skip under `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard UserDefaults.standard.string(forKey: key) != window else { return }
        let token = "\(key)|\(window)"
        guard !pending.contains(token) else { return }
        pending.insert(token)

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Diagnostics.app.error("notification auth failed: \(error.localizedDescription, privacy: .public)")
            }
            guard granted else {
                Diagnostics.app.notice("notification permission denied; alert not posted")
                Task { @MainActor in pending.remove(token) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { addError in
                if let addError {
                    Diagnostics.app.error("notification post failed: \(addError.localizedDescription, privacy: .public)")
                    Task { @MainActor in pending.remove(token) }
                    return
                }
                // Only now is the window genuinely spent.
                Task { @MainActor in
                    UserDefaults.standard.set(window, forKey: key)
                    pending.remove(token)
                }
            }
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Today's spend crossed the configured daily budget.
    @MainActor
    static func notifyIfCrossed(todayCost: Double, budget: Double, now: Date = Date()) {
        guard budget > 0, todayCost > budget else { return }
        let day = dayKey(now)
        post(
            key: "budgetNotifiedDay",
            window: day,
            identifier: "tktracker-budget-\(day)",
            title: String(localized: "notify.budget.title", defaultValue: "Daily budget exceeded"),
            body: "Today's usage is at \(Format.money(todayCost)) (budget \(Format.money(budget)))."
        )
    }

    /// The current 5-hour block is nearly used up. Keyed by the block's start so
    /// each block can warn once.
    @MainActor
    static func notifyBlockNearLimit(gauge: PlanGauge, blockStart: Date, now: Date = Date()) {
        guard gauge.limit > 0, gauge.isNearLimit, !gauge.isOverLimit else { return }
        let window = ISO8601DateFormatter().string(from: blockStart)
        post(
            key: "blockNotifiedStart",
            window: window,
            identifier: "tktracker-block-\(window)",
            title: String(localized: "notify.block.title", defaultValue: "5-hour block nearly used up"),
            body: "\(Format.money(gauge.used)) of your \(Format.money(gauge.limit)) block allowance used, "
                + "\(Format.money(gauge.remaining)) left."
        )
    }

    /// The rolling weekly plan allowance is nearly used up, keyed by ISO week.
    @MainActor
    static func notifyWeeklyNearLimit(gauge: PlanGauge, now: Date = Date()) {
        guard gauge.limit > 0, gauge.isNearLimit, !gauge.isOverLimit else { return }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let window = "\(components.yearForWeekOfYear ?? 0)-W\(components.weekOfYear ?? 0)"
        post(
            key: "weeklyNotifiedWeek",
            window: window,
            identifier: "tktracker-weekly-\(window)",
            title: String(localized: "notify.weekly.title", defaultValue: "Weekly plan limit approaching"),
            body: "\(Format.percent(gauge.fraction)) of this week's allowance used — "
                + "\(Format.money(gauge.remaining)) left."
        )
    }
}
