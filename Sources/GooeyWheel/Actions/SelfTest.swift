import AppKit

/// `GooeyWheel --self-test [pattern]` checks the actions against this Mac and prints one line
/// per check. It is built not to disturb whoever is using the Mac: key presses go to a window
/// of its own that nobody sees, settings are written back to the value they already have, and
/// anything with a visible or lasting effect is checked up to the point where it would act.
enum SelfTest {
    struct Case {
        let name: String
        let run: (Context) throws -> Void

        init(_ name: String, _ run: @escaping (Context) throws -> Void) {
            self.name = name
            self.run = run
        }
    }

    struct Skip: Error { let reason: String }
    struct Failure: Error { let message: String }

    final class Context {
        private(set) var notes: [String] = []

        func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            if !condition { throw Failure(message: message()) }
        }

        func skip(_ reason: String) throws -> Never {
            throw Skip(reason: reason)
        }

        /// Adds a detail to the check's line, such as a value that was read.
        func note(_ text: String) {
            notes.append(text)
        }

        func reset() {
            notes.removeAll()
        }

        /// Lets the app work for a while, so events and notifications arrive.
        func wait(_ seconds: Double) {
            pump(until: Date().addingTimeInterval(seconds))
        }

        /// Hands queued events to the app's windows, as its run loop would.
        private func pump(until date: Date) {
            repeat {
                if let event = NSApp.nextEvent(matching: .any, until: min(date, Date().addingTimeInterval(0.01)), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            } while Date() < date
        }

        /// Runs the run loop until `condition` holds or `timeout` passes. Returns whether it held.
        @discardableResult
        func wait(upTo timeout: Double, until condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { return false }
                pump(until: Date().addingTimeInterval(0.01))
            }
            return true
        }

        /// A text view in a window of this process that nobody sees, holding the keyboard
        /// focus of this process. Key presses sent to this process land in it.
        var textTarget: TextTarget {
            let target = sharedTarget ?? TextTarget()
            sharedTarget = target
            // Another check may have hidden this process or focused a window of its own.
            target.focus()
            return target
        }

        private var sharedTarget: TextTarget?

