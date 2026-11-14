import AppKit

let options = LaunchOptions(arguments: CommandLine.arguments)

if let iconPath = options.iconPath {
    exit(IconRenderer.write(to: iconPath) ? 0 : 1)
}

if options.listDemoMarks {
    for (name, time) in DemoDriver.configureMarks { print(name, String(format: "%.2f", time)) }
    exit(0)
}

let app = NSApplication.shared

if options.printStageRect, let screen = NSScreen.main {
    print(DemoStage.captureRect(for: options.demoScript, on: screen))
    exit(0)
}

let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
