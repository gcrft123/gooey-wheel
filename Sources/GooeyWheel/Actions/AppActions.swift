import AppKit
import Carbon.HIToolbox

/// App and file actions: opening and quitting apps, opening files, folders, and links,
/// Finder's windows and its commands on the selection, and ejecting disks.
enum AppActions {
    static let behaviors: [String: ActionBehavior] = {
        var map = shared
        #if !APPSTORE
        map["apps.quit"] = ActionBehavior { invocation in
            try quitApp(try required(invocation, "No app is chosen"))
        }
        #endif
        return map
    }()

    private static let shared: [String: ActionBehavior] = [
        "apps.open": ActionBehavior { invocation in
            try openApp(try required(invocation, "No app is chosen"))
        },
        "apps.openFile": ActionBehavior { invocation in
            try openItem(invocation.argument, inFinder: false)
        },
        "apps.openFolder": ActionBehavior { invocation in
            try openItem(invocation.argument, inFinder: true)
        },
        "apps.openWebsite": ActionBehavior { invocation in
            try openLink(try required(invocation, "No link is set"))
        },
        "apps.airdrop": ActionBehavior { _ in
            try openFinderStub(airDrop)
        },
        "apps.newFinderWindow": ActionBehavior { _ in
            newFinderWindow()
        },
        "apps.recents": ActionBehavior { _ in
            try openFinderStub(recents)
        },
        "apps.quickLook": finderCommand { KeyCombo.character("y", .maskCommand) ?? KeyCombo(kVK_ANSI_Y, .maskCommand) },
        "apps.getInfo": finderCommand { KeyCombo.character("i", .maskCommand) ?? KeyCombo(kVK_ANSI_I, .maskCommand) },
        "apps.moveToTrash": finderCommand { KeyCombo(kVK_Delete, .maskCommand) },
        "apps.ejectAll": ActionBehavior { _ in
            DispatchQueue.global(qos: .userInitiated).async { ejectAll() }
        },
    ]

    private static func required(_ invocation: ActionInvocation, _ message: String) throws -> String {
        guard let argument = invocation.argument?.trimmingCharacters(in: .whitespacesAndNewlines), !argument.isEmpty else {
            throw ActionError.failed(message)
        }
        return argument
    }

    /// Logs a failure that arrives after the action has returned, and says so in a toast.
    private static func report(_ what: String, _ error: Error) {
        NSLog("Gooey Wheel: %@ failed, %@", what, "\(error)")
        ActionFeedback.failed("\(what) didn't work")
    }

    // MARK: Apps

    /// Where an app is: the copy that is running, else the one Launch Services picks.
    static func appURL(_ bundleID: String) -> URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Opens an app, or brings it to the front if it is running. Like clicking its Dock icon,
    /// that unhides it and, if it has no windows, asks it to open one.
    static func openApp(_ bundleID: String, activates: Bool = true) throws {
        guard let url = appURL(bundleID) else { throw ActionError.failed("No app with the id \(bundleID) is installed") }
        if activates {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where app.isHidden {
                app.unhide()
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.hides = !activates
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { report("Opening \(AppIndex.shared.app(bundleID)?.name ?? bundleID)", error) }
        }
    }

    #if !APPSTORE
    /// Asks every running copy of an app to quit, as its Quit menu item would. It may ask to
    /// save documents first. Never forced.
    static func quitApp(_ bundleID: String) throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        let refused = running.filter { !$0.terminate() }
        if !running.isEmpty, refused.count == running.count {
            throw ActionError.failed("\(running[0].localizedName ?? bundleID) didn't take the request to quit")
        }
    }
    #endif

    // MARK: Files and links

    /// The file or folder at a stored path, which may start with ~.
    static func existingItem(_ argument: String?) throws -> URL {
        guard let location = ItemLocation(argument: argument) else {
            throw ActionError.failed("No file or folder is chosen")
        }
        guard FileManager.default.fileExists(atPath: location.url.path) else {
            throw ActionError.failed("Nothing is at \(location.path) any more")
        }
        return location.url
    }

