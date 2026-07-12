// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppFeature",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppFeature", targets: ["AppFeature"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../IPCContract")
    ],
    targets: [
        .target(name: "AppFeature", dependencies: ["Core", "IPCContract"]),
        .testTarget(name: "AppFeatureTests", dependencies: ["AppFeature"])
    ]
)
