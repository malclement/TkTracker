import Foundation
import Testing

@testable import TkTracker

@Suite("Version")
struct VersionTests {
    /// AppVersion.current (printed by `TkTracker --version`) must match the
    /// bundle version in Support/Info.plist (shown in Settings → About).
    @Test func cliVersionMatchesInfoPlist() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Support/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == AppVersion.current)
    }
}
