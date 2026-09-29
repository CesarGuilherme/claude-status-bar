// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeStatusBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeStatusBar"),
        .testTarget(
            name: "ClaudeStatusBarTests",
            dependencies: ["ClaudeStatusBar"],
            resources: [.process("fixtures")]
        ),
    ]
)
