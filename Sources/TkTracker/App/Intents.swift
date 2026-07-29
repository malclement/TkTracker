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
    var scope: SourceScope

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let stats = try await IntentSupport.stats(range: .today, scope: scope)
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
    var range: StatsRange

    @Parameter(title: "Source", default: .all)
    var scope: SourceScope

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let stats = try await IntentSupport.stats(range: range, scope: scope)
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
        let stats = try await IntentSupport.stats(range: .today, scope: .all)
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

// MARK: - Parameter types

// The Shortcuts parameter types are the app's own `StatsRange` and `SourceScope`,
// conformed to `AppEnum` here rather than duplicated.
//
// A parallel pair of enums existed first, round-tripping through `rawValue` into
// the real types — which meant renaming a case in Core would silently retarget
// every saved shortcut instead of failing to build. The conformances live in the
// App layer so Core keeps no dependency on AppIntents.

extension StatsRange: AppEnum {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Range")
    }

    public static var caseDisplayRepresentations: [StatsRange: DisplayRepresentation] {
        [
            .today: "Today",
            .week: "Last 7 days",
            .month: "Last 30 days",
            .quarter: "Last 90 days",
            .all: "All time",
        ]
    }
}

extension SourceScope: AppEnum {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Source")
    }

    public static var caseDisplayRepresentations: [SourceScope: DisplayRepresentation] {
        [
            .all: "All sources",
            .claude: "Claude Code",
            .codex: "Codex",
        ]
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

    /// Resolves stats for an intent.
    ///
    /// Two things this deliberately does *not* do, both of which it used to:
    ///
    /// - Take the requested scope only sometimes. It previously used the running
    ///   store when `scope == .all`, which silently applied whatever source lens
    ///   the dashboard happened to be set to — so "today's spend, all sources"
    ///   answered with Claude-only figures if the window was filtered. The
    ///   requested scope is now always honoured, whichever path runs.
    /// - Scan on the main actor. `CLIReport.scan` walks the filesystem and, by
    ///   default, writes caches; doing that inline froze the UI for the duration
    ///   of a cold scan. It now runs detached and read-only.
    @MainActor
    static func stats(range: StatsRange, scope: SourceScope) async throws -> DashboardStats {
        let store = UsageStore.shared
        if store.hasScanned {
            return store.stats(range: range, scope: scope)
        }
        // Cold launch: scan off the main actor, and do not persist — an intent is
        // a read, and the app proper owns cache writes.
        let sources = scope.sources
        let outcome = await Task.detached(priority: .userInitiated) {
            CLIReport.scan(sources: sources, persist: false)
        }.value
        switch outcome {
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
