// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentDeckCore"),
        .executableTarget(name: "agentdeck-hook", dependencies: ["AgentDeckCore"]),
        .executableTarget(name: "AgentDeck", dependencies: ["AgentDeckCore"]),
        .testTarget(name: "AgentDeckCoreTests", dependencies: ["AgentDeckCore"]),
    ]
)
