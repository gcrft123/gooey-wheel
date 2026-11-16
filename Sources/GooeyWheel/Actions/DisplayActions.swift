import AppKit

// DisplayServices and CoreBrightness are private frameworks, left out of the App Store edition.
#if !APPSTORE

/// Display and keyboard brightness, through the private frameworks the brightness keys use.
/// They are looked up when first needed; on a Mac without them the actions are unavailable.
enum DisplayActions {
    static let behaviors: [String: ActionBehavior] = {
        var brightness = ActionBehavior(isAvailable: { DisplayBrightness.display() != nil })
        brightness.level = LevelControl(
            read: { DisplayBrightness.display().flatMap(DisplayBrightness.level) },
            write: { value in
                guard let display = DisplayBrightness.display() else { throw ActionError.unavailable("No display with adjustable brightness") }
                try DisplayBrightness.setLevel(value, of: display)
            },
            symbol: { $0 < 0.5 ? "sun.min.fill" : "sun.max.fill" }
        )

        var keyboard = ActionBehavior(isAvailable: { KeyboardBrightness.keyboard != nil })
        keyboard.level = LevelControl(
            read: { KeyboardBrightness.level },
            write: { try KeyboardBrightness.setLevel($0) },
            symbol: { $0 < 0.5 ? "light.min" : "light.max" }
        )

        return [
            "system.brightness": brightness,
            "system.keyboardBrightness": keyboard,
        ]
    }()

    // MARK: Checks

    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("system.brightnessWritesBack") { ctx in
                let displays = DisplayBrightness.onlineDisplays()
                ctx.note(displays.map { "\(DisplayBrightness.name(of: $0)): \(DisplayBrightness.canChange($0) ? "adjustable" : "not adjustable")" }.joined(separator: ", "))
                let behavior = ActionBehaviors.behavior(for: "system.brightness")
                guard let display = DisplayBrightness.display(), let level = behavior?.level else {
                    try ctx.expect(behavior?.isAvailable() == false, "available with no adjustable display")
                    try ctx.expect(behavior?.level?.read() == nil, "a level with no adjustable display")
                    try ctx.skip("no display here has brightness macOS can change")
                }
                try ctx.expect(behavior?.isAvailable() == true, "isAvailable")
                guard let before = level.read() else { throw SelfTest.Failure(message: "can't read the brightness of \(DisplayBrightness.name(of: display))") }
                // Written back as it is, so the screen doesn't change.
                try level.write(before)
                let after = level.read() ?? -1
                ctx.note(String(format: "%.3f → %.3f", before, after))
                try ctx.expect(abs(after - before) < 0.005, "brightness moved from \(before) to \(after)")
            },
            SelfTest.Case("system.brightnessSymbols") { ctx in
                let level = ActionBehaviors.behavior(for: "system.brightness")?.level
                try ctx.expect(level?.symbol?(0.2) == "sun.min.fill" && level?.symbol?(0.8) == "sun.max.fill", "symbols")
                for name in ["sun.min.fill", "sun.max.fill", "light.min", "light.max"] {
                    try ctx.expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "no symbol \(name)")
                }
            },
            SelfTest.Case("system.brightnessReadsAreFast") { ctx in
                // The wheel reads these on the main thread whenever it draws the items.
                let rounds = 50
                for id in ["system.brightness", "system.keyboardBrightness"] {
                    let behavior = ActionBehaviors.behavior(for: id)
                    let start = Date()
                    for _ in 0..<rounds {
                        _ = behavior?.isAvailable()
                        _ = behavior?.level?.read()
                    }
                    let each = Date().timeIntervalSince(start) * 1000 / Double(rounds)
                    ctx.note(String(format: "%@ %.2f ms", id, each))
                    try ctx.expect(each < 2, "\(id) takes \(each) ms")
                }
            },
            SelfTest.Case("system.keyboardBrightnessWritesBack") { ctx in
                let behavior = ActionBehaviors.behavior(for: "system.keyboardBrightness")
                guard KeyboardBrightness.keyboard != nil, let level = behavior?.level else {
                    try ctx.expect(behavior?.isAvailable() == false, "available with no backlit keyboard")
                    try ctx.skip(KeyboardBrightness.client == nil ? "CoreBrightness has no KeyboardBrightnessClient" : "no keyboard with a backlight macOS controls")
                }
                guard let before = level.read() else { throw SelfTest.Failure(message: "can't read the keyboard brightness") }
                try level.write(before)
                let after = level.read() ?? -1
                ctx.note(String(format: "%.3f → %.3f", before, after))
                try ctx.expect(abs(after - before) < 0.005, "brightness moved from \(before) to \(after)")
            },
        ]
    }
}

