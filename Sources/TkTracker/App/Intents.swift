import AppIntents
import Foundation

/// Shortcuts / Spotlight entry points.
///
/// These run in the app's own process and read through the same scan caches the
/// menu bar uses, so a shortcut and the popover can never disagree. Nothing here
/// touches the network, and no intent exposes session titles or project paths —
/// only aggregate figures.
struct TodaySpendIntent: AppIntent {
    static var title: LocalizedStringResource = "Get today's spend"
    static var description = IntentDescription(
        "Returns today's API-equivalent spend across the tools TkTracker tracks.",
        categoryName: "Usage"
    )
    /// No UI needed — this is a value lookup, so don't steal focus for it.
    static var openAppWhenRun = false

    @Parameter(title: "Source", default: .all)
    var scope: IntentSourceScope

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let stats = try IntentSupport.stats(range: .today, scope: scope)
        let amount = stats.todayCost
        return .result(
            value: amount,
            dialog: IntentDialog("You've used \(Format.money(amount)) today.")
        )
    }
}

struct RangeSpendIntent: AppIntent {
    static var title: LocalizedStringResource = "Get spend for a range"
    static var description = IntentDescription(
        "Returns API-equivalent spend over today, the last 7, 30 or 90 days, or all time.",
        categoryName: "Usage"
    )
    static var openAppWhenRun = false

    @Parameter(title: "Range", default: .week)
    var range: IntentRange

    @Parameter(title: "Source", default: .all)
    var scope: IntentSourceScope

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let stats = try IntentSupport.stats(range: range.statsRange, scope: scope)
        return .result(
            value: stats.cost,
            dialog: IntentDialog("\(range.label): \(Format.money(stats.cost)).")
        )
    }
}

struct BlockRemainingIntent: AppIntent {
    static var title: LocalizedStringResource = "Get current 5-hour block"
    static var description = IntentDescription(
        "Returns how much has been spent in the current 5-hour billing block and how long is left.",
        categoryName: "Usage"
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let stats = try IntentSupport.stats(range: .today, scope: .all)
        guard let block = stats.block, block.isActive else {
            return .result(value: 0, dialog: IntentDialog("No active block right now."))
        }
        let left = Format.duration(block.end.timeIntervalSince(Date()))
        return .result(
            value: block.cost,
            dialog: IntentDialog("\(Format.money(block.cost)) this block, \(left) left.")
        )
    }
}

struct OpenDashboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open TkTracker dashboard"
    static var description = IntentDescription("Brings up the full usage dashboard.", categoryName: "Usage")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WindowFocus.promote()
        NotificationCenter.default.post(name: .tkTrackerOpenDashboard, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let tkTrackerOpenDashboard = Notification.Name("tktracker.openDashboard")
}

// MARK: - Parameter enums

enum IntentRange: String, AppEnum {
    case today, week, month, quarter, all

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Range")
    static var caseDisplayRepresentations: [IntentRange: DisplayRepresentation] = [
        .today: "Today",
        .week: "Last 7 days",
        .month: "Last 30 days",
        .quarter: "Last 90 days",
        .all: "All time",
    ]

    var statsRange: StatsRange { StatsRange(rawValue: rawValue) ?? .today }
    var label: String { statsRange.label }
}

enum IntentSourceScope: String, AppEnum {
    case all, claude, codex

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Source")
    static var caseDisplayRepresentations: [IntentSourceScope: DisplayRepresentation] = [
        .all: "All sources",
        .claude: "Claude Code",
        .codex: "Codex",
    ]

    var sources: Set<UsageSource> {
        switch self {
        case .all: return Set(UsageSource.allCases)
        case .claude: return [.claude]
        case .codex: return [.codex]
        }
    }
}

// MARK: - Shared lookup

enum IntentSupport {
    enum IntentError: LocalizedError {
        case noData(String)
        var errorDescription: String? {
            switch self {
            case .noData(let message): return message
            }
        }
    }

    /// Prefer the running store's already-scanned state; fall back to a fresh
    /// scan when the app was cold-launched just to answer this.
    @MainActor
    static func stats(range: StatsRange, scope: IntentSourceScope) throws -> DashboardStats {
        let store = UsageStore.shared
        if store.hasScanned, scope == .all {
            return StatsBuilder.build(
                digests: store.digestsForIntents,
                range: range,
                plan: store.plan
            )
        }
        switch CLIReport.scan(sources: scope.sources) {
        case .failure(let message, _):
            throw IntentError.noData(message.trimmingCharacters(in: .whitespacesAndNewlines))
        case .success(let digests, _):
            return StatsBuilder.build(digests: digests, range: range, plan: store.plan)
        }
    }
}

/// Surfaces the shortcuts without the user having to search for them.
struct TkTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodaySpendIntent(),
            phrases: [
                "How much have I spent in \(.applicationName) today",
                "\(.applicationName) today",
            ],
            shortTitle: "Today's spend",
            systemImageName: "dollarsign.circle"
        )
        AppShortcut(
            intent: BlockRemainingIntent(),
            phrases: ["\(.applicationName) block", "Check my \(.applicationName) block"],
            shortTitle: "Current block",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: OpenDashboardIntent(),
            phrases: ["Open \(.applicationName) dashboard"],
            shortTitle: "Open dashboard",
            systemImageName: "rectangle.on.rectangle"
        )
    }
}
