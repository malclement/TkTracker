#if DEBUG
import SwiftUI
import AppKit

/// Renders the Overview page offscreen from a real scan, for checking layout
/// without a window grant:
///   swift run TkTracker --overview-snapshot out.png [--light] [--width W] [--height H] [--range today|week|month|quarter|all]
/// Run it with CFFIXED_USER_HOME pointing at a scratch home so the scan cache
/// and history archive don't touch the real app's Application Support.
enum OverviewSnapshot {
    static func run(arguments: [String]) -> Int32 {
        guard let path = arguments.first else {
            print("usage: --overview-snapshot out.png [--light] [--width W] [--height H] [--range R]")
            return 2
        }
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let size = CGSize(width: Double(value("--width") ?? "") ?? 900, height: Double(value("--height") ?? "") ?? 1500)
        return MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let store = UsageStore.shared
            if let raw = value("--range"), let range = StatsRange(rawValue: raw) { store.range = range }
            Task { await store.startIfNeeded() }
            let deadline = Date().addingTimeInterval(90)
            while !store.hasScanned, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: arguments.contains("--light") ? .aqua : .darkAqua)
            let host = NSHostingView(rootView: OverviewView().environment(store))
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return 1 }
            do { try data.write(to: URL(fileURLWithPath: path)) } catch { return 1 }
            return 0
        }
    }
}
#endif
