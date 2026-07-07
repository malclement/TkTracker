// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TkTracker",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TkTracker",
            path: "Sources/TkTracker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TkTrackerTests",
            dependencies: ["TkTracker"],
            path: "Tests/TkTrackerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
