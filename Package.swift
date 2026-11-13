// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ActionsWheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ActionsWheel", path: "Sources/ActionsWheel")
    ]
)
