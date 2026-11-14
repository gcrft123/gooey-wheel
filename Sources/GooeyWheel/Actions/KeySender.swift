import AppKit
import Carbon.HIToolbox

/// A key and the modifiers held with it.
struct KeyCombo: Equatable {
    var key: CGKeyCode
    var modifiers: CGEventFlags = []

    init(_ key: Int, _ modifiers: CGEventFlags = []) {
        self.key = CGKeyCode(key)
        self.modifiers = modifiers
    }

    /// A key found by the character it types in the current keyboard layout, so ⌘C is ⌘C on
    /// AZERTY and Dvorak too.
    static func character(_ character: Character, _ modifiers: CGEventFlags = []) -> KeyCombo? {
        guard let found = KeyLayout.current.key(for: character) else { return nil }
        return KeyCombo(Int(found.code), modifiers.union(found.shift ? .maskShift : []))
    }

    /// Parses menu notation as the keystroke recorder stores it: modifier symbols, then a key
    /// name or a character, such as "⌃⌥⌘T", "⇧⌘Space" or "F5".
    init?(notation: String) {
        var flags: CGEventFlags = []
        var rest = Substring(notation)
        let symbols: [Character: CGEventFlags] = ["⌃": .maskControl, "⌥": .maskAlternate, "⇧": .maskShift, "⌘": .maskCommand, "🌐": .maskSecondaryFn]
        while let first = rest.first, let flag = symbols[first], rest.count > 1 {
            flags.insert(flag)
            rest = rest.dropFirst()
        }
        let name = String(rest)
        if let code = KeyCombo.named[name] {
            self.init(code, flags)
            return
        }
        guard name.count == 1, let character = name.first else { return nil }
        // The recorder stores letters in upper case. The key is the one that types the lower case.
        let lower = Character(name.lowercased())
        if let found = KeyLayout.current.key(for: lower) ?? KeyLayout.current.key(for: character) {
            self.init(Int(found.code), flags.union(found.shift ? .maskShift : []))
        } else {
            return nil
        }
    }

    /// Keys stored by name rather than by the character they type. Matches the recorder.
    static let named: [String: Int] = [
        "↩": kVK_Return, "⇥": kVK_Tab, "Space": kVK_Space, "⌫": kVK_Delete, "⌦": kVK_ForwardDelete,
        "←": kVK_LeftArrow, "→": kVK_RightArrow, "↓": kVK_DownArrow, "↑": kVK_UpArrow,
        "↖": kVK_Home, "↘": kVK_End, "⇞": kVK_PageUp, "⇟": kVK_PageDown, "⌤": kVK_ANSI_KeypadEnter,
        "⎋": kVK_Escape,
        "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6,
        "F7": kVK_F7, "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
        "F13": kVK_F13, "F14": kVK_F14, "F15": kVK_F15, "F16": kVK_F16, "F17": kVK_F17, "F18": kVK_F18,
        "F19": kVK_F19, "F20": kVK_F20,
    ]
}

/// Which key types a character, read from the keyboard layout in use.
struct KeyLayout {
    private var keys: [Character: (code: CGKeyCode, shift: Bool)] = [:]
    let sourceID: String

    private static var cached: KeyLayout?

    /// The layout in use. Rebuilt when the user switches input source.
    static var current: KeyLayout {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let id = property(source, kTISPropertyInputSourceID) ?? ""
        if let cached, cached.sourceID == id { return cached }
        let layout = KeyLayout(source: source, id: id)
        cached = layout
        return layout
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private init(source: TISInputSource, id: String) {
        sourceID = id
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            // Unshifted first, so a character on two keys maps to the one that needs no Shift.
            for shift in [false, true] {
                for code in 0..<128 {
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                    let status = UCKeyTranslate(
                        layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars
                    )
                    guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) else { continue }
                    let character = Character(scalar)
                    // Keypad keys type digits too. The main row is the one shortcuts mean.
                    if keys[character] == nil, !Self.keypad.contains(code) {
                        keys[character] = (CGKeyCode(code), shift)
                    }
                }
            }
        }
    }

    private static let keypad: Set<Int> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    func key(for character: Character) -> (code: CGKeyCode, shift: Bool)? {
        keys[character]
    }
}

