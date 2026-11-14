import AppKit

extension WindowActions {
    /// A titled, resizable window of the self-test process behind the desktop picture, where
    /// nobody sees it. The window actions reach it through Accessibility, the same way they
    /// reach another app's window. Minimizing and full screen are counted instead of done,
    /// since both would show on screen.
    final class ProbeWindow: NSWindow {
        private(set) var miniaturizeRequests = 0
        private(set) var fullScreenRequests = 0

        init(frame: CGRect) {
            super.init(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            collectionBehavior = [.fullScreenPrimary]
            title = "Gooey Wheel self-test"
            setFrame(frame, display: false)
            orderFrontRegardless()
            makeKey()
        }

        override func miniaturize(_ sender: Any?) { miniaturizeRequests += 1 }
        override func toggleFullScreen(_ sender: Any?) { fullScreenRequests += 1 }
    }

    /// Runs `body` with a probe window in the middle of the main screen, as the focused window
    /// of this process, and an invocation that targets this process.
    private static func withProbe(_ ctx: SelfTest.Context, _ body: (ProbeWindow, ActionInvocation, CGRect) throws -> Void) throws {
        guard AXIsProcessTrusted() else { try ctx.skip("Accessibility not granted") }
        guard let screen = NSScreen.main else { try ctx.skip("no screen") }
        let visible = screen.visibleFrame
        let start = CGRect(x: (visible.midX - 300).rounded(), y: (visible.midY - 200).rounded(), width: 600, height: 400)
        let probe = ProbeWindow(frame: start)
        let saved = history
        history = [:]
        defer {
            probe.orderOut(nil)
            history = saved
        }
        ctx.wait(0.05)
        let invocation = ActionInvocation(argument: nil, frontmost: .current)
        let window = try AXWindow.focused(of: .current)
        try ctx.expect(window.key?.window == CGWindowID(probe.windowNumber), "the focused window is the probe")
        try body(probe, invocation, visible)
    }

    private static func run(_ id: String, _ invocation: ActionInvocation, argument: String? = nil) throws {
        guard let run = ActionBehaviors.behavior(for: id)?.run else { throw SelfTest.Failure(message: "no behavior for \(id)") }
        try run(invocation.with(argument: argument))
    }

