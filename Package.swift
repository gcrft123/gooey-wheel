// swift-tools-version: 5.10
import Foundation
import PackageDescription

// GOOEY_APPSTORE=1 builds the Mac App Store edition (scripts/build-mas.sh): it leaves out Sparkle,
// since the App Store installs updates, and sets the APPSTORE condition, which compiles out what the
// App Sandbox blocks or App Review doesn't allow.
let appStore = ProcessInfo.processInfo.environment["GOOEY_APPSTORE"] == "1"

let package = Package(
    name: "GooeyWheel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GooeyWheel", targets: ["GooeyWheel"]),
        // Loaded by /usr/bin/perl to read what is playing, not linked into the app.
        .library(name: "GooeyNowPlaying", type: .dynamic, targets: ["NowPlayingHelper"]),
    ],
    targets: [
        .executableTarget(
            name: "GooeyWheel",
            dependencies: appStore ? [] : ["Sparkle"],
            path: "Sources/GooeyWheel",
            swiftSettings: appStore ? [.define("APPSTORE")] : [],
            // Finds Sparkle.framework in the app's Contents/Frameworks, where scripts/build-app.sh
            // copies it, and next to the binary when it runs from the build folder.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            ])]
        ),
        .target(name: "NowPlayingHelper", path: "Sources/NowPlayingHelper"),
        // The release Sparkle publishes for SwiftPM, taken directly instead of through Sparkle's
        // package, which would clone its whole repository. The zip also holds the command line
        // tools scripts/release.sh uses.
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
        ),
    ]
)