/// Sends key presses to the app in front, as if typed.
enum KeySender {
    /// Posting input into other apps needs Accessibility. Without it the system drops the events silently.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requireTrust() throws {
        guard isTrusted else { throw ActionError.needsAccessibility }
    }

    /// Events carry their own modifier state, not the keyboard's, so a ⌃⌥ still held from the
    /// wheel's shortcut doesn't leak into them.
    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        return source
    }()

    private static let modifierKeys: [(CGEventFlags, Int)] = [
        (.maskControl, kVK_Control), (.maskAlternate, kVK_Option), (.maskShift, kVK_Shift), (.maskCommand, kVK_Command),
    ]

    /// The events for one press of a combination: modifiers down, the key down and up,
    /// modifiers up. Apps that watch modifier keys separately see them as well.
    static func events(for combo: KeyCombo) -> [CGEvent] {
        var events: [CGEvent] = []
        var held: CGEventFlags = []
        let mods = modifierKeys.filter { combo.modifiers.contains($0.0) }
        for (flag, code) in mods {
            held.insert(flag)
            if let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true) {
                e.flags = held
                events.append(e)
            }
        }
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: source, virtualKey: combo.key, keyDown: down) {
                // Arrow and function keys carry these flags when typed. Some apps check them.
                e.flags = combo.modifiers.union(Self.extraFlags(for: combo.key))
                events.append(e)
            }
        }
        for (flag, code) in mods.reversed() {
            held.remove(flag)
            if let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) {
                e.flags = held
                events.append(e)
            }
        }
        return events
    }

    private static func extraFlags(for key: CGKeyCode) -> CGEventFlags {
        let arrows: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        let function: Set<Int> = [kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help,
                                  kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                  kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        if arrows.contains(Int(key)) { return [.maskNumericPad, .maskSecondaryFn] }
        if function.contains(Int(key)) { return .maskSecondaryFn }
        return []
    }

    /// Where events go. Tests send them to one process; in use they go through the system,
    /// so system-wide shortcuts such as ⇧⌘4 work too.
    static var target: pid_t?
    /// Takes the events instead of posting them, for checks of actions whose effect would be
    /// visible to whoever is using the Mac.
    static var recorder: ((CGEvent) -> Void)?

    static func post(_ events: [CGEvent]) {
        for event in events {
            if let recorder {
                recorder(event)
            } else if let target {
                event.postToPid(target)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }
    }

    static func post(_ combo: KeyCombo) throws {
        try requireTrust()
        post(events(for: combo))
    }

    /// Posts a combination the user recorded, in menu notation.
    static func post(notation: String) throws {
        guard let combo = KeyCombo(notation: notation) else {
            throw ActionError.failed("No key on this keyboard layout makes \(notation)")
        }
        try post(combo)
    }

    // MARK: Special keys

    /// The media and system keys on Apple keyboards, as NX_KEYTYPE values from IOKit's ev_keymap.h.
    enum SpecialKey: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        case play = 16, next = 17, previous = 18, fast = 19, rewind = 20
        case illuminationUp = 21, illuminationDown = 22
    }

    /// The down and up events for a media or system key. They arrive like the keys on an
    /// Apple keyboard, so they reach whatever the system routes those keys to.
    static func events(for key: SpecialKey) -> [CGEvent] {
        [true, false].compactMap { down in
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data = (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8)
            return NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, subtype: 8, data1: data, data2: -1
            )?.cgEvent
        }
    }

    static func post(_ key: SpecialKey) throws {
        try requireTrust()
        post(events(for: key))
    }

    // MARK: Text

    /// Types text at the cursor, as key presses carrying the characters themselves, so it
    /// doesn't depend on the keyboard layout. Line breaks are sent as Return.
    static func type(_ text: String) throws {
        try requireTrust()
        post(events(typing: text))
    }

    static func events(typing text: String) -> [CGEvent] {
        var events: [CGEvent] = []
        // Lines are typed one at a time with Return between them: a line break carried as a
        // character isn't taken as Return by every app.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 { events += Self.events(for: KeyCombo(kVK_Return)) }
            // Apps read at most 20 UTF-16 units from one event.
            var units = Array(line.utf16)[...]
            while !units.isEmpty {
                var count = min(units.count, 20)
                // Never split a surrogate pair.
                if count < units.count, UTF16.isLeadSurrogate(units[units.startIndex + count - 1]) { count -= 1 }
                let chunk = Array(units.prefix(count))
                units = units.dropFirst(count)
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    e.flags = []
                    chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    events.append(e)
                }
            }
        }
        return events
    }

    // MARK: Waiting for the keyboard

    /// Runs `body` once no modifier key is held. A ⌃⌥ still held from the wheel's shortcut would
    /// otherwise join a shortcut that system services read from the keyboard itself, and ⌥
    /// turns some menu commands into versions that skip their confirmation. After `timeout`
    /// it runs anyway, or with `required` it calls `gaveUp` instead.
    static func whenModifiersReleased(timeout: TimeInterval = 0.5, required: Bool = false, gaveUp: (() -> Void)? = nil, _ body: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            let held = CGEventSource.flagsState(.hidSystemState).intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            if held.isEmpty {
                body()
            } else if Date() > deadline {
                if required { gaveUp?() } else { body() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
            }
        }
        check()
    }
}