        /// The general pasteboard's contents, put back after `body` whatever it does, so a test
        /// that copies leaves the user's clipboard as it was.
        func preservingClipboard<T>(_ body: () throws -> T) rethrows -> T {
            let board = NSPasteboard.general
            let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            defer {
                board.clearContents()
                if !saved.isEmpty { board.writeObjects(saved) }
            }
            return try body()
        }
    }

    /// A borderless panel behind the desktop picture with a text view in it. The panel can
    /// hold the keyboard focus without the app becoming active, so tests can type into it.
    final class TextTarget {
        let panel: NSPanel
        let textView: NSTextView

        init() {
            panel = KeyablePanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
            textView = NSTextView(frame: panel.contentLayoutRect)
            textView.isRichText = false
            textView.allowsUndo = true
            panel.contentView = textView
            panel.orderFrontRegardless()
            panel.makeKey()
            panel.makeFirstResponder(textView)
        }

        func focus() {
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            panel.orderFrontRegardless()
            panel.makeKey()
            panel.makeFirstResponder(textView)
        }

        var text: String {
            get { textView.string }
            set {
                textView.string = newValue
                textView.undoManager?.removeAllActions()
            }
        }

        func close() {
            panel.orderOut(nil)
        }

        private final class KeyablePanel: NSPanel {
            override var canBecomeKey: Bool { true }
        }
    }

    static var cases: [Case] {
        catalogTests
            + EditingActions.tests
            + MediaActions.tests
            + AudioActions.tests
            + DisplayActions.tests
            + WindowActions.tests
            + SystemActions.tests
            + AppActions.tests
            + AutomationActions.tests
            + MouseActions.tests
            + MouseButtonTap.tests
            + KeyCapture.tests
    }

    /// Runs every check whose name matches `pattern`, a regular expression. Returns the exit code.
    static func run(pattern: String?) -> Int32 {
        let context = Context()
        var failed = 0
        var passed = 0
        var skipped = 0
        let selected = cases.filter { test in
            pattern.map { test.name.range(of: $0, options: .regularExpression) != nil } ?? true
        }
        installEditMenu()
        print("Running \(selected.count) check(s). Accessibility: \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
        for test in selected {
            context.reset()
            let start = Date()
            var line: String
            do {
                try test.run(context)
                passed += 1
                line = "PASS  \(test.name)"
            } catch let skip as Skip {
                skipped += 1
                line = "SKIP  \(test.name) — \(skip.reason)"
            } catch let failure as Failure {
                failed += 1
                line = "FAIL  \(test.name) — \(failure.message)"
            } catch {
                failed += 1
                line = "FAIL  \(test.name) — threw \(error)"
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if !context.notes.isEmpty { line += "  [\(context.notes.joined(separator: "; "))]" }
            print(line + (ms > 200 ? "  (\(ms) ms)" : ""))
            fflush(stdout)
        }
        print("\(passed) passed, \(failed) failed, \(skipped) skipped")
        return failed == 0 ? 0 : 1
    }

    /// The Edit menu every Mac app has. It is what turns ⌘C and the rest into commands, so
    /// checks of those shortcuts need it here as they would in the app they are sent to.
    private static func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "Z", .command),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "V", [.command, .option]),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (title, action, key, modifiers) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Catalog

    private static var catalogTests: [Case] {
        [
            Case("catalog.everyActionImplemented") { ctx in
                let missing = ActionBehaviors.unimplemented
                try ctx.expect(missing.isEmpty, "no behavior for: \(missing.joined(separator: ", "))")
            },
            Case("catalog.idsUnique") { ctx in
                let ids = ActionCatalog.categories.flatMap(\.actions).map(\.id)
                try ctx.expect(Set(ids).count == ids.count, "duplicate ids")
            },
            Case("catalog.symbolsExist") { ctx in
                var names = ActionCatalog.categories.flatMap(\.actions).flatMap { [$0.symbol] + $0.choices.compactMap(\.symbol) }
                names += ActionCatalog.categories.map(\.symbol)
                let missing = names.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
                try ctx.expect(missing.isEmpty, "missing SF Symbols: \(missing.joined(separator: ", "))")
            },
            Case("catalog.controlsHaveWhatTheyNeed") { ctx in
                var problems: [String] = []
                for action in ActionCatalog.categories.flatMap(\.actions) {
                    guard let behavior = ActionBehaviors.behavior(for: action.id) else { continue }
                    switch action.control {
                    case .toggle?: if behavior.isOn == nil || behavior.run == nil { problems.append("\(action.id) toggle needs isOn and run") }
                    case .slider?: if behavior.level == nil { problems.append("\(action.id) slider needs level") }
                    case .stepper?: if behavior.step == nil || behavior.run == nil { problems.append("\(action.id) stepper needs step and run") }
                    case .picker?: if behavior.choices == nil || behavior.choose == nil { problems.append("\(action.id) picker needs choices and choose") }
                    case .readout?: if behavior.liveDetail == nil { problems.append("\(action.id) readout needs liveDetail") }
                    case nil: if behavior.run == nil { problems.append("\(action.id) needs run") }
                    }
                }
                try ctx.expect(problems.isEmpty, problems.joined(separator: "; "))
            },
            Case("catalog.migration") { ctx in
                let old = WheelItem.action("desktop.leftHalf")
                let migrated = ActionMigration.migrate(old)
                try ctx.expect(migrated.actionID == "window.move" && migrated.argument == "leftHalf", "desktop.leftHalf → \(String(describing: migrated.actionID)) \(String(describing: migrated.argument))")
                try ctx.expect(migrated.title == "Left Half", "title \(migrated.title)")
                let gone = ActionMigration.migrate(WheelItem.action("navigation.scrollUp"))
                try ctx.expect(gone.actionID == nil && gone.title == "Scroll Up", "retired action keeps its name, got \(gone.title)")
                for item in WheelItem.defaults.flatMap({ [$0] + ($0.children ?? []) }) {
                    if let id = item.actionID { try ctx.expect(ActionCatalog.action(id) != nil, "layout uses unknown \(id)") }
                }
            },
        ]
    }
}
