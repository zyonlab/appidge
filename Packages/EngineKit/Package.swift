// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EngineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EngineKit", targets: ["EngineKit"])
    ],
    dependencies: [
        .package(path: "../IPCContract")
    ],
    targets: [
        .target(name: "EngineKit", dependencies: ["IPCContract"]),
        .testTarget(name: "EngineKitTests", dependencies: ["EngineKit"])
    ]
)
