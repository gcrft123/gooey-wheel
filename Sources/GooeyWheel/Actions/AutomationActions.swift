import AppKit
import Carbon.HIToolbox

/// Automation actions: key presses and text sent to the app in front, the clipboard, and
/// shortcuts, shell commands, and AppleScripts run in the background.
enum AutomationActions {
    static let behaviors: [String: ActionBehavior] = [
        "automation.keystroke": ActionBehavior { invocation in
            try KeySender.post(notation: try required(invocation, "No keyboard shortcut is set"))
        },
        "automation.typeText": ActionBehavior { invocation in
            try insert(try required(invocation, "No text is set"))
        },
        "automation.copyText": ActionBehavior { invocation in
            copy(try required(invocation, "No text is set"))
            ActionFeedback.confirm("Copied to the clipboard", symbol: "doc.on.clipboard")
        },
        "automation.shortcut": ActionBehavior { invocation in
            let name = try required(invocation, "No shortcut is chosen")
            launch(shortcut(name), "“\(name)”")
        },
        "automation.shell": ActionBehavior { invocation in
            launch(shell(try required(invocation, "No command is set")), "The shell command")
        },
        "automation.appleScript": ActionBehavior { invocation in
            launch(appleScript(try required(invocation, "No script is set")), "The AppleScript")
        },
    ]

    private static func required(_ invocation: ActionInvocation, _ message: String) throws -> String {
        guard let argument = invocation.argument, !argument.isEmpty else { throw ActionError.failed(message) }
        return argument
    }

    // MARK: Text

    /// Text longer than this is pasted instead of typed. Typing sends a key press per line
    /// break and per 20 characters, and apps react to each one: editors indent after Return
    /// and close brackets, chat apps send on Return. One paste inserts the text as it is.
    static let pasteThreshold = 200
    /// How long the pasted text stays on the clipboard before what was there comes back.
    /// The app reads the clipboard when it handles ⌘V, which a busy app does late.
    static var clipboardRestoreDelay: TimeInterval = 1

    /// Inserts text at the cursor of the app in front: typed when short, pasted when long.
    static func insert(_ text: String) throws {
        if text.count > pasteThreshold {
            try paste(text)
        } else {
            try KeySender.type(text)
        }
    }

    /// What was on the clipboard before a paste, and the clipboard's change count once the
    /// pasted text was on it. A second paste before the first is put back keeps the first's.
    private static var pendingRestore: (saved: [NSPasteboardItem], ours: Int)?

