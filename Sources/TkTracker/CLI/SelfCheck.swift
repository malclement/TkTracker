import Foundation

/// Post-build assertion that the packaged app can actually reach what it needs.
///
/// This exists because a resource-loading defect shipped once already and was
/// invisible on the build machine: SwiftPM's `Bundle.module` accessor carries a
/// hardcoded absolute `.build` path, so an app bundle that lacked the resource
/// bundle entirely still worked locally and would have trapped on every other
/// Mac. `make app` runs this against the freshly built bundle and fails the
/// build if anything is unreachable, which turns that class of mistake from a
/// crash-on-a-stranger's-machine into a red build.
///
/// It deliberately reports the *resolved path* rather than a bare pass/fail, so
/// the Makefile can assert the resource came from inside the app bundle and not
/// from a developer-only fallback.
enum SelfCheck {
    static func run() -> Int32 {
        var failures: [String] = []

        print("bundle       \(Bundle.main.bundleURL.path)")
        print("executable   \(Bundle.main.executableURL?.path ?? "unknown")")

        // Pricing table: the app runs without it (compiled-in fallback), but a
        // packaged build missing it means the Makefile copy broke.
        if let url = PricingCatalog.resourceURL(named: "pricing", extension: "json") {
            print("pricing.json \(url.path)")
        } else {
            print("pricing.json UNRESOLVED")
            failures.append("pricing.json not reachable from this bundle")
        }

        // The catalog must be constructible without trapping, whatever happens.
        let catalog = PricingCatalog(overrides: [:])
        print("fromBundle   \(catalog.loadedFromBundle)")
        if catalog.pricing(for: "claude-opus-4-8") == nil {
            failures.append("pricing lookup returned nil for a known model")
        }

        // The shipped table and the compiled-in fallback must agree, or the app
        // and the CLI price differently depending on what they can reach.
        let fallback = PricingCatalog(
            document: PricingCatalog.builtIn,
            overrides: [:],
            overridesURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tktracker-selfcheck-\(UUID().uuidString).json")
        )
        let probes = [
            "claude-opus-4-8", "claude-sonnet-4-5", "claude-haiku-4-5", "claude-fable-5",
            "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "claude-sonnet-5", "claude-opus-5", "claude-fable-5-1", "gpt-5.5", "gpt-5.3-codex", "codex-mini-latest", "some-unknown-model",
        ]
        for id in probes where catalog.pricing(for: id) != fallback.pricing(for: id) {
            failures.append("pricing.json disagrees with the compiled-in table for \(id)")
        }

        if let localized = PricingCatalog.resourceURL(named: "Localizable", extension: "strings") {
            print("strings      \(localized.path)")
        } else {
            print("strings      UNRESOLVED (base localization missing)")
            failures.append("Localizable.strings not reachable from this bundle")
        }

        // App Intents are compiled in but only *discoverable* when the bundle
        // carries Metadata.appintents, which Xcode's appintentsmetadataprocessor
        // generates and SwiftPM does not. 1.5.0 shipped documenting Shortcuts
        // support that had never registered, so this is reported on every build.
        //
        // Deliberately not a failure: on a Command-Line-Tools toolchain the
        // condition can never be satisfied, and a build that cannot pass its own
        // gate teaches people to ignore the gate.
        let metadata = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Metadata.appintents")
        if FileManager.default.fileExists(atPath: metadata.path) {
            print("appintents   metadata present (runtime discovery requires macOS registration)")
        } else {
            print("appintents   INERT — no Metadata.appintents, Shortcuts will not register")
            print("             (expected on a SwiftPM build; do not document Shortcuts support)")
        }

        guard failures.isEmpty else {
            for failure in failures {
                FileHandle.standardError.write(Data("selfcheck: \(failure)\n".utf8))
            }
            return 1
        }
        print("selfcheck    OK")
        return 0
    }
}
