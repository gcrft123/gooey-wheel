import AppKit
import Carbon.HIToolbox

/// Mission Control and Spaces, system panels, appearance and power, and the session.
enum SystemActions {
    static let behaviors: [String: ActionBehavior] = {
        // A shortcut lent by a run that crashed goes back before anything lends one again.
        SymbolicHotKey.restoreInterrupted()

        var map: [String: ActionBehavior] = [
            "desktop.missionControl": afterClose { _ in try Dock.show(.missionControl) },
            "desktop.appExpose": afterClose { _ in try Dock.show(.appExpose) },
            "desktop.showDesktop": afterClose { _ in try Dock.show(.desktop) },
            "desktop.launchpad": afterClose { _ in try Dock.show(.apps) },
            "desktop.spaceLeft": ActionBehavior(run: { _ in try SymbolicHotKey.press(SymbolicHotKey.spaceLeft) }),
            "desktop.spaceRight": ActionBehavior(run: { _ in try SymbolicHotKey.press(SymbolicHotKey.spaceRight) }),

            "system.screenshot": afterClose { invocation in try Screenshots.take(invocation.argument ?? "selection") },
            "system.colorPicker": afterClose { invocation in ColorPicker.pick(returningTo: invocation.frontmost) },
            "system.spotlight": afterClose { _ in try SystemShortcut.press(SymbolicHotKey.spotlight) },
            // Pressing the clock in the menu bar through Accessibility opens Notification Center
            // and closes it again half a second later, on macOS 27. Its shortcut opens it for good,
            // lent a key combination when the user hasn't given it one.
            "system.notificationCenter": afterClose { _ in
                do {
                    try SystemShortcut.press(SymbolicHotKey.notificationCenter)
                } catch let error as ActionError {
                    guard case .needsAccessibility = error, let clock = MenuItems.menuExtra("com.apple.menuextra.clock") else { throw error }
                    try MenuItems.press(clock)
                }
            },
            "system.controlCenter": afterClose { _ in
                guard let extra = MenuItems.menuExtra("com.apple.menuextra.controlcenter") else {
                    throw ActionError.failed("Couldn't find Control Center in the menu bar")
                }
                try MenuItems.press(extra)
            },
            // AppKit adds both to every app's Edit menu, named after the actions they send.
            "system.dictation": afterClose { invocation in
                try KeySender.requireTrust()
                guard let pid = MenuItems.menuOwner(invocation.frontmost),
                      let item = MenuItems.item(in: pid, identifier: "startDictation:"), MenuItems.isEnabled(item) else {
                    throw ActionError.unavailable("This app has no Dictation")
                }
                try MenuItems.press(item)
            },
            "system.emoji": afterClose { invocation in
                try KeySender.requireTrust()
                if let pid = MenuItems.menuOwner(invocation.frontmost),
                   let item = MenuItems.item(in: pid, identifier: "orderFrontCharacterPalette:"), MenuItems.isEnabled(item) {
                    try MenuItems.press(item)
                } else {
                    try sendKeys(KeyCombo(kVK_Space, [.maskControl, .maskCommand]))
                }
            },
            // Siri.app does what the Siri key does. Siri AI.app is the typed chat.
            "system.siri": ActionBehavior(timing: .afterClose, isAvailable: { SystemApps.url(siri) != nil }) { _ in
                try SystemApps.open(siri)
            },

            "system.lockScreen": afterClose { invocation in try Session.lock(invocation.frontmost) },
            "system.sleep": ActionBehavior(timing: .afterClose, isAvailable: { !Session.sleepIsDisabled }) { _ in try Session.sleep() },
            "system.displaySleep": afterClose { _ in try Session.displaySleep() },
            "system.screenSaver": afterClose { _ in try SystemApps.open(screenSaver) },
            "system.switchUser": afterClose { _ in try Session.switchUser() },
            "system.logOut": afterClose { invocation in try Session.pressAppleItem(.logOut, invocation.frontmost) },
            "system.restart": afterClose { invocation in try Session.pressAppleItem(.restart, invocation.frontmost) },
            "system.shutDown": afterClose { invocation in try Session.pressAppleItem(.shutDown, invocation.frontmost) },
            "system.forceQuit": afterClose { invocation in
                do {
                    try Session.pressAppleItem(.forceQuit, invocation.frontmost)
                } catch ActionError.failed {
                    try sendKeys(KeyCombo(kVK_Escape, [.maskCommand, .maskAlternate]))
                }
            },
            "system.emptyTrash": afterClose { _ in try Trash.empty() },
        ]

        map["system.appearance"] = toggle(isOn: { Appearance.isDark }, set: Appearance.setIsDark)
        map["system.toggleDock"] = toggle(isOn: { Dock.autoHides }, set: Dock.setAutoHides)
        map["system.keepAwake"] = toggle(isOn: { KeepAwake.isOn }, set: KeepAwake.set)
        map["system.wifi"] = toggle(isOn: { WiFi.isOn }, isAvailable: { WiFi.interface != nil }, set: WiFi.set)
        map["system.doNotDisturb"] = shortcutToggle(SymbolicHotKey.doNotDisturb) { FocusState.isOn }
        map["desktop.stageManager"] = shortcutToggle(SymbolicHotKey.stageManager) { stageManagerIsOn }
        return map
    }()