    private static func describe(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    // MARK: Checks

    static var tests: [SelfTest.Case] {
        [
            SelfTest.Case("window.layoutMath") { ctx in
                // A visible frame off the origin, as on a second display left of the main one.
                let visible = CGRect(x: -1920, y: 40, width: 1920, height: 1015)
                let window = CGRect(x: -1500, y: 300, width: 700, height: 500)
                func frame(_ id: String, step: Int = 0) -> CGRect { WindowGeometry.frame(for: id, window: window, visible: visible, step: step) ?? .null }
                let expected: [String: CGRect] = [
                    "leftHalf": CGRect(x: -1920, y: 40, width: 960, height: 1015),
                    "rightHalf": CGRect(x: -960, y: 40, width: 960, height: 1015),
                    "topHalf": CGRect(x: -1920, y: 548, width: 1920, height: 507),
                    "bottomHalf": CGRect(x: -1920, y: 40, width: 1920, height: 508),
                    "topLeft": CGRect(x: -1920, y: 548, width: 960, height: 507),
                    "topRight": CGRect(x: -960, y: 548, width: 960, height: 507),
                    "bottomLeft": CGRect(x: -1920, y: 40, width: 960, height: 508),
                    "bottomRight": CGRect(x: -960, y: 40, width: 960, height: 508),
                    "leftThird": CGRect(x: -1920, y: 40, width: 640, height: 1015),
                    "centerThird": CGRect(x: -1280, y: 40, width: 640, height: 1015),
                    "rightThird": CGRect(x: -640, y: 40, width: 640, height: 1015),
                    "leftTwoThirds": CGRect(x: -1920, y: 40, width: 1280, height: 1015),
                    "rightTwoThirds": CGRect(x: -1280, y: 40, width: 1280, height: 1015),
                    "maximize": visible,
                    "almostMaximize": CGRect(x: -1824, y: 91, width: 1728, height: 913),
                    "maximizeHeight": CGRect(x: -1500, y: 40, width: 700, height: 1015),
                    "center": CGRect(x: -1310, y: 298, width: 700, height: 500),
                ]
                for choice in WindowLayout.choices where choice.id != "restore" {
                    guard let want = expected[choice.id] else { throw SelfTest.Failure(message: "no expectation for \(choice.id)") }
                    try ctx.expect(frame(choice.id) == want, "\(choice.id) → \(describe(frame(choice.id))), want \(describe(want))")
                }
                try ctx.expect(WindowGeometry.frame(for: "restore", window: window, visible: visible) == nil, "restore needs a record")
                // Neighbors meet exactly, even when the visible frame doesn't divide evenly.
                let odd = CGRect(x: 0, y: 0, width: 1511, height: 945)
                func on(_ id: String) -> CGRect { WindowGeometry.frame(for: id, window: window, visible: odd) ?? .null }
                try ctx.expect(on("leftHalf").maxX == on("rightHalf").minX && on("rightHalf").maxX == odd.maxX, "halves meet")
                try ctx.expect(on("leftThird").maxX == on("centerThird").minX && on("centerThird").maxX == on("rightThird").minX, "thirds meet")
                try ctx.expect(on("bottomHalf").maxY == on("topHalf").minY, "top and bottom meet")
                // Center shrinks a window larger than the screen to fit.
                let big = CGRect(x: 0, y: 0, width: 2500, height: 600)
                let centered = WindowGeometry.frame(for: "center", window: big, visible: visible) ?? .null
                try ctx.expect(centered == CGRect(x: -1920, y: 248, width: 1920, height: 600), "center of a too-wide window → \(describe(centered))")
            },
            SelfTest.Case("window.cycleMath") { ctx in
                let visible = CGRect(x: 0, y: 0, width: 1800, height: 900)
                let window = CGRect(x: 100, y: 100, width: 500, height: 500)
                var record: Record?
                var widths: [CGFloat] = []
                for _ in 0..<4 {
                    guard let plan = plan("leftHalf", window: record?.placed ?? window, visible: visible, record: record) else { break }
                    widths.append(plan.frame.width)
                    record = Record(original: record?.original ?? window, placed: plan.frame, layout: "leftHalf", step: plan.step)
                }
                try ctx.expect(widths == [900, 1200, 600, 900], "left half chosen four times → \(widths)")
                let right = plan("rightHalf", window: CGRect(x: 600, y: 0, width: 1200, height: 900), visible: visible,
                                 record: Record(original: window, placed: CGRect(x: 900, y: 0, width: 900, height: 900), layout: "rightHalf", step: 0))
                try ctx.expect(right?.frame == CGRect(x: 900, y: 0, width: 900, height: 900) && right?.step == 0,
                               "a window moved since starts the cycle over → \(right.map { describe($0.frame) } ?? "nil")")
                let top = plan("topHalf", window: CGRect(x: 0, y: 450, width: 1800, height: 450), visible: visible,
                               record: Record(original: window, placed: CGRect(x: 0, y: 450, width: 1800, height: 450), layout: "topHalf", step: 0))
                try ctx.expect(top?.frame == CGRect(x: 0, y: 300, width: 1800, height: 600), "top half twice → \(top.map { describe($0.frame) } ?? "nil")")
                let restore = plan("restore", window: .zero, visible: visible, record: record)
                try ctx.expect(restore?.frame == window, "restore goes back to the frame before the run of moves")
            },
            SelfTest.Case("window.screenMath") { ctx in
                // A laptop with a larger display above and to its right.
                let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
                let external = CGRect(x: 1000, y: 982, width: 2560, height: 1440)
                let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
                let screens = [laptop, external, left]
                try ctx.expect(WindowGeometry.screenIndex(for: CGRect(x: 1100, y: 700, width: 400, height: 800), among: screens) == 1,
                               "a window mostly on the display above")
                try ctx.expect(WindowGeometry.screenIndex(for: CGRect(x: 100, y: 100, width: 400, height: 300), among: screens) == 0, "a window on the laptop")
                try ctx.expect(WindowGeometry.screenIndex(for: CGRect(x: -5000, y: 100, width: 400, height: 300), among: screens) == 2,
                               "a window off every screen belongs to the nearest")
                try ctx.expect(WindowGeometry.nextScreenIndex(after: 2, among: screens) == 0
                               && WindowGeometry.nextScreenIndex(after: 0, among: screens) == 1
                               && WindowGeometry.nextScreenIndex(after: 1, among: screens) == 2, "next display goes left to right and wraps")
                // The Accessibility API measures from the top of the primary screen.
                let ax = WindowGeometry.flipped(CGRect(x: 1200, y: 1500, width: 800, height: 600), primaryHeight: laptop.height)
                try ctx.expect(ax == CGRect(x: 1200, y: -1118, width: 800, height: 600), "a window on the display above has a negative y → \(describe(ax))")
                try ctx.expect(WindowGeometry.flipped(ax, primaryHeight: laptop.height) == CGRect(x: 1200, y: 1500, width: 800, height: 600), "flipping back")
                // Next Display keeps the window's place relative to the screen.
                let laptopVisible = CGRect(x: 0, y: 0, width: 1512, height: 945)
                let externalVisible = CGRect(x: 1000, y: 982, width: 2560, height: 1415)
                let leftHalf = WindowGeometry.frame(for: "leftHalf", window: .zero, visible: laptopVisible) ?? .null
                let moved = WindowGeometry.moved(leftHalf, from: laptopVisible, to: externalVisible)
                try ctx.expect(moved == WindowGeometry.frame(for: "leftHalf", window: .zero, visible: externalVisible), "a left half stays a left half → \(describe(moved))")
                let small = WindowGeometry.moved(CGRect(x: 1600, y: 1200, width: 2400, height: 1000), from: externalVisible, to: laptopVisible)
                try ctx.expect(laptopVisible.contains(small), "a window moved to a smaller screen fits on it → \(describe(small))")
                let fitted = WindowGeometry.fitted(CGRect(x: 1300, y: -50, width: 400, height: 300), in: laptopVisible)
                try ctx.expect(fitted == CGRect(x: 1112, y: 0, width: 400, height: 300), "a window sticking out is pulled in → \(describe(fitted))")
            },
            SelfTest.Case("window.moveEveryLayout") { ctx in
                try withProbe(ctx) { probe, invocation, visible in
                    for choice in WindowLayout.choices where choice.id != "restore" {
                        let predicted = targetFrame(for: choice.id, invocation: invocation)
                        try run("window.move", invocation, argument: choice.id)
                        ctx.wait(0.02)
                        let actual = probe.frame
                        try ctx.expect(predicted.map { WindowGeometry.same(actual, $0) } == true,
                                       "\(choice.id) → \(describe(actual)), preview said \(predicted.map(describe) ?? "nil")")
                        try ctx.expect(visible.insetBy(dx: -1, dy: -1).contains(actual), "\(choice.id) left the visible frame: \(describe(actual))")
                    }
                    ctx.note("visible \(describe(visible))")
                }
            },
            SelfTest.Case("window.restoreAndCycle") { ctx in
                try withProbe(ctx) { probe, invocation, visible in
                    let start = probe.frame
                    try run("window.move", invocation, argument: "leftHalf")
                    try run("window.move", invocation, argument: "rightHalf")
                    try run("window.move", invocation, argument: "restore")
                    try ctx.expect(WindowGeometry.same(probe.frame, start), "restore → \(describe(probe.frame)), want \(describe(start))")
                    do {
                        try run("window.move", invocation, argument: "restore")
                        throw SelfTest.Failure(message: "a second restore should have nothing to go back to")
                    } catch ActionError.failed {}

                    var widths: [Int] = []
                    for _ in 0..<4 {
                        try run("window.move", invocation, argument: "leftHalf")
                        widths.append(Int(probe.frame.width))
                    }
                    let w = visible.width
                    try ctx.expect(widths == [w / 2, w * 2 / 3, w / 3, w / 2].map { Int($0.rounded()) }, "left half four times → \(widths)")
                    // Moved by hand, the window starts over and Restore goes to where it was put.
                    let byHand = CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 500, height: 300)
                    probe.setFrame(byHand, display: false)
                    try run("window.move", invocation, argument: "leftHalf")
                    try ctx.expect(Int(probe.frame.width) == Int((w / 2).rounded()), "after a move by hand the cycle starts over")
                    try run("window.move", invocation, argument: "restore")
                    try ctx.expect(WindowGeometry.same(probe.frame, byHand), "restore after a move by hand → \(describe(probe.frame))")
                    try run("window.move", invocation, argument: nil)
                    try ctx.expect(WindowGeometry.same(probe.frame, WindowGeometry.frame(for: "leftHalf", window: byHand, visible: visible)!), "no argument means the first layout")
                }
            },
            SelfTest.Case("window.minimumSizeStaysOnScreen") { ctx in
                try withProbe(ctx) { probe, invocation, visible in
                    let minimum = CGSize(width: (visible.width * 0.7).rounded(), height: (visible.height * 0.7).rounded())
                    probe.minSize = minimum
                    for id in ["rightHalf", "bottomRight", "rightThird"] {
                        try run("window.move", invocation, argument: id)
                        let frame = probe.frame
                        try ctx.expect(frame.width >= minimum.width - 1, "\(id): the app kept its minimum width, got \(describe(frame))")
                        try ctx.expect(visible.insetBy(dx: -1, dy: -1).contains(frame), "\(id) → \(describe(frame)) sticks out of \(describe(visible))")
                        try ctx.expect(abs(frame.maxX - visible.maxX) <= 1, "\(id) keeps to the right edge → \(describe(frame))")
                    }
                }
            },
            SelfTest.Case("window.previewIsQuick") { ctx in
                try withProbe(ctx) { _, invocation, _ in
                    let start = Date()
                    for _ in 0..<20 { _ = targetFrame(for: "leftHalf", invocation: invocation) }
                    let own = Date().timeIntervalSince(start) / 20 * 1000
                    ctx.note(String(format: "%.2f ms here", own))
                    // Read-only, on whatever app is in front: the first request sets up the
                    // connection to the app, the rest are what hovering costs.
                    let front = ActionInvocation(argument: nil, frontmost: NSWorkspace.shared.frontmostApplication)
                    var times: [Double] = []
                    var other: CGRect?
                    for _ in 0..<5 {
                        let otherStart = Date()
                        other = targetFrame(for: "leftHalf", invocation: front)
                        times.append(Date().timeIntervalSince(otherStart) * 1000)
                    }
                    ctx.note(String(format: "%.1f ms first, %.1f ms after for %@", times[0], times.dropFirst().min() ?? 0, front.frontmost?.localizedName ?? "?")
                             + (other == nil ? " (no window)" : ""))
                    try ctx.expect(own < 20, "a preview took \(own) ms")
                }
            },
            SelfTest.Case("desktop.minimize") { ctx in
                try withProbe(ctx) { probe, invocation, _ in
                    try run("desktop.minimize", invocation)
                    try ctx.expect(probe.miniaturizeRequests == 1, "the window was asked to minimize \(probe.miniaturizeRequests) times")
                }
            },
            SelfTest.Case("desktop.fullScreen") { ctx in
                try withProbe(ctx) { probe, invocation, _ in
                    try run("desktop.fullScreen", invocation)
                    try ctx.expect(probe.fullScreenRequests == 1, "the window was asked to toggle full screen \(probe.fullScreenRequests) times")
                    let window = try AXWindow.focused(of: .current)
                    ctx.note(window.isSettable("AXFullScreen") ? "set AXFullScreen" : "pressed the full screen button")
                }
            },
            SelfTest.Case("desktop.closeWindow") { ctx in
                try withProbe(ctx) { probe, invocation, _ in
                    try run("desktop.closeWindow", invocation)
                    try ctx.expect(ctx.wait(upTo: 1, until: { !probe.isVisible }), "the window is still open")
                }
            },
            SelfTest.Case("desktop.nextDisplay") { ctx in
                guard NSScreen.screens.count > 1 else { try ctx.skip("one display; the math is checked in window.screenMath") }
                try withProbe(ctx) { probe, invocation, visible in
                    let before = probe.frame
                    try run("desktop.nextDisplay", invocation)
                    let screens = NSScreen.screens
                    let from = WindowGeometry.screenIndex(for: before, among: screens.map(\.frame))!
                    let to = WindowGeometry.nextScreenIndex(after: from, among: screens.map(\.frame))
                    let want = WindowGeometry.moved(before, from: visible, to: screens[to].visibleFrame)
                    try ctx.expect(WindowGeometry.same(probe.frame, want), "→ \(describe(probe.frame)), want \(describe(want))")
                }
            },
            SelfTest.Case("desktop.switchAppsChoosesPreviousApp") { ctx in
                let me: pid_t = 1
                let running = [AppSwitching.App(pid: me, isRegular: false), AppSwitching.App(pid: 10), AppSwitching.App(pid: 20),
                               AppSwitching.App(pid: 30), AppSwitching.App(pid: 40, isRegular: false), AppSwitching.App(pid: 50, isHidden: true)]
                func previous(_ recent: [pid_t], _ windows: [pid_t], front: pid_t?) -> pid_t? {
                    AppSwitching.previousApp(recent: recent, windowOwners: windows, frontmost: front, running: running, exclude: me)
                }
                try ctx.expect(previous([10, 20, 30], [30, 20, 10], front: 10) == 20, "the app active before the one in front")
                try ctx.expect(previous([1, 10, 20], [], front: 10) == 20, "skips the wheel itself")
                try ctx.expect(previous([10, 40, 99, 50], [], front: 10) == 50, "skips agents and apps that quit; a hidden app counts")
                try ctx.expect(previous([10], [40, 10, 30, 20], front: 10) == 30, "falls back to the window order")
                try ctx.expect(previous([], [], front: 10) == nil, "nothing to switch to")
                // What it would do now, without doing it. The history here starts at this
                // check, so this comes from the window order.
                let live = AppSwitching.previousApp(
                    recent: AppHistory.shared.recent, windowOwners: AppSwitching.windowOwnersFrontToBack(),
                    frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, running: AppSwitching.runningApps, exclude: getpid()
                )
                ctx.note("would switch to \(live.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "nothing")")
                // The history follows NSWorkspace's activations, here posted only within this process.
                guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
                let center = NSWorkspace.shared.notificationCenter
                for app in [finder, NSRunningApplication.current] {
                    center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                                userInfo: [NSWorkspace.applicationUserInfoKey: app])
                }
                try ctx.expect(Array(AppHistory.shared.recent.prefix(2)) == [getpid(), finder.processIdentifier],
                               "history after two activations → \(AppHistory.shared.recent.prefix(2))")
            },
            SelfTest.Case("desktop.hideOthersChoosesApps") { ctx in
                let me: pid_t = 1
                let running = [AppSwitching.App(pid: me, isRegular: false), AppSwitching.App(pid: 10), AppSwitching.App(pid: 20),
                               AppSwitching.App(pid: 30, isHidden: true), AppSwitching.App(pid: 40, isRegular: false)]
                let hidden = AppSwitching.appsToHide(running: running, frontmost: 10, exclude: me)
                try ctx.expect(hidden == [20], "hides the other showing regular apps → \(hidden)")
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let live = AppSwitching.appsToHide(running: AppSwitching.runningApps, frontmost: front, exclude: getpid())
                try ctx.expect(!live.contains { $0 == front || $0 == getpid() }, "never the app in front or the wheel")
                ctx.note("would hide \(live.count) app(s)")
            },
            SelfTest.Case("desktop.hideApp") { ctx in
                // Hides this process, whose only windows are behind the desktop picture.
                try run("desktop.hideApp", ActionInvocation(argument: nil, frontmost: .current))
                defer { NSApp.unhideWithoutActivation() }
                try ctx.expect(ctx.wait(upTo: 1, until: { NSApp.isHidden }), "this process wasn't hidden")
            },
            SelfTest.Case("desktop.quitFrontChoosesApp") { ctx in
                try ctx.expect(AppSwitching.appToQuit(frontmost: 10, exclude: 1) == 10, "quits the app in front")
                try ctx.expect(AppSwitching.appToQuit(frontmost: 1, exclude: 1) == nil, "never the wheel")
                do {
                    try run("desktop.quitFront", ActionInvocation(argument: nil, frontmost: .current))
                    throw SelfTest.Failure(message: "the wheel was asked to quit itself")
                } catch ActionError.failed {}
            },
        ]
    }
}
