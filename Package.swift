// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentWorkspace",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentWorkspace", targets: ["AgentWorkspace"])],
    targets: [.executableTarget(name: "AgentWorkspace", path: "Sources/AgentWorkspace")]
)