    static let siri = "com.apple.siri.launcher"
    static let screenSaver = "com.apple.ScreenSaver.Engine"

    private static func afterClose(_ run: @escaping (ActionInvocation) throws -> Void) -> ActionBehavior {
        ActionBehavior(timing: .afterClose, run: run)
    }

    private static func sendKeys(_ combo: KeyCombo) throws {
        try KeySender.requireTrust()
        KeySender.whenModifiersReleased { try? KeySender.post(combo) }
    }

    /// A toggle whose state can be read and set.
    private static func toggle(
        isOn: @escaping () -> Bool?,
        isAvailable: @escaping () -> Bool = { true },
        set: @escaping (Bool) throws -> Void
    ) -> ActionBehavior {
        var behavior = ActionBehavior(isAvailable: isAvailable) { _ in
            guard let on = isOn() else { throw ActionError.unavailable("its current state") }
            try set(!on)
        }
        behavior.isOn = { _ in isOn() }
        return behavior
    }

    /// A toggle flipped by a system shortcut. The state, when it can be read at all, changes
    /// a moment after the shortcut arrives, so the wheel is told to read it again.
    private static func shortcutToggle(_ id: Int, isOn: @escaping () -> Bool?) -> ActionBehavior {
        var behavior = ActionBehavior(run: { _ in
            try SymbolicHotKey.press(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotificationCenter.default.post(name: ActionBehaviors.stateDidChange, object: nil)
            }
        })
        behavior.isOn = { _ in isOn() }
        return behavior
    }

