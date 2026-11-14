// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GooeyWheel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GooeyWheel", targets: ["GooeyWheel"]),
        // Loaded by /usr/bin/perl to read what is playing, not linked into the app.
        .library(name: "GooeyNowPlaying", type: .dynamic, targets: ["NowPlayingHelper"]),
    ],
    targets: [
        .executableTarget(name: "GooeyWheel", path: "Sources/GooeyWheel"),
        .target(name: "NowPlayingHelper", path: "Sources/NowPlayingHelper"),
    ]
)
