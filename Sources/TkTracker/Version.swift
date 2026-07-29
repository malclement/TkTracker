/// Single source of truth for the CLI's version report. Must match
/// `CFBundleShortVersionString` in Support/Info.plist — a unit test enforces it.
enum AppVersion {
    static let current = "1.5.0"

    /// Semantic-version comparison for the update check. Missing components read
    /// as 0 ("1.5" == "1.5.0"), and anything non-numeric compares as 0 rather
    /// than throwing — a malformed tag on the release must never crash the app.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        components(current).lexicographicallyPrecedes(components(candidate))
    }

    static func components(_ version: String) -> [Int] {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        var parts = core.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        return Array(parts.prefix(3))
    }
}
