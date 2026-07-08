import Foundation
import UserNotifications

/// Posts at most one notification per local day when today's cost crosses the
/// configured budget. Authorization is requested lazily, on the first crossing.
enum BudgetNotifier {
    static func notifyIfCrossed(todayCost: Double, budget: Double, now: Date = Date()) {
        guard budget > 0, todayCost > budget else { return }
        // UNUserNotificationCenter requires a real bundle; skip under `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)

        let key = "budgetNotifiedDay"
        guard UserDefaults.standard.string(forKey: key) != day else { return }
        UserDefaults.standard.set(day, forKey: key)

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Daily budget exceeded"
            content.body = "Today's usage is at \(Format.money(todayCost))"
                + " (budget \(Format.money(budget)))."
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "tktracker-budget-\(day)",
                content: content,
                trigger: nil
            ))
        }
    }
}
