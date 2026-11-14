import AppKit
import Carbon.HIToolbox

/// Editing and browsing actions: the standard shortcuts every Mac app answers to, sent to the
/// app in front.
enum EditingActions {
    private static func letter(_ c: Character, _ modifiers: CGEventFlags = .maskCommand) -> KeyCombo {
        // A layout with no key for the letter falls back to its key on a US keyboard.
        KeyCombo.character(c, modifiers) ?? KeyCombo(usKeys[c] ?? kVK_ANSI_A, modifiers)
    }

    private static let usKeys: [Character: Int] = [
        "a": kVK_ANSI_A, "c": kVK_ANSI_C, "f": kVK_ANSI_F, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "z": kVK_ANSI_Z, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "=": kVK_ANSI_Equal,
        "-": kVK_ANSI_Minus, "0": kVK_ANSI_0,
    ]

    /// The combination for an action, looked up when it runs, so a change of keyboard layout
    /// since launch is taken into account.
    private static func keys(_ combo: @escaping () -> KeyCombo) -> ActionBehavior {
        ActionBehavior { _ in try KeySender.post(combo()) }
    }

    static let zoomIn = { letter("=") }
    static let zoomOut = { letter("-") }

    static let behaviors: [String: ActionBehavior] = {
        var map: [String: ActionBehavior] = [
            "edit.copy": keys { letter("c") },
            "edit.cut": keys { letter("x") },
            "edit.paste": keys { letter("v") },
            "edit.pasteMatchStyle": keys { letter("v", [.maskCommand, .maskAlternate, .maskShift]) },
            "edit.redo": keys { letter("z", [.maskCommand, .maskShift]) },
            "edit.selectAll": keys { letter("a") },
            "edit.find": keys { letter("f") },
            "edit.save": keys { letter("s") },
            "edit.new": keys { letter("n") },
            "edit.open": keys { letter("o") },
            "edit.print": keys { letter("p") },
            "edit.refresh": keys { letter("r") },
            "edit.newTab": keys { letter("t") },
            "edit.closeTab": keys { letter("w") },
            "edit.reopenTab": keys { letter("t", [.maskCommand, .maskShift]) },
            "navigation.back": keys { letter("[") },
            "navigation.forward": keys { letter("]") },
            // Home and End scroll to the top and bottom without moving the insertion point.
            "navigation.home": keys { KeyCombo(kVK_Home) },
            "navigation.end": keys { KeyCombo(kVK_End) },
        ]

        // Scrolling up undoes, going back in time, and scrolling down redoes.
        var undo = keys { letter("z") }
        undo.step = { notches, _ in
            let combo = notches < 0 ? letter("z") : letter("z", [.maskCommand, .maskShift])
            for _ in 0..<abs(notches) { try KeySender.post(combo) }
        }
        map["edit.undo"] = undo

        // Scrolling up zooms in, as in Maps and Photos. Choosing it goes back to actual size.
        var zoom = keys { letter("0") }
        zoom.step = { notches, _ in
            let combo = notches < 0 ? zoomIn() : zoomOut()
            for _ in 0..<abs(notches) { try KeySender.post(combo) }
        }
        map["edit.zoom"] = zoom

        // Scrolling down moves to the next tab, as down a list. Choosing it goes to the next tab.
        let nextTab = KeyCombo(kVK_Tab, .maskControl)
        let previousTab = KeyCombo(kVK_Tab, [.maskControl, .maskShift])
        var tabs = ActionBehavior { _ in try KeySender.post(nextTab) }
        tabs.step = { notches, _ in
            for _ in 0..<abs(notches) { try KeySender.post(notches > 0 ? nextTab : previousTab) }
        }
        map["navigation.tabs"] = tabs
        return map
    }()

