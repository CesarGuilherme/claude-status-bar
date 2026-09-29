// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeStatusBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeStatusBar",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ClaudeStatusBarTests",
            dependencies: ["ClaudeStatusBar"],
            resources: [.process("fixtures")]
        ),
    ]
)