/// The brightness of displays macOS controls: built-in screens and Apple displays. Other
/// displays answer over DDC at best, which failed on the HDMI display this was tried with,
/// so they are left out.
enum DisplayBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool

    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let get: Get? = symbol("DisplayServicesGetBrightness")
    private static let set: Set? = symbol("DisplayServicesSetBrightness")
    private static let canChangeBrightness: CanChange? = symbol("DisplayServicesCanChangeBrightness")

    private static func symbol<T>(_ name: String) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    static func canChange(_ display: CGDirectDisplayID) -> Bool {
        canChangeBrightness?(display) ?? false
    }

    /// The display under the pointer when its brightness can change, else the first one
    /// whose can, built-in screens first. Nil when none can.
    static func display() -> CGDirectDisplayID? {
        guard get != nil, set != nil else { return nil }
        let pointer = NSEvent.mouseLocation
        let underPointer = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let id = (underPointer?.deviceDescription[key] as? NSNumber)?.uint32Value, canChange(id) { return id }
        return onlineDisplays().sorted { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsBuiltin($1) == 0 }.first(where: canChange)
    }

    static func level(of display: CGDirectDisplayID) -> Double? {
        var value: Float = -1
        guard let get, get(display, &value) == 0, value >= 0 else { return nil }
        return Double(value)
    }

    static func setLevel(_ level: Double, of display: CGDirectDisplayID) throws {
        guard let set else { throw ActionError.unavailable("Display brightness") }
        let status = set(display, Float(min(max(level, 0), 1)))
        guard status == 0 else { throw ActionError.failed("The display refused the brightness (\(status))") }
    }

    static func name(of display: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == display }
        return screen?.localizedName ?? "display \(display)"
    }
}

/// The keyboard backlight macOS controls, as on a MacBook. Keyboards that light themselves,
/// such as Logitech's, aren't listed by CoreBrightness.
enum KeyboardBrightness {
    private typealias GetLevel = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetLevel = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

    /// CoreBrightness's client, or nil when the class or its methods are gone.
    static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = type.init()
        let selectors = [NSSelectorFromString("copyKeyboardBacklightIDs"), getSelector, setSelector]
        return selectors.allSatisfy(client.responds(to:)) ? client : nil
    }()

    /// The first backlit keyboard's identifier, or nil when there is none.
    static var keyboard: UInt64? {
        guard let client else { return nil }
        let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        return ids?.first?.uint64Value
    }

    static var level: Double? {
        guard let client, let keyboard else { return nil }
        let get = unsafeBitCast(client.method(for: getSelector), to: GetLevel.self)
        return Double(get(client, getSelector, keyboard))
    }

    static func setLevel(_ level: Double) throws {
        guard let client, let keyboard else { throw ActionError.unavailable("Keyboard backlight") }
        let set = unsafeBitCast(client.method(for: setSelector), to: SetLevel.self)
        guard set(client, setSelector, Float(min(max(level, 0), 1)), keyboard) else {
            throw ActionError.failed("The keyboard backlight refused the change")
        }
    }
}
#endif
