import AppKit

let options = LaunchOptions(arguments: CommandLine.arguments)

if let iconPath = options.iconPath {
    exit(IconRenderer.write(to: iconPath) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
