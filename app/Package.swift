// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeInbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeInbox",
            path: "Sources/ClaudeInbox",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