    /// Pastes text with ⌘V, then puts back what was on the clipboard, unless something else
    /// has been copied in the meantime.
    static func paste(_ text: String) throws {
        try KeySender.requireTrust()
        let board = NSPasteboard.general
        let saved = pendingRestore?.saved ?? snapshot(board)
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Clipboard managers leave alone what is marked transient (nspasteboard.org).
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.writeObjects([item])
        let ours = board.changeCount
        pendingRestore = (saved, ours)
        try KeySender.post(KeyCombo.character("v", .maskCommand) ?? KeyCombo(kVK_ANSI_V, .maskCommand))
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            guard pendingRestore?.ours == ours else { return }
            restoreClipboard()
        }
    }

    /// Puts back what was on the clipboard before the last paste, if nothing has been copied
    /// since. Also called when the app quits, so a quit right after a paste doesn't lose it.
    static func restoreClipboard() {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        let board = NSPasteboard.general
        guard board.changeCount == pending.ours else { return }
        board.clearContents()
        if !pending.saved.isEmpty { board.writeObjects(pending.saved) }
    }

    /// A copy of every item on the clipboard, in every type it offers.
    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    // MARK: Programs

    /// Runs a shortcut from the Shortcuts app by name.
    static func shortcut(_ name: String) -> ChildProcess {
        ChildProcess(executable: "/usr/bin/shortcuts", arguments: ["run", name])
    }

    /// Runs a command in the user's login shell, from their home folder, so the PATH and
    /// variables their profile sets apply as they do in Terminal.
    static func shell(_ command: String, shell: String = loginShell) -> ChildProcess {
        ChildProcess(executable: shell, arguments: ["-l", "-c", command], directory: NSHomeDirectory())
    }

    /// The user's login shell: $SHELL, else the one in their account record, else zsh.
    static var loginShell: String {
        let manager = FileManager.default
        if let shell = ProcessInfo.processInfo.environment["SHELL"], manager.isExecutableFile(atPath: shell) { return shell }
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_shell {
            let shell = String(cString: path)
            if manager.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    /// Runs AppleScript source with osascript. NSAppleScript would have to run on the main
    /// thread, where a slow script would stall the wheel.
    static func appleScript(_ source: String) -> ChildProcess {
        ChildProcess(executable: "/usr/bin/osascript", arguments: ["-e", source])
    }

    /// Starts a program in the background. If it fails, says why in the log and beeps.
    static func launch(_ process: ChildProcess, _ what: String) {
        process.start { result in
            let problem: String?
            switch result {
            case .success(let result) where result.timedOut:
                problem = "stopped after \(Int(process.timeout)) s"
            case .success(let result) where !result.succeeded:
                problem = "exited with \(result.status): \(result.errorTail())"
            case .success:
                problem = nil
            case .failure(let error):
                problem = "\(error)"
            }
            guard let problem else { return }
            NSLog("Gooey Wheel: %@ failed, %@", what, problem)
            ActionFeedback.failed("\(what) didn't work")
        }
    }

    // MARK: Checks

    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("automation.keystrokeSendsTheCombination") { ctx in
                let tap = EventRecorder()
                defer { tap.stop() }
                do {
                    try ActionBehaviors.behavior(for: "automation.keystroke")?.run?(.current.with(argument: "⌃⌥⌘T"))
                } catch ActionError.needsAccessibility {
                    try ctx.skip("Accessibility not granted")
                }
                let key = tap.events.first { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(KeyCombo.character("t")?.key ?? 999) }
                try ctx.expect(key != nil, "no T among \(tap.events.count) events")
                try ctx.expect(key?.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) == [.maskControl, .maskAlternate, .maskCommand], "flags \(String(describing: key?.flags))")
                tap.events.removeAll()
                var threw = false
                do { try ActionBehaviors.behavior(for: "automation.keystroke")?.run?(.current.with(argument: "⌘NoSuchKey")) } catch { threw = true }
                try ctx.expect(threw && tap.events.isEmpty, "an unknown key should fail without sending anything")
            },
            SelfTest.Case("automation.typeTextShort") { ctx in
                try KeySender.requireTrust()
                let target = ctx.textTarget
                target.text = ""
                KeySender.target = getpid()
                defer { KeySender.target = nil }
                let text = "Gooey ✓ wheel\nsecond line"
                try ctx.preservingClipboard {
                    let before = NSPasteboard.general.changeCount
                    try ActionBehaviors.behavior(for: "automation.typeText")?.run?(.current.with(argument: text))
                    try ctx.expect(ctx.wait(upTo: 2, until: { target.text == text }), "typed \(target.text.debugDescription)")
                    try ctx.expect(NSPasteboard.general.changeCount == before, "short text should be typed, not pasted")
                }
            },
            SelfTest.Case("automation.typeTextLongIsPasted") { ctx in
                try KeySender.requireTrust()
                let target = ctx.textTarget
                target.text = ""
                KeySender.target = getpid()
                defer { KeySender.target = nil }
                let text = (1...30).map { "Line \($0): the quick brown fox ({[ ]})" }.joined(separator: "\n")
                try ctx.expect(text.count > pasteThreshold, "test text is short")
                try ctx.preservingClipboard {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString("what the user had copied", forType: .string)
                    try ActionBehaviors.behavior(for: "automation.typeText")?.run?(.current.with(argument: text))
                    try ctx.expect(ctx.wait(upTo: 2, until: { target.text == text }), "pasted \(target.text.prefix(60).debugDescription)…")
                    let restored = ctx.wait(upTo: clipboardRestoreDelay + 1, until: { board.string(forType: .string) == "what the user had copied" })
                    try ctx.expect(restored, "clipboard holds \(board.string(forType: .string)?.prefix(40).debugDescription ?? "nil")")
                }
            },
            SelfTest.Case("automation.pasteLeavesANewerCopyAlone") { ctx in
                try KeySender.requireTrust()
                let target = ctx.textTarget
                target.text = ""
                KeySender.target = getpid()
                defer { KeySender.target = nil }
                try ctx.preservingClipboard {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString("old", forType: .string)
                    try paste("pasted")
                    try ctx.expect(ctx.wait(upTo: 2, until: { target.text == "pasted" }), "pasted \(target.text.debugDescription)")
                    // The user copies something before the old contents come back.
                    copy("newer")
                    ctx.wait(clipboardRestoreDelay + 0.3)
                    try ctx.expect(board.string(forType: .string) == "newer", "clipboard holds \(board.string(forType: .string) ?? "nil")")
                }
            },
            SelfTest.Case("automation.copyText") { ctx in
                try ctx.preservingClipboard {
                    try ActionBehaviors.behavior(for: "automation.copyText")?.run?(.current.with(argument: "Copied by Gooey Wheel ✓"))
                    try ctx.expect(NSPasteboard.general.string(forType: .string) == "Copied by Gooey Wheel ✓", "clipboard holds \(NSPasteboard.general.string(forType: .string) ?? "nil")")
                }
            },
            SelfTest.Case("automation.missingArgumentFails") { ctx in
                for id in ["automation.keystroke", "automation.typeText", "automation.copyText", "automation.shortcut", "automation.shell", "automation.appleScript"] {
                    var threw = false
                    do { try ActionBehaviors.behavior(for: id)?.run?(.current) } catch { threw = true }
                    try ctx.expect(threw, "\(id) ran with nothing set")
                }
            },
            SelfTest.Case("automation.shellRunsInLoginShell") { ctx in
                let process = shell("echo \"$PWD\"; echo out; echo err >&2; exit 3")
                ctx.note(process.executable)
                let result = try process.run()
                let lines = result.output.split(separator: "\n").map(String.init)
                try ctx.expect(lines.suffix(2) == [NSHomeDirectory(), "out"], "output \(result.output.debugDescription)")
                try ctx.expect(result.errorTail(lines: 1) == "err", "stderr \(result.errorOutput.debugDescription)")
                try ctx.expect(result.status == 3 && !result.succeeded, "status \(result.status)")
            },
            SelfTest.Case("automation.shellGetsProfilePATH") { ctx in
                // As when the app is opened from Finder: launchd's short PATH. The login shell
                // runs path_helper and the user's profile, which add to it.
                var process = shell("echo \"$PATH\"")
                process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(), "SHELL": process.executable]
                let result = try process.run()
                let path = result.output.split(separator: "\n").last.map(String.init) ?? ""
                ctx.note(path.split(separator: ":").count.description + " entries")
                try ctx.expect(result.succeeded, "status \(result.status): \(result.errorTail())")
                try ctx.expect(path.split(separator: ":").contains("/usr/local/bin"), "PATH \(path)")
            },
            SelfTest.Case("automation.shellTimeoutStopsEverything") { ctx in
                // The background sleep is in the shell's process group; stopping the group ends it.
                // The limit leaves time for the login shell to read the profile first.
                var process = shell("sleep 30 & echo $!; wait")
                process.timeout = 2
                let start = Date()
                let result = try process.run()
                let elapsed = Date().timeIntervalSince(start)
                try ctx.expect(result.timedOut && !result.succeeded, "timed out \(result.timedOut), status \(result.status)")
                try ctx.expect(elapsed < 4, "took \(elapsed) s")
                guard let pid = result.output.split(separator: "\n").last.flatMap({ pid_t($0) }) else {
                    throw SelfTest.Failure(message: "no pid in \(result.output.debugDescription)")
                }
                ctx.wait(0.1)
                try ctx.expect(kill(pid, 0) == -1 && errno == ESRCH, "sleep \(pid) is still running")
            },
            SelfTest.Case("automation.shellRunsInTheBackground") { ctx in
                let marker = NSTemporaryDirectory() + "GooeyWheel-selftest-\(UUID().uuidString)"
                defer { try? FileManager.default.removeItem(atPath: marker) }
                let start = Date()
                try ActionBehaviors.behavior(for: "automation.shell")?.run?(.current.with(argument: "sleep 0.3; touch '\(marker)'"))
                try ctx.expect(Date().timeIntervalSince(start) < 0.1, "run blocked for \(Date().timeIntervalSince(start)) s")
                try ctx.expect(ctx.wait(upTo: 5, until: { FileManager.default.fileExists(atPath: marker) }), "the command didn't run")
            },
            SelfTest.Case("automation.appleScript") { ctx in
                let result = try appleScript("set x to 1\nreturn x + 1").run()
                try ctx.expect(result.succeeded && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "2", "output \(result.output.debugDescription), status \(result.status): \(result.errorTail())")
                let broken = try appleScript("return 1 +").run()
                ctx.note(broken.errorTail(lines: 1))
                try ctx.expect(!broken.succeeded && broken.errorOutput.contains("-2741"), "syntax error gave status \(broken.status): \(broken.errorOutput)")
            },
            SelfTest.Case("automation.shortcuts") { ctx in
                let list = try ChildProcess(executable: "/usr/bin/shortcuts", arguments: ["list"], timeout: 30).run()
                try ctx.expect(list.succeeded, "shortcuts list: \(list.status) \(list.errorTail())")
                ctx.note("\(list.output.split(separator: "\n").count) shortcuts")
                // A name no one has. Running a real shortcut would do whatever it does.
                var missing = shortcut("Gooey Wheel self-test \(UUID().uuidString)")
                missing.timeout = 30
                let result = try missing.run()
                ctx.note(result.errorTail(lines: 1))
                try ctx.expect(!result.succeeded && !result.timedOut, "a missing shortcut gave status \(result.status), timed out \(result.timedOut)")
            },
        ]
    }
}
