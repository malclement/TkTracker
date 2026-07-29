import Foundation
import os

/// Logging and self-report plumbing.
///
/// Everything in TkTracker's IO path used to be `try?`, so a permissions problem,
/// a corrupt cache or a failed save was indistinguishable from "you just spent
/// less money". These loggers make the failure visible in Console.app, and
/// `Diagnostics.report` turns the app's current state into something a user can
/// paste into a bug report without leaking what they work on.
enum Diagnostics {
    static let subsystem = "com.clementmalige.tktracker"

    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let pricing = Logger(subsystem: subsystem, category: "pricing")
    static let update = Logger(subsystem: subsystem, category: "update")

    /// Absolute paths name projects, clients and people. Reports quote only the
    /// last component, and only its shape.
    static func redact(path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        return "<\(name.count) chars>\(ext.isEmpty ? "" : ".\(ext)")"
    }

    static func humanBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value < 10 && unit > 0 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }
}

/// Health of the last scan, for the UI and the diagnostics report. Written by
/// `UsageStore` after each refresh.
struct ScanHealth: Sendable, Equatable {
    var lastScan: Date?
    var lastScanDuration: TimeInterval = 0
    var digestCount = 0
    var claimCount = 0
    var unreadableFiles: [String] = []
    var cacheWriteFailed = false

    var hasProblem: Bool { !unreadableFiles.isEmpty || cacheWriteFailed }

    /// One line for the UI when something is wrong, nil when everything is fine.
    var problemSummary: String? {
        var parts: [String] = []
        if !unreadableFiles.isEmpty {
            let n = unreadableFiles.count
            parts.append("\(n) session file\(n == 1 ? "" : "s") could not be read")
        }
        if cacheWriteFailed { parts.append("cache could not be saved") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Diagnostics {
    /// A paste-ready state dump. Contains counts, sizes and timings — never a
    /// project path, session title or prompt.
    @MainActor
    static func report(store: UsageStore) -> String {
        let health = store.scanHealth
        let stats = store.stats
        var lines: [String] = []

        lines.append("TkTracker diagnostics")
        lines.append("version      \(AppVersion.current) (cache format v\(ScanCore.cacheVersion))")
        lines.append("macOS        \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("bundle       \(Bundle.main.bundleURL.pathExtension == "app" ? "app" : "cli/dev")")
        lines.append("")

        lines.append("sources")
        lines.append("  claude     tracked=\(store.trackClaude) dirExists=\(store.dataDirExists)")
        lines.append("  codex      tracked=\(store.trackCodex) dirExists=\(store.codexDataDirExists)")
        lines.append("  scope      \(store.sourceScope.rawValue)")
        lines.append("  customRoot claude=\(ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil)"
            + " codex=\(ProcessInfo.processInfo.environment["CODEX_HOME"] != nil)")
        lines.append("")

        lines.append("scan")
        lines.append("  lastScan   \(health.lastScan.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
        lines.append("  duration   \(String(format: "%.3fs", health.lastScanDuration))")
        lines.append("  digests    \(health.digestCount)")
        lines.append("  claims     \(health.claimCount)")
        lines.append("  unreadable \(health.unreadableFiles.count)")
        for path in health.unreadableFiles.prefix(10) {
            lines.append("             \(redact(path: path))")
        }
        lines.append("  saveFailed \(health.cacheWriteFailed)")
        lines.append("")

        lines.append("caches")
        for (label, url) in cacheFiles() {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            lines.append("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                + (size.map(humanBytes) ?? "absent"))
        }
        lines.append("")

        lines.append("data")
        lines.append("  range      \(stats.range.rawValue)")
        lines.append("  sessions   \(stats.sessions.count) (\(stats.activeSessions) live)")
        lines.append("  models     \(stats.models.map(\.shortName).sorted().joined(separator: ", "))")
        lines.append("  noPricing  \(stats.models.filter { !$0.hasPricing }.map(\.model).sorted().joined(separator: ", "))")
        lines.append("  since      \(stats.dataSince.map { ISO8601DateFormatter().string(from: $0) } ?? "n/a")")
        lines.append("  estimated  \(stats.hasEstimatedHistory)")
        lines.append("")

        lines.append("settings")
        lines.append("  budget     \(store.dailyBudget > 0 ? "set" : "off")")
        lines.append("  history    \(store.includeHistory)")
        lines.append("  plan       \(store.plan.id)")
        lines.append("  updates    \(store.checksForUpdates)")
        lines.append("  overrides  \(PricingCatalog.shared.overrideCount)")

        return lines.joined(separator: "\n")
    }

    private static func cacheFiles() -> [(String, URL)] {
        UsageSource.allCases.flatMap { source in
            [
                ("\(source.rawValue)", ScanCore.defaultCacheURL(for: source)),
                ("\(source.rawValue)-arc", HistoryArchive.defaultURL(for: source)),
            ]
        }
    }
}
