// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TkTracker",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TkTracker",
            path: "Sources/TkTracker",
            exclude: ["Resources/README.md"],
            resources: [
                // Vendor rates, so a price change is a data edit rather than a
                // release. PricingCatalog falls back to a compiled-in copy when
                // the bundle is unreachable.
                .process("Resources/pricing.json"),
                .process("Resources/en.lproj"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TkTrackerTests",
            dependencies: ["TkTracker"],
            path: "Tests/TkTrackerTests",
            // .copy, not .process: the scanners walk a real directory tree, so
            // the fixture layout (project dirs, Codex's YYYY/MM/DD nesting) has
            // to survive into the bundle intact.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
