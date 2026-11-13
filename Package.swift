// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GooeyWheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GooeyWheel", path: "Sources/GooeyWheel")
    ]
)
