import Metal
import AppKit

let options = LaunchOptions(arguments: CommandLine.arguments)

if let iconPath = options.iconPath {
    exit(IconRenderer.write(to: iconPath) ? 0 : 1)
}

if options.listDemoMarks {
    for (name, time) in DemoDriver.steps(of: options.demoScript).marks { print(name, String(format: "%.2f", time)) }
    exit(0)
}

let app = NSApplication.shared

// Shows sample toasts in the bottom-right corner of the screen and writes images of them into
// a folder, for checking how they look.
if let index = CommandLine.arguments.firstIndex(of: "--toast-preview"), index + 1 < CommandLine.arguments.count,
   let device = MTLCreateSystemDefaultDevice(), let screen = NSScreen.main {
    let folder = CommandLine.arguments[index + 1]
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let toast = Toast(device: device)
    let point = CGPoint(x: screen.visibleFrame.maxX - 340, y: screen.visibleFrame.minY + 110)
    func capture(_ name: String, after seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(toast.windowNumber), folder + "/" + name + ".png"]
        try? process.run()
        process.waitUntilExit()
    }
    toast.show(Toast.Message(text: "Copied #3FA7D6", symbol: "circle.fill", swatch: SIMD3(0.25, 0.65, 0.84)), at: point)
    capture("1-growing", after: 0.08)
    capture("2-shown", after: 0.5)
    toast.show(Toast.Message(text: "Allow Accessibility for Gooey Wheel", symbol: "exclamationmark.triangle.fill", isError: true), at: point)
    capture("3-morphing", after: 0.1)
    capture("4-error", after: 0.5)
    toast.show(Toast.Message(text: "Microphone muted", symbol: "mic.slash.fill"), at: point)
    capture("5-short", after: 0.6)
    capture("6-leaving", after: 2.05)
    exit(0)
}

// Writes images of the welcome panel's pages into a folder, without showing it.
if let index = CommandLine.arguments.firstIndex(of: "--welcome-preview"), index + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    if let appearance = options.appearance {
        app.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
    }
    let panel = WelcomePanel()
    panel.writePreview(to: CommandLine.arguments[index + 1])
    exit(0)
}

// Writes the welcome panel from its way in to Done, frame by frame, without showing it.
if let index = CommandLine.arguments.firstIndex(of: "--welcome-record"), index + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    if let appearance = options.appearance {
        app.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
    }
    let panel = WelcomePanel()
    panel.writeRecording(to: CommandLine.arguments[index + 1])
    exit(0)
}

// Runs one action as the wheel would, then waits a few seconds, for checking an action by hand.
if let index = CommandLine.arguments.firstIndex(of: "--run-action"), index + 1 < CommandLine.arguments.count {
    let id = CommandLine.arguments[index + 1]
    let argument = CommandLine.arguments.dropFirst(index + 2).first
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    guard let behavior = ActionBehaviors.behavior(for: id), let run = behavior.run else {
        print("No action \(id)")
        exit(1)
    }
    do {
        try run(ActionInvocation.current.with(argument: argument))
        print("ran \(id)")
    } catch {
        print("failed: \(error)")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(4))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--self-test") {
    let next = CommandLine.arguments.dropFirst(index + 1).first
    let pattern = next.flatMap { $0.hasPrefix("--") ? nil : $0 }
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    exit(SelfTest.run(pattern: pattern))
}

if options.printStageRect, let screen = NSScreen.main {
    print(DemoStage.captureRect(for: options.demoScript, on: screen))
    exit(0)
}

let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
