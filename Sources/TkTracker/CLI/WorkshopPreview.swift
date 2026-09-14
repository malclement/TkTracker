#if DEBUG
import SwiftUI

/// A separate development window: no usage-engine bootstrap, archive writes,
/// notifications or account refreshes while inspecting sample scene states.
struct WorkshopPreviewApp: App {
    @State private var daylight = false
    var body: some Scene {
        Window("TkTracker · Workshops preview", id: "workshops-preview") {
            WorkshopView(demo: true)
                .environment(UsageStore.shared)
                .frame(minWidth: 780, minHeight: 520)
                .preferredColorScheme(daylight ? .light : .dark)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Toggle("Daylight", isOn: $daylight).toggleStyle(.checkbox).font(.caption)
                    }
                }
                .onAppear { WindowFocus.promote() }
        }.defaultSize(width: 1120, height: 760)
    }
}
#endif
