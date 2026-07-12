// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IPCContract",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IPCContract", targets: ["IPCContract"])
    ],
    targets: [
        .target(name: "IPCContract"),
        .testTarget(name: "IPCContractTests", dependencies: ["IPCContract"])
    ]
)
