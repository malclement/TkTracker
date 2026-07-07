/// Single source of truth for the CLI's version report. Must match
/// `CFBundleShortVersionString` in Support/Info.plist — a unit test enforces it.
enum AppVersion {
    static let current = "1.2.0"
}
