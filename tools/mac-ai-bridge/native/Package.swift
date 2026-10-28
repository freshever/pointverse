// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MacAIBridge", platforms: [.macOS(.v14)], products: [
    .executable(name: "BridgeAgent", targets: ["BridgeAgent"]),
    .executable(name: "ScreenProbe", targets: ["ScreenProbe"]),
    .executable(name: "MockAI", targets: ["MockAI"])
], targets: [.executableTarget(name: "ScreenProbe"), .executableTarget(name: "BridgeAgent"), .executableTarget(name: "MockAI")])
