// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArchitectureTests",
    platforms: [.macOS(.v14)],
    targets: [
        .testTarget(name: "ArchitectureInvariantTests")
    ]
)