    /// Opens an item's file or folder. In the App Store edition the item's bookmark grants
    /// access to it for as long as the opening takes.
    private static func openItem(_ argument: String?, inFinder: Bool) throws {
        #if APPSTORE
        guard let location = ItemLocation(argument: argument) else { throw ActionError.failed("No file or folder is chosen") }
        guard let url = location.startAccess() else {
            throw ActionError.failed("Choose \((location.path as NSString).lastPathComponent) again in the item's action")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            throw ActionError.failed("Nothing is at \(location.path) any more")
        }
        let done = { url.stopAccessingSecurityScopedResource() }
        #else
        let url = try existingItem(argument)
        let done = {}
        #endif
        if inFinder { openInFinder(url, then: done) } else { open(url, then: done) }
    }

    /// Opens a file in its default app, or a folder in Finder.
    private static func open(_ url: URL, then done: @escaping () -> Void = {}) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            done()
            if let error { report("Opening \(url.path)", error) }
        }
    }

    /// Opens a folder in a Finder window. A file or a package such as an app is shown
    /// selected in its folder instead, since opening it would launch it.
    private static func openInFinder(_ url: URL, then done: @escaping () -> Void) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true {
            open(url, then: done)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            done()
        }
    }

    /// The link a user typed, as a URL. Any scheme works, such as mailto: or obsidian://. A
    /// bare address such as example.com gets https://, or http:// for this Mac. Nil if it
    /// can't be a link.
    static func normalizedLink(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = trimmed[..<colon]
            let rest = trimmed[trimmed.index(after: colon)...]
            // "example.com:8080" and "localhost:3000" are an address with a port, not a scheme.
            let port = rest.prefix { $0 != "/" }
            let isPort = (scheme.contains(".") || scheme.lowercased() == "localhost") && !port.isEmpty && port.allSatisfy(\.isNumber)
            if !isPort, scheme.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil {
                guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
                if ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty ?? true { return nil }
                return url
            }
        }
        let host = trimmed.prefix { !"/:?#".contains($0) }.lowercased()
        let local = ["localhost", "127.0.0.1", "[::1]"].contains(host)
        guard local || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")) else { return nil }
        guard let url = URL(string: (local ? "http://" : "https://") + trimmed), url.host?.isEmpty == false else { return nil }
        return url
    }

    static func openLink(_ text: String) throws {
        guard let url = normalizedLink(text) else { throw ActionError.failed("\(text) isn't a link") }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            throw ActionError.failed("No app opens \(url.scheme ?? "these") links")
        }
        open(url)
    }

    // MARK: Finder

    /// Small apps inside Finder that each open one of its windows, as its Go menu does.
    static let airDrop = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
    static let recents = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/Recents.app")

    private static func openFinderStub(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ActionError.unavailable("Finder's \(url.deletingPathExtension().lastPathComponent) window")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { report("Opening \(url.lastPathComponent)", error) }
        }
    }

    #if APPSTORE
    /// Brings Finder forward and sends it ⌘N, which opens a window where Finder's settings say.
    private static func newFinderWindow() {
        do {
            try FinderCommand.send(KeyCombo.character("n", .maskCommand) ?? KeyCombo(kVK_ANSI_N, .maskCommand))
        } catch {
            ActionFeedback.failed(ActionRunner.message(for: error))
        }
    }
    #else
    /// Makes Finder open a new window on the home folder and come forward. The first time,
    /// macOS asks whether Gooey Wheel may control Finder. Without that, the home folder is
    /// opened instead, which brings forward a window already showing it.
    static let newFinderWindowScript = """
        tell application "Finder"
            make new Finder window to home
            activate
        end tell
        """

    private static func newFinderWindow() {
        AutomationActions.appleScript(newFinderWindowScript).start { result in
            if case .success(let result) = result, result.succeeded { return }
            DispatchQueue.main.async { open(URL(fileURLWithPath: UserHome.path)) }
        }
    }
    #endif

    static let finderID = "com.apple.finder"

    /// One of Finder's own commands on the selection, sent as its shortcut. Only while Finder
    /// is in front, so it never reaches another app, where the same keys mean something else.
    private static func finderCommand(_ combo: @escaping () -> KeyCombo) -> ActionBehavior {
        ActionBehavior { invocation in
            guard invocation.frontmost?.bundleIdentifier == finderID else {
                throw ActionError.unavailable("Works on Finder's selection")
            }
            try KeySender.post(combo())
        }
    }

    // MARK: Disks

    struct Volume {
        let url: URL
        let name: String
        var isRoot = false
        var isBrowsable = true
        var isEjectable = false
        var isRemovable = false
        /// Nil for volumes that aren't on a device, such as network shares.
        var isInternal: Bool? = true
        var isLocal = true
    }

    static func mountedVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Volume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isRoot: values.volumeIsRootFileSystem ?? false,
                isBrowsable: values.volumeIsBrowsable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isInternal: values.volumeIsInternal,
                isLocal: values.volumeIsLocal ?? true
            )
        }
    }

    /// The volumes Finder shows an eject button for: disks, card readers, disk images, and
    /// network shares. Never the startup disk or the system's own volumes.
    static func ejectCandidates(_ volumes: [Volume]) -> [Volume] {
        volumes.filter { volume in
            guard !volume.isRoot, volume.isBrowsable, !volume.url.path.hasPrefix("/System/Volumes/") else { return false }
            return volume.isEjectable || volume.isRemovable || volume.isInternal == false || !volume.isLocal
        }
    }

    /// Unmounts and ejects every candidate, one at a time. Blocks, so runs off the main thread.
    /// A disk in use stays; it is logged, and if nothing could be ejected the Mac beeps.
    private static func ejectAll() {
        let candidates = ejectCandidates(mountedVolumes())
        var ejected = 0
        for volume in candidates {
            // Ejecting a disk takes all its volumes, so a later one may be gone already.
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?
                .contains { $0.standardizedFileURL == volume.url.standardizedFileURL } ?? false
            guard mounted else {
                ejected += 1
                continue
            }
            let finished = DispatchSemaphore(value: 0)
            var failure: Error?
            FileManager.default.unmountVolume(at: volume.url, options: [.allPartitionsAndEjectDisk, .withoutUI]) { error in
                failure = error
                finished.signal()
            }
            finished.wait()
            if let failure {
                NSLog("Gooey Wheel: couldn't eject %@: %@", volume.name, failure.localizedDescription)
            } else {
                ejected += 1
            }
        }
        let busy = candidates.count - ejected
        if candidates.isEmpty {
            ActionFeedback.confirm("No disks to eject", symbol: "eject")
        } else if busy == 0 {
            ActionFeedback.confirm(ejected == 1 ? "Ejected \(candidates[0].name)" : "Ejected \(ejected) disks", symbol: "eject.fill")
        } else {
            NSLog("Gooey Wheel: Eject All Disks left %d disk(s) in use", busy)
            ActionFeedback.failed(busy == 1 ? "A disk is in use and stayed" : "\(busy) disks are in use and stayed")
        }
    }

    #if APPSTORE
    private static let quitTests: [SelfTest.Case] = []
    #else
    private static var quitTests: [SelfTest.Case] {
        [SelfTest.Case("apps.openAndQuitAnApp") { ctx in
            // A stay-open AppleScript applet with no Dock icon or windows, made for the check,
            // opened in the background (the action itself also brings it to the front),
            // then quit by the action.
            let id = "dev.gooey.wheel.selftest.\(UUID().uuidString.prefix(8))"
            // Launch Services doesn't look up apps by id in the temporary folder.
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let folder = caches.appendingPathComponent("dev.gooey.wheel.selftest-\(UUID().uuidString)")
            let app = folder.appendingPathComponent("Quit Probe.app")
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            defer {
                _ = try? ChildProcess(executable: lsregister, arguments: ["-u", app.path], timeout: 10).run()
                try? FileManager.default.removeItem(at: folder)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let plist = app.appendingPathComponent("Contents/Info.plist").path
            for step in [
                ChildProcess(executable: "/usr/bin/osacompile", arguments: ["-s", "-o", app.path, "-e", "on idle\nreturn 60\nend idle"]),
                ChildProcess(executable: "/usr/libexec/PlistBuddy", arguments: ["-c", "Add :CFBundleIdentifier string \(id)", "-c", "Add :LSUIElement bool true", plist]),
                ChildProcess(executable: "/usr/bin/codesign", arguments: ["-s", "-", "--force", app.path]),
                ChildProcess(executable: lsregister, arguments: ["-f", app.path]),
            ] {
                var step = step
                step.timeout = 30
                let result = try step.run()
                if !result.succeeded { try ctx.skip("\((step.executable as NSString).lastPathComponent) failed: \(result.errorTail())") }
            }
            try ctx.expect(ctx.wait(upTo: 5, until: { appURL(id) != nil }), "Launch Services doesn't know \(id)")
            try openApp(id, activates: false)
            try ctx.expect(ctx.wait(upTo: 10, until: { NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.isFinishedLaunching == true }), "didn't open")
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            try ActionBehaviors.behavior(for: "apps.quit")?.run?(.current.with(argument: id))
            try ctx.expect(ctx.wait(upTo: 10, until: { running.allSatisfy(\.isTerminated) }), "didn't quit")
        }]
    }
    #endif

    // MARK: Checks

    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("apps.findsAppsByBundleID") { ctx in
                let safari = appURL("com.apple.Safari")
                ctx.note(safari?.path ?? "nil")
                try ctx.expect(safari?.pathExtension == "app", "com.apple.Safari didn't resolve")
                var threw = false
                do { try ActionBehaviors.behavior(for: "apps.open")?.run?(.current.with(argument: "dev.gooey.no-such-app")) } catch { threw = true }
                try ctx.expect(threw, "opening an app that isn't installed should fail")
                // Asking an app that isn't running to quit is nothing to do.
                #if !APPSTORE
                try ActionBehaviors.behavior(for: "apps.quit")?.run?(.current.with(argument: "dev.gooey.no-such-app"))
                #endif
            },
        ] + quitTests + [
            SelfTest.Case("apps.pathsExpandAndMustExist") { ctx in
                let home = try existingItem("~")
                try ctx.expect(home.path == UserHome.path, "~ → \(home.path)")
                try ctx.expect(try existingItem("  ~/  ").path.hasPrefix(UserHome.path), "spaces around a path")
                for id in ["apps.openFile", "apps.openFolder"] {
                    for argument in [nil, "", "~/Gooey Wheel self-test \(UUID().uuidString).txt"] {
                        var message = ""
                        do {
                            try ActionBehaviors.behavior(for: id)?.run?(.current.with(argument: argument))
                        } catch ActionError.failed(let why) {
                            message = why
                        }
                        try ctx.expect(!message.isEmpty, "\(id) with \(argument ?? "nil") should fail")
                        if let argument, !argument.isEmpty { try ctx.expect(message.contains((argument as NSString).lastPathComponent), "message \(message)") }
                    }
                }
            },
            SelfTest.Case("apps.locationArguments") { ctx in
                let plain = ItemLocation(argument: " ~/Downloads ")
                try ctx.expect(plain == ItemLocation(path: "~/Downloads") && plain?.argument == "~/Downloads", "a path alone → \(String(describing: plain))")
                let marked = ItemLocation(path: "~/Notes.txt", bookmark: Data([1, 2, 3]))
                try ctx.expect(ItemLocation(argument: marked.argument) == marked, "with a bookmark → \(marked.argument.debugDescription)")
                try ctx.expect(ItemLocation.path(of: marked.argument) == "~/Notes.txt", "the path line")
                try ctx.expect(ItemLocation(argument: "") == nil && ItemLocation(argument: "\nAQID") == nil, "no path")
                try ctx.expect(UserHome.expand("~/Desktop") == UserHome.path + "/Desktop" && UserHome.abbreviate(UserHome.path + "/Desktop") == "~/Desktop", "~")
                try ctx.expect(UserHome.expand("/tmp/~") == "/tmp/~" && UserHome.abbreviate("/Users") == "/Users", "paths outside home")
                ctx.note("home \(UserHome.path)")
                #if APPSTORE
                // A file the app may write, bookmarked as a chosen file would be.
                let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Gooey Wheel self-test \(UUID().uuidString).txt")
                try Data("x".utf8).write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                let chosen = ItemLocation(chosen: file)
                try ctx.expect(chosen.bookmark != nil, "no security-scoped bookmark for \(file.path)")
                guard let reached = ItemLocation(argument: chosen.argument)?.startAccess() else { throw SelfTest.Failure(message: "the bookmark didn't resolve") }
                defer { reached.stopAccessingSecurityScopedResource() }
                try ctx.expect(reached.standardizedFileURL.path == file.standardizedFileURL.path, "resolved to \(reached.path)")
                #endif
            },
            SelfTest.Case("apps.ejectOneProbe") { ctx in
                // Unmounts a disk image made for the check, never the user's disks:
                // GOOEY_EJECT_PROBE names its mount point.
                guard let path = ProcessInfo.processInfo.environment["GOOEY_EJECT_PROBE"] else {
                    try ctx.skip("set GOOEY_EJECT_PROBE to a disk image's mount point to check ejecting")
                }
                let url = URL(fileURLWithPath: path)
                let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
                try ctx.expect(mounted.contains { $0.standardizedFileURL == url.standardizedFileURL }, "nothing is mounted at \(path)")
                var failure: Error?
                var finished = false
                FileManager.default.unmountVolume(at: url, options: [.allPartitionsAndEjectDisk, .withoutUI]) { error in
                    failure = error
                    finished = true
                }
                try ctx.expect(ctx.wait(upTo: 20, until: { finished }), "no answer in 20 s")
                try ctx.expect(failure == nil, "refused: \(failure?.localizedDescription ?? "")")
            },
            SelfTest.Case("apps.linksAreNormalized") { ctx in
                let cases: [(String, String?)] = [
                    ("example.com", "https://example.com"),
                    ("  example.com/path?q=1  ", "https://example.com/path?q=1"),
                    ("http://example.com", "http://example.com"),
                    ("HTTPS://Example.com", "HTTPS://Example.com"),
                    ("example.com:8080/x", "https://example.com:8080/x"),
                    ("localhost:3000", "http://localhost:3000"),
                    ("mailto:someone@example.com", "mailto:someone@example.com"),
                    ("obsidian://open?vault=Notes", "obsidian://open?vault=Notes"),
                    ("x-apple.systempreferences:com.apple.preference.security?Privacy", "x-apple.systempreferences:com.apple.preference.security?Privacy"),
                    ("tel:+15555550123", "tel:+15555550123"),
                    ("tel:5555550123", "tel:5555550123"),
                    ("", nil), ("   ", nil), ("not a link", nil), ("hello", nil), ("https://", nil), ("https:///path", nil), (".com", nil),
                ]
                for (input, expected) in cases {
                    let got = normalizedLink(input)?.absoluteString
                    try ctx.expect(got == expected, "\(input.debugDescription) → \(got ?? "nil"), expected \(expected ?? "nil")")
                }
            },
            SelfTest.Case("apps.linksHaveAnApp") { ctx in
                for link in ["example.com", "mailto:someone@example.com", "x-apple.systempreferences:com.apple.preference.security"] {
                    let url = normalizedLink(link)
                    try ctx.expect(url.flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) != nil, "nothing opens \(link)")
                }
                ctx.note("https → \(normalizedLink("example.com").flatMap(NSWorkspace.shared.urlForApplication(toOpen:))?.lastPathComponent ?? "nil")")
                var message = ""
                do { try openLink("gooey-no-such-scheme-\(UUID().uuidString.prefix(6)):thing") } catch ActionError.failed(let why) { message = why }
                try ctx.expect(message.contains("No app opens"), "unhandled scheme gave \(message.debugDescription)")
                message = ""
                do { try openLink("not a link") } catch ActionError.failed(let why) { message = why }
                try ctx.expect(message.contains("isn't a link"), "bad link gave \(message.debugDescription)")
            },
            SelfTest.Case("apps.finderWindowsExist") { ctx in
                // Checked up to opening them: each would put a Finder window on the screen.
                for url in [airDrop, recents] {
                    let bundle = Bundle(url: url)
                    try ctx.expect(bundle?.bundleIdentifier != nil && bundle?.executableURL != nil, "\(url.path) isn't an app")
                    ctx.note("\(url.deletingPathExtension().lastPathComponent): \(bundle?.bundleIdentifier ?? "nil")")
                }
                #if APPSTORE
                // Recorded, not sent.
                guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first else { try ctx.skip("Finder isn't running") }
                try KeySender.requireTrust()
                let tap = EventRecorder()
                defer { tap.stop() }
                try FinderCommand.send(KeyCombo.character("n", .maskCommand) ?? KeyCombo(kVK_ANSI_N, .maskCommand), activating: false)
                try ctx.expect(ctx.wait(upTo: 1, until: { !tap.events.isEmpty }), "New Finder Window sent nothing")
                try ctx.expect(tap.targets.allSatisfy { $0 == finder.processIdentifier }, "sent to \(tap.targets), not Finder")
                #else
                var error: NSDictionary?
                let script = NSAppleScript(source: newFinderWindowScript)
                try ctx.expect(script?.compileAndReturnError(&error) == true, "new window script: \(String(describing: error))")
                #endif
            },
            SelfTest.Case("apps.finderCommandsNeedFinderInFront") { ctx in
                let tap = EventRecorder()
                defer { tap.stop() }
                let other = NSRunningApplication.current
                for id in ["apps.quickLook", "apps.getInfo", "apps.moveToTrash"] {
                    var message = ""
                    do {
                        try ActionBehaviors.behavior(for: id)?.run?(ActionInvocation(argument: nil, frontmost: other))
                    } catch ActionError.unavailable(let why) {
                        message = why
                    }
                    try ctx.expect(message == "Works on Finder's selection", "\(id) with another app in front: \(message.debugDescription)")
                    try ctx.expect(tap.events.isEmpty, "\(id) sent keys with another app in front")
                }
            },
            SelfTest.Case("apps.finderCommandsSendFindersShortcuts") { ctx in
                // Recorded, not sent: they would act on whatever is selected in Finder.
                guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first else {
                    try ctx.skip("Finder isn't running")
                }
                let tap = EventRecorder()
                defer { tap.stop() }
                let expected: [(String, Int)] = [
                    ("apps.quickLook", Int(KeyCombo.character("y")?.key ?? CGKeyCode(kVK_ANSI_Y))),
                    ("apps.getInfo", Int(KeyCombo.character("i")?.key ?? CGKeyCode(kVK_ANSI_I))),
                    ("apps.moveToTrash", kVK_Delete),
                ]
                for (id, code) in expected {
                    tap.events.removeAll()
                    do {
                        try ActionBehaviors.behavior(for: id)?.run?(ActionInvocation(argument: nil, frontmost: finder))
                    } catch ActionError.needsAccessibility {
                        try ctx.skip("Accessibility not granted")
                    }
                    let key = tap.events.first { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(code) }
                    try ctx.expect(key != nil, "\(id) didn't send key \(code)")
                    try ctx.expect(key?.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand, "\(id) flags")
                }
            },
            SelfTest.Case("apps.ejectCandidates") { ctx in
                // Lists what Eject All Disks would eject on this Mac, without ejecting anything.
                let mounted = mountedVolumes()
                let candidates = ejectCandidates(mounted)
                ctx.note("would eject: " + (candidates.isEmpty ? "nothing" : candidates.map(\.name).joined(separator: ", ")))
                try ctx.expect(mounted.contains { $0.isRoot }, "the startup disk isn't listed")
                try ctx.expect(!candidates.contains { $0.isRoot || $0.url.path == "/" }, "the startup disk is a candidate")
                func volume(_ path: String, _ change: (inout Volume) -> Void = { _ in }) -> Volume {
                    var volume = Volume(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent)
                    change(&volume)
                    return volume
                }
                let made = [
                    volume("/") { $0.isRoot = true },
                    volume("/System/Volumes/Data") { $0.isInternal = true },
                    volume("/System/Volumes/Preboot") { $0.isBrowsable = false },
                    volume("/Volumes/Internal Data"),
                    volume("/Volumes/USB Stick") { $0.isEjectable = true; $0.isRemovable = true },
                    volume("/Volumes/SD Card") { $0.isRemovable = true },
                    volume("/Volumes/External SSD") { $0.isInternal = false },
                    volume("/Volumes/Share") { $0.isLocal = false; $0.isInternal = nil },
                    volume("/Volumes/Hidden Image") { $0.isEjectable = true; $0.isBrowsable = false },
                ]
                let names = ejectCandidates(made).map(\.name)
                try ctx.expect(names == ["USB Stick", "SD Card", "External SSD", "Share"], "chose \(names)")
            },
        ]
    }
}

#if APPSTORE
/// One of Finder's own commands, sent as its shortcut to Finder alone, so the keys never reach
/// another app where they mean something else. Finder comes forward first, so the user sees
/// what the command does, such as the question Empty Trash… asks.
enum FinderCommand {
    static func send(_ combo: KeyCombo, activating: Bool = true) throws {
        try KeySender.requireTrust()
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: AppActions.finderID).first else {
            throw ActionError.unavailable("Finder isn't running")
        }
        if activating { AppSwitching.activate(finder) }
        KeySender.whenModifiersReleased {
            KeySender.post(KeySender.events(for: combo), to: finder.processIdentifier)
        }
    }
}
#endif