    /// Stage Manager's switch, which WindowManager keeps in its preferences.
    static var stageManagerIsOn: Bool? {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) as? Bool ?? false
    }

    // MARK: Checks

    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("system.privateCallsResolve") { ctx in
                let calls: [(String, Bool)] = [
                    ("CoreDockSendNotification", Dock.sendNotification != nil),
                    ("CoreDockGetAutoHideEnabled", Dock.getAutoHide != nil),
                    ("CoreDockSetAutoHideEnabled", Dock.setAutoHide != nil),
                    ("SLSGetAppearanceThemeLegacy", Appearance.getDark != nil),
                    ("SLSSetAppearanceThemeLegacy", Appearance.setDark != nil),
                    ("SLSGetAppearanceThemeSwitchesAutomatically", Appearance.getAuto != nil),
                    ("SLSSetAppearanceThemeSwitchesAutomatically", Appearance.setAuto != nil),
                    ("SLS…SymbolicHotKey…", SymbolicHotKey.isSupported),
                    ("SACLockScreenImmediate", Session.lockScreen != nil),
                    ("SACSwitchToLoginWindow", Session.switchToLoginWindow != nil),
                    ("IOPMCopySystemPowerSettings", Session.copyPowerSettings != nil),
                ]
                let missing = calls.filter { !$0.1 }.map(\.0)
                try ctx.expect(missing.isEmpty, "missing: \(missing.joined(separator: ", "))")
            },
            SelfTest.Case("system.everyActionHasABehavior") { ctx in
                let ids = ActionCatalog.categories.flatMap(\.actions).map(\.id).filter { behaviors[$0] != nil }
                try ctx.expect(ids.count == behaviors.count, "behaviors for ids not in the catalog: \(Set(behaviors.keys).subtracting(ids).sorted())")
                ctx.note("\(ids.count) actions")
            },
            SelfTest.Case("desktop.missionControlFamily") { ctx in
                // Each would cover the screen, so this stops at the call and the fallback apps.
                try ctx.expect(Dock.sendNotification != nil, "CoreDockSendNotification missing")
                for overview in [Dock.Overview.missionControl, .appExpose, .desktop, .apps] {
                    try ctx.expect(SystemApps.url(overview.app.bundleID) != nil, "no app for \(overview.app.bundleID)")
                }
            },
            SelfTest.Case("desktop.spacesSendTheUsersShortcut") { ctx in
                try KeySender.requireTrust()
                for (id, action) in [(SymbolicHotKey.spaceLeft, "desktop.spaceLeft"), (SymbolicHotKey.spaceRight, "desktop.spaceRight")] {
                    guard let combo = SymbolicHotKey.userCombo(id) else {
                        ctx.note("\(action): shortcut off, lent while sent")
                        continue
                    }
                    let tap = EventRecorder()
                    defer { tap.stop() }
                    try ActionBehaviors.behavior(for: action)?.run?(.current)
                    let key = tap.events.first { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(combo.key) && $0.type == .keyDown }
                    try ctx.expect(key != nil, "\(action) sent no key \(combo.key)")
                    let flags = key?.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]) ?? []
                    try ctx.expect(flags == combo.modifiers.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]), "\(action) flags \(flags)")
                    ctx.note("\(action) key \(combo.key)")
                }
            },
            SelfTest.Case("desktop.stageManagerState") { ctx in
                let on = try unwrap(stageManagerIsOn, ctx, "GloballyEnabled unreadable")
                try ctx.expect(ActionBehaviors.behavior(for: "desktop.stageManager")?.isOn?(.current) == on, "behavior disagrees")
                ctx.note("Stage Manager \(on ? "on" : "off"), shortcut \(SymbolicHotKey.userCombo(SymbolicHotKey.stageManager) == nil ? "lent" : "the user's")")
            },
            SelfTest.Case("system.hotkeyTableReads") { ctx in
                try ctx.expect(SymbolicHotKey.isSupported, "no symbolic hotkey calls")
                var notes: [String] = []
                for id in [28, 30, 31, 64, 79, 81, 163, 175, 222] {
                    let value = try unwrap(SymbolicHotKey.value(id), ctx, "\(id) unreadable")
                    notes.append("\(id)=\(value.enabled && value.hasKey ? "key \(value.key)" : "off")")
                }
                ctx.note(notes.joined(separator: " "))
            },
            SelfTest.Case("system.hotkeyLoanRoundTrip") { ctx in
                // Lends Do Not Disturb's shortcut and records the combination instead of
                // sending it, so nothing toggles. The table must read back as it was.
                try ctx.expect(!SymbolicHotKey.hasSavedLoans, "a loan was left over before the check")
                let id = SymbolicHotKey.doNotDisturb
                let original = try unwrap(SymbolicHotKey.value(id), ctx, "unreadable")
                if original.enabled && original.hasKey { try ctx.skip("the user has a key for Do Not Disturb, so nothing is lent") }
                var sent: KeyCombo?
                var during: SymbolicHotKey.Value?
                var saved = false
                try SymbolicHotKey.press(id) { combo in
                    sent = combo
                    during = SymbolicHotKey.value(id)
                    saved = SymbolicHotKey.hasSavedLoans
                }
                try ctx.expect(during?.enabled == true && during?.combo == sent && sent?.key == CGKeyCode(kVK_F19), "lent \(String(describing: during)), sent \(String(describing: sent))")
                try ctx.expect(saved, "the loan wasn't saved before the change")
                // A second press while lent reuses the loan.
                try SymbolicHotKey.press(id) { try ctx.expect($0 == sent, "second press lent \($0)") }
                let returned = ctx.wait(upTo: SymbolicHotKey.loanDuration + 1) { SymbolicHotKey.value(id) == original }
                try ctx.expect(returned, "table reads \(String(describing: SymbolicHotKey.value(id))) after, was \(original)")
                try ctx.expect(!SymbolicHotKey.hasSavedLoans, "saved loan not cleared")
            },
            SelfTest.Case("system.hotkeyLoanRestoredAfterCrash") { ctx in
                let id = SymbolicHotKey.doNotDisturb
                let original = try unwrap(SymbolicHotKey.value(id), ctx, "unreadable")
                let lent = SymbolicHotKey.Value(character: 0xFFFF, key: UInt16(kVK_F18), modifiers: 0x9E0000, enabled: true)
                // A run that lent the shortcut and died before giving it back.
                SymbolicHotKey.savedLoans = [String(id): .init(original: original, lent: lent)]
                SymbolicHotKey.write(id, lent)
                SymbolicHotKey.restoreInterrupted()
                try ctx.expect(SymbolicHotKey.value(id) == original, "not restored: \(String(describing: SymbolicHotKey.value(id)))")
                try ctx.expect(!SymbolicHotKey.hasSavedLoans, "record left")
                // One the user changed since is left alone.
                SymbolicHotKey.savedLoans = [String(id): .init(original: lent, lent: lent)]
                SymbolicHotKey.write(id, original)
                SymbolicHotKey.restoreInterrupted()
                try ctx.expect(SymbolicHotKey.value(id) == original && !SymbolicHotKey.hasSavedLoans, "changed shortcut overwritten")
            },
            SelfTest.Case("system.screenshotShortcuts") { ctx in
                try ctx.expect(SystemApps.url("com.apple.screenshot.launcher") != nil, "no Screenshot app")
                try ctx.expect(FileManager.default.isExecutableFile(atPath: "/usr/sbin/screencapture"), "no screencapture")
                var notes: [String] = []
                for (choice, id) in Screenshots.shortcuts.sorted(by: { $0.value < $1.value }) {
                    let before = try unwrap(SymbolicHotKey.value(id), ctx, "\(id) unreadable")
                    var sent: KeyCombo?
                    try SymbolicHotKey.press(id) { sent = $0 }
                    try ctx.expect(sent != nil, "\(choice) sent nothing")
                    let back = ctx.wait(upTo: SymbolicHotKey.loanDuration + 1) { SymbolicHotKey.value(id) == before }
                    try ctx.expect(back, "\(id) not given back")
                    notes.append("\(choice): \(before.enabled && before.hasKey ? "user's" : "lent")")
                }
                ctx.note(notes.joined(separator: ", "))
            },
            SelfTest.Case("system.doNotDisturbState") { ctx in
                let state = ActionBehaviors.behavior(for: "system.doNotDisturb")?.isOn?(.current)
                try ctx.expect(state == FocusState.isOn, "behavior disagrees with the database")
                guard let state else { try ctx.skip("Focus database unreadable without Full Disk Access; the toggle still works, its state shows as unknown") }
                ctx.note("Focus \(state ? "on" : "off")")
            },
            SelfTest.Case("system.appearance") { ctx in
                let dark = try unwrap(Appearance.isDark, ctx, "unreadable")
                let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
                try ctx.expect(dark == (style == "Dark"), "SkyLight says \(dark), AppleInterfaceStyle says \(style ?? "Light")")
                let auto = Appearance.switchesAutomatically ?? false
                ctx.note("\(dark ? "Dark" : "Light")\(auto ? ", Auto" : "")")
                // Choosing the current appearance changes nothing, unless Auto is on: it
                // would turn Auto off.
                if auto { return }
                try Appearance.setIsDark(dark)
                try ctx.expect(Appearance.isDark == dark, "appearance changed")
            },
            SelfTest.Case("system.dockHiding") { ctx in
                let hides = try unwrap(Dock.autoHides, ctx, "unreadable")
                try Dock.setAutoHides(hides)
                try ctx.expect(Dock.autoHides == hides, "changed")
                ctx.note("hiding \(hides ? "on" : "off")")
            },
            SelfTest.Case("system.keepAwake") { ctx in
                try ctx.expect(!KeepAwake.isOn, "already on")
                let behavior = try unwrap(ActionBehaviors.behavior(for: "system.keepAwake"), ctx, "missing")
                try behavior.run?(.current)
                defer { try? KeepAwake.set(false) }
                try ctx.expect(behavior.isOn?(.current) == true, "not on")
                var byProcess: Unmanaged<CFDictionary>?
                IOPMCopyAssertionsByProcess(&byProcess)
                let mine = (byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]])?[NSNumber(value: getpid())] ?? []
                try ctx.expect(mine.contains { $0["AssertType"] as? String == "PreventUserIdleDisplaySleep" }, "no assertion held")
                try behavior.run?(.current)
                try ctx.expect(behavior.isOn?(.current) == false, "still on")
            },
            SelfTest.Case("system.wifi") { ctx in
                guard let interface = WiFi.interface else { try ctx.skip("no Wi-Fi interface") }
                let on = try unwrap(WiFi.isOn, ctx, "power unreadable")
                // Setting the current power state changes nothing.
                try interface.setPower(on)
                try ctx.expect(WiFi.isOn == on, "changed")
                ctx.note("\(interface.interfaceName ?? "?") \(on ? "on" : "off")")
            },
            SelfTest.Case("system.menuExtras") { ctx in
                try KeySender.requireTrust()
                for id in ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"] {
                    let extra = try unwrap(MenuItems.menuExtra(id), ctx, "\(id) not found")
                    var names: CFArray?
                    AXUIElementCopyActionNames(extra, &names)
                    try ctx.expect((names as? [String] ?? []).contains(kAXPressAction), "\(id) can't be pressed")
                }
            },
            SelfTest.Case("system.editMenuItems") { ctx in
                try KeySender.requireTrust()
                let finder = try unwrap(Trash.finder, ctx, "Finder not running")
                for id in ["startDictation:", "orderFrontCharacterPalette:"] {
                    _ = try unwrap(MenuItems.item(in: finder.processIdentifier, identifier: id), ctx, "\(id) not in Finder's menus")
                }
            },
            SelfTest.Case("system.appleMenuItems") { ctx in
                try KeySender.requireTrust()
                let finder = try unwrap(Trash.finder, ctx, "Finder not running")
                for which in MenuItems.AppleItem.allCases {
                    let found = try unwrap(MenuItems.appleItem(which, in: finder.processIdentifier), ctx, "\(which) not found")
                    let byShortcut = try unwrap(MenuItems.appleItem(which, in: finder.processIdentifier, byIdentifier: false), ctx, "\(which) not found by shortcut")
                    try ctx.expect(CFEqual(found, byShortcut), "\(which): identifier and shortcut find different items")
                }
            },
            SelfTest.Case("system.emptyTrash") { ctx in
                // Found, not pressed.
                try KeySender.requireTrust()
                let item = try unwrap(Trash.emptyTrashItem(), ctx, "Finder's Empty Trash not found")
                ctx.note("\(MenuItems.isEnabled(item) ? "Trash has items" : "Trash empty"), Finder \(Trash.finderWarns ? "warns" : "doesn't warn, the app asks")")
            },
            SelfTest.Case("system.sessionAndPower") { ctx in
                let port = IOPMFindPowerManagement(kIOMainPortDefault)
                try ctx.expect(port != 0, "no power management connection")
                IOServiceClose(port)
                try ctx.expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/pmset"), "no pmset")
                try ctx.expect(SystemApps.url(screenSaver) != nil, "no screen saver app")
                try ctx.expect(SystemApps.url(siri) != nil, "no Siri app")
                let available = ActionBehaviors.behavior(for: "system.sleep")?.isAvailable() ?? false
                try ctx.expect(available == !Session.sleepIsDisabled, "sleep availability")
                ctx.note("sleep \(Session.sleepIsDisabled ? "disabled system-wide, so Sleep is unavailable" : "allowed")")
            },
            SelfTest.Case("system.colorPickerHex") { ctx in
                try ctx.expect(ColorPicker.hex(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#FF8000", "orange")
                try ctx.expect(ColorPicker.hex(NSColor(white: 1, alpha: 1)) == "#FFFFFF", "white")
                let p3 = ColorPicker.hex(NSColor(displayP3Red: 0, green: 0, blue: 1, alpha: 1))
                try ctx.expect(p3 == "#0000FF", "Display P3 blue converts to \(p3)")
                try ctx.preservingClipboard {
                    ColorPicker.copy("#123ABC")
                    try ctx.expect(NSPasteboard.general.string(forType: .string) == "#123ABC", "clipboard")
                }
                try ctx.expect(NSClassFromString("NSColorSampler") != nil, "no NSColorSampler")
            },
        ]
    }

    private static func unwrap<T>(_ value: T?, _ ctx: SelfTest.Context, _ message: String) throws -> T {
        guard let value else { throw SelfTest.Failure(message: message) }
        return value
    }
}