    // MARK: Checks

    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("keys.layoutFindsLetters") { ctx in
                let layout = KeyLayout.current
                ctx.note(layout.sourceID)
                for c in "acvxz[]=-0" {
                    try ctx.expect(layout.key(for: c) != nil, "no key types \(c)")
                }
            },
            SelfTest.Case("keys.notation") { ctx in
                let combo = KeyCombo(notation: "⌃⌥⌘T")
                try ctx.expect(combo?.modifiers == [.maskControl, .maskAlternate, .maskCommand], "modifiers of ⌃⌥⌘T")
                try ctx.expect(combo?.key == KeyCombo.character("t")?.key, "key of ⌃⌥⌘T")
                try ctx.expect(KeyCombo(notation: "⇧⌘Space")?.key == CGKeyCode(kVK_Space), "⇧⌘Space")
                try ctx.expect(KeyCombo(notation: "F5")?.key == CGKeyCode(kVK_F5), "F5")
                try ctx.expect(KeyCombo(notation: "⌘↑")?.key == CGKeyCode(kVK_UpArrow), "⌘↑")
                // The recorder keeps Shift's character: ⇧⌘! is ⇧⌘1.
                let bang = KeyCombo(notation: "⇧⌘!")
                try ctx.expect(bang?.key == KeyCombo.character("1")?.key && bang?.modifiers.contains(.maskShift) == true, "⇧⌘!")
            },
            SelfTest.Case("keys.eventsCarryModifiers") { ctx in
                let events = KeySender.events(for: KeyCombo(kVK_ANSI_C, [.maskCommand, .maskShift]))
                // Command down, Shift down, C down, C up, Shift up, Command up.
                try ctx.expect(events.count == 6, "\(events.count) events")
                let key = events[2]
                try ctx.expect(key.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_C), "key code")
                try ctx.expect(key.flags.contains(.maskCommand) && key.flags.contains(.maskShift), "key flags \(key.flags)")
                try ctx.expect(events.last?.flags.intersection([.maskCommand, .maskShift]) == [], "all modifiers up at the end")
            },
            SelfTest.Case("keys.mediaKeyEvents") { ctx in
                let events = KeySender.events(for: .play)
                try ctx.expect(events.count == 2, "two events")
                let down = NSEvent(cgEvent: events[0])
                try ctx.expect(down?.type == .systemDefined && down?.subtype.rawValue == 8, "system-defined subtype 8")
                try ctx.expect(((down?.data1 ?? 0) >> 16) == KeySender.SpecialKey.play.rawValue, "key type")
                try ctx.expect((((down?.data1 ?? 0) >> 8) & 0xFF) == 0xA, "down state")
            },
            SelfTest.Case("keys.typeIntoWindow") { ctx in
                try KeySender.requireTrust()
                let target = ctx.textTarget
                target.text = ""
                KeySender.target = getpid()
                defer { KeySender.target = nil }
                try KeySender.type("Héllo wörld 👋\nline two")
                try ctx.expect(ctx.wait(upTo: 2, until: { target.text == "Héllo wörld 👋\nline two" }), "typed \(target.text.debugDescription)")
            },
            SelfTest.Case("edit.shortcutsReachTheApp") { ctx in
                try KeySender.requireTrust()
                let target = ctx.textTarget
                KeySender.target = getpid()
                defer { KeySender.target = nil }
                try ctx.preservingClipboard {
                    target.text = "alpha"
                    let board = NSPasteboard.general
                    /// Runs an action, then waits for what it should do, since events take a moment to arrive.
                    func run(_ id: String, step: Int? = nil, until done: () -> Bool, _ what: String) throws {
                        if let step {
                            try ActionBehaviors.behavior(for: id)?.step?(step, .current)
                        } else {
                            try ActionBehaviors.behavior(for: id)?.run?(.current)
                        }
                        try ctx.expect(ctx.wait(upTo: 2, until: done), "\(what) → \(target.text.debugDescription)")
                    }
                    try run("edit.selectAll", until: { target.textView.selectedRange() == NSRange(location: 0, length: 5) }, "select all")
                    try run("edit.copy", until: { board.string(forType: .string) == "alpha" }, "copy")
                    try run("edit.cut", until: { target.text.isEmpty }, "cut")
                    try run("edit.paste", until: { target.text == "alpha" }, "paste")
                    try run("edit.paste", until: { target.text == "alphaalpha" }, "paste again")
                    try run("edit.undo", until: { target.text == "alpha" }, "undo")
                    try run("edit.redo", until: { target.text == "alphaalpha" }, "redo")
                    try run("edit.undo", step: -1, until: { target.text == "alpha" }, "scrolling up undoes")
                    try run("edit.undo", step: 1, until: { target.text == "alphaalpha" }, "scrolling down redoes")
                    try run("edit.pasteMatchStyle", until: { target.text == "alphaalphaalpha" }, "paste as plain text")
                }
            },
            SelfTest.Case("edit.otherShortcutsAreTheStandardOnes") { ctx in
                // These are checked as the events they send, not by running them: each would
                // open a panel or change a document in this process.
                let expected: [(String, Character, CGEventFlags)] = [
                    ("edit.find", "f", .maskCommand), ("edit.save", "s", .maskCommand), ("edit.new", "n", .maskCommand),
                    ("edit.open", "o", .maskCommand), ("edit.print", "p", .maskCommand), ("edit.refresh", "r", .maskCommand),
                    ("edit.newTab", "t", .maskCommand), ("edit.closeTab", "w", .maskCommand),
                    ("edit.reopenTab", "t", [.maskCommand, .maskShift]), ("navigation.back", "[", .maskCommand),
                    ("navigation.forward", "]", .maskCommand),
                ]
                let tap = EventRecorder()
                defer { tap.stop() }
                for (id, character, flags) in expected {
                    tap.events.removeAll()
                    try ActionBehaviors.behavior(for: id)?.run?(.current)
                    let key = tap.events.first { $0.getIntegerValueField(.keyboardEventKeycode) != Int64(kVK_Command) && $0.getIntegerValueField(.keyboardEventKeycode) != Int64(kVK_Shift) }
                    let code = KeyCombo.character(character)?.key
                    try ctx.expect(key?.getIntegerValueField(.keyboardEventKeycode) == Int64(code ?? 999), "\(id) key")
                    try ctx.expect(key?.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == flags, "\(id) flags")
                }
            },
        ]
    }
}

/// Captures what `KeySender` would post, instead of posting it. For checks of actions whose
/// effect would be visible.
final class EventRecorder {
    var events: [CGEvent] = []

    init() {
        KeySender.recorder = { [weak self] in self?.events.append($0) }
    }

    func stop() {
        KeySender.recorder = nil
    }
}
