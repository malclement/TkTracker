import SwiftUI
import AppKit

struct TkTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(UsageStore.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("TkTracker", id: "dashboard") {
            DashboardView()
                .environment(UsageStore.shared)
                .frame(minWidth: 940, minHeight: 580)
        }
        .defaultSize(width: 1080, height: 680)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--dashboard") || Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(UsageStore.shared)
        }
    }
}

/// Rendered in the status bar from launch — also the reliable place to boot the store.
private struct MenuBarLabel: View {
    @State private var store = UsageStore.shared
    /// The status item is always in the scene graph, so this is the one view
    /// guaranteed to be alive when a Shortcut asks for the dashboard.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: store.isOverBudget ? "exclamationmark.triangle.fill" : "chart.bar.xaxis")
            if let title = store.menuBarTitle {
                Text(title).monospacedDigit()
            }
        }
        // The status item is TkTracker's primary output surface; without this it
        // reads to VoiceOver as an unlabeled image plus a bare number.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TkTracker")
        .accessibilityValue(store.menuBarAccessibilityValue)
        .task { await store.startIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .tkTrackerOpenDashboard)) { _ in
            openWindow(id: "dashboard")
            WindowFocus.promote()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app by default; the dashboard flips this to .regular while open.
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await UsageStore.shared.startIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        UsageStore.shared.flushBlocking()
    }
}

enum WindowFocus {
    /// Show the dashboard as a normal app window (dock presence, cmd-tab) while open.
    @MainActor static func promote() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    @MainActor static func demoteIfNoWindows() {
        let hasVisible = NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
        if !hasVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
