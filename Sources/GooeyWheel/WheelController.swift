import AppKit
import Carbon.HIToolbox
import QuartzCore
import simd

/// Borderless panel that covers one screen while the wheel is up. It takes clicks without
/// activating the app, so the frontmost app keeps its focus.
final class OverlayPanel: NSPanel {
    /// Set while the wheel is being configured, which needs ⌘Z and, in the editing panels,
    /// typing. A non-activating panel can be key without its app becoming active.
    var allowsKey = false
    /// A demo's panel draws its fields and controls as a key window does, without taking
    /// the keyboard from whoever is using the Mac.
    var actsKey = false

    override var isKeyWindow: Bool { actsKey || super.isKeyWindow }
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

final class OverlayContentView: NSView {
    weak var controller: WheelController?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.pointerDown() }
    override func mouseUp(with event: NSEvent) { controller?.pointerUp() }
    override func rightMouseDown(with event: NSEvent) { controller?.secondaryClick() }
    override func scrollWheel(with event: NSEvent) { controller?.scrolled(event) }

    override func keyDown(with event: NSEvent) {
        // Keys the wheel doesn't use are dropped, so they don't beep.
        _ = controller?.handleKey(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        controller?.handleKey(event) ?? false
    }
}

final class WheelController: NSObject {
    /// Wide enough for the largest editing panel with its shadow.
    static let gooViewSize: CGFloat = 940
    private static let escapeHotKey: UInt32 = 2

    let sim = WheelSim()
    let runner = ActionRunner()
    private let renderer: GooRenderer
    private let panel: OverlayPanel
    private let content = OverlayContentView()
    private let stageView = NSView()
    /// Where the front window would go, shown while a Move Window bubble is hovered.
    private let previewView = NSView()
    private var preview = WindowPreview()
    private let gooView: GooView
    private let hostView = NSView()
    private let layers = WheelLayers()
    private let editors = EditorHost()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var screenFrame = CGRect.zero
    private var scale: CGFloat = 2
    private var style = GooStyle.resolve(dark: true, accent: .controlAccentColor)
    private var gooOrigin = V2(0, 0)

    var timescale = 1.0
    /// Overrides the system's Reduce Motion setting, for demos.
    var reduceMotion: Bool?
    var demo: DemoDriver?
    var stage: String?
    var stageScript = DemoScript.wheel
    /// The line shown under the wheel when it opens at launch.
    var hintText: String {
        get { layers.hintText }
        set {
            layers.hintText = newValue
            sim.hintHalfWidth = layers.hintWidth() / 2 + 14
        }
    }
    var parentStyle: ParentStyle {
        get { sim.parentStyle }
        set { sim.parentStyle = newValue }
    }

    init?(renderer: GooRenderer, store: WheelStore) {
        self.renderer = renderer
        sim.store = store
        gooView = GooView(device: renderer.device)
        panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Tab moves between an editing panel's fields.
        panel.autorecalculatesKeyViewLoop = true

        content.controller = self
        content.wantsLayer = true
        panel.contentView = content

        stageView.wantsLayer = true
        stageView.isHidden = true
        content.addSubview(stageView)
        previewView.wantsLayer = true
        previewView.layer?.addSublayer(preview.layer)
        content.addSubview(previewView)
        content.addSubview(gooView)
        hostView.layer = layers.root
        hostView.wantsLayer = true
        content.addSubview(hostView)
        content.addSubview(editors.view)

        sim.labelWidth = { WheelLayers.labelWidth($0) }
        sim.hintHalfWidth = layers.hintWidth() / 2 + 14
        sim.onHover = { [weak self] in
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self?.tapMouse(.hover)
        }
        sim.onSelect = { [weak self] item in
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            self?.tapMouse(.select)
            // A demo plays the wheel for a recording. It never acts on this Mac.
            guard let self, self.demo == nil else { return }
            self.toastPoint = self.screenPoint(self.sim.hubPosition)
            self.runner.perform(item)
        }
        sim.onChoose = { [weak self] choice, item in
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            self?.tapMouse(.select)
            guard let self, self.demo == nil else { return }
            self.toastPoint = self.screenPoint(self.sim.hubPosition)
            self.runner.choose(choice, of: item)
        }
        sim.onDetent = { [weak self] in
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self?.tapMouse(.step)
        }
        sim.onLimit = { [weak self] in
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            self?.tapMouse(.limit)
        }
        sim.onEnter = { [weak self] in self?.tapMouse(.open) }
        sim.onBack = { [weak self] in self?.tapMouse(.back) }
        // While a request of this app's has the mouse sending its wheel here instead of to
        // Logi Options+, the wheel's turns arrive from the mouse itself.
        MouseWheelEvents.onWheel = { [weak self] vertical, horizontal in
            guard let self, self.demo == nil, self.sim.phase == .open else { return }
            self.updateCursor()
            self.sim.scroll(up: vertical, right: horizontal, precise: false)
        }
        sim.onRefuse = { [weak self] in
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            self?.tapMouse(.refuse)
        }
        sim.controls = runner
        ActionFeedback.show = { [weak self] message in self?.showToast(message) }
        runner.onStateChange = { [weak self] in
            guard let self, self.sim.phase == .open else { return }
            self.sim.refreshLive()
        }
        sim.onEdit = { [weak self] feedback in self?.edited(feedback) }
        sim.onEditorOpen = { [weak self] request in
            guard let self else { return }
            self.editors.open(request, sim: self.sim, style: self.style)
        }
        sim.onEditorSave = { [weak self] in
            guard let self else { return }
            self.editors.commit(joined: self.sim.config.editor?.provisional ?? false)
            self.sim.editorSaved()
        }
        sim.onEditorClose = { [weak self] in self?.editors.close() }
        sim.panelPoint = { [weak self] name in self?.editors.demoPoint(name) }

    }

    // MARK: Coordinates

    /// Screen coordinates (origin bottom-left) to wheel coordinates (origin top-left of the panel).
    private func toSim(_ p: CGPoint) -> V2 {
        V2(Double(p.x - screenFrame.minX), Double(screenFrame.maxY - p.y))
    }

    private func attach(to screen: NSScreen) {
        attach(frame: screen.frame, visible: screen.visibleFrame, scale: screen.backingScaleFactor)
    }

    /// Covers `frame` with the overlay and keeps the wheel inside `visible`.
    private func attach(frame: CGRect, visible: CGRect, scale backing: CGFloat) {
        screenFrame = frame
        scale = backing
        panel.setFrame(screenFrame, display: false)
        hostView.frame = content.bounds
        previewView.frame = content.bounds
        editors.view.frame = content.bounds
        layers.height = content.bounds.height
        layers.scale = scale

        let t = sim.tuning
        let inset = t.ringRadius + t.hoverRadius + 14
        let minX = Double(visible.minX - screenFrame.minX) + inset
        let maxX = Double(visible.maxX - screenFrame.minX) - inset
        let minY = Double(screenFrame.maxY - visible.maxY) + inset
        let maxY = Double(screenFrame.maxY - visible.minY) - inset
        sim.clampCenter = { c in
            V2(min(max(c.x, minX), max(minX, maxX)), min(max(c.y, minY), max(minY, maxY)))
        }
        // A panel keeps its whole outline, and room for its shadow, inside the visible frame.
        let edge = inset - t.ringRadius - t.hoverRadius + 22
        sim.clampPanel = { c, half in
            let low = V2(minX - inset + edge, minY - inset + edge) + half
            let high = V2(maxX + inset - edge, maxY + inset - edge) - half
            return V2(min(max(c.x, low.x), max(low.x, high.x)), min(max(c.y, low.y), max(low.y, high.y)))
        }
    }

    private func positionGooView(force: Bool = false) {
        let size = Double(Self.gooViewSize)
        let origin = V2((sim.viewCenter.x - size / 2).rounded(), (sim.viewCenter.y - size / 2).rounded())
        guard force || origin != gooOrigin else { return }
        gooOrigin = origin
        gooView.frame = CGRect(x: origin.x, y: Double(content.bounds.height) - origin.y - size, width: size, height: size)
        gooView.configure(scale: scale)
    }

    // MARK: Open and close

    var isOpen: Bool { sim.phase == .open }

    /// The wheel's state, for the thumb-button diagnostic's log.
    var debugState: String {
        var parts = ["\(sim.phase)", "\(sim.mode)"]
        if sim.config.active { parts.append(sim.config.editor == nil ? "config" : "editor") }
        if sim.phase != .closed, !panel.isVisible { parts.append("HIDDEN") }
        if sim.phase == .closed, panel.isVisible { parts.append("SHOWN") }
        if sim.phase != .closed, link?.isPaused ?? true { parts.append("NO FRAMES") }
        parts.append("levels=\(sim.levels.count) key=\(panel.isKeyWindow)")
        return "[" + parts.joined(separator: " ") + "]"
    }

    /// Opens at `point` in screen coordinates, or at the cursor when nil.
    func open(at point: CGPoint? = nil, mode: WheelSim.Mode, hint: Bool = false, cursor: V2? = nil) {
        TriggerDebug.log("open mode=\(mode) \(debugState)")
        let mouse = NSEvent.mouseLocation
        let anchor = point ?? mouse
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        // A demo attached itself to its stage when it started.
        if demo == nil, sim.phase == .closed || screen.frame != screenFrame {
            attach(to: screen)
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        style = GooStyle.resolve(dark: dark, accent: .controlAccentColor)
        sim.tuning = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reducedMotion : Tuning()

        if demo == nil {
            runner.wheelOpened()
            optionsPlusRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.optionsPlusAgent).isEmpty
            refreshMouse()
        }
        let center = sim.clampCenter(toSim(anchor))
        sim.open(center: center, cursor: cursor ?? toSim(mouse), mode: mode, hint: hint)
        positionGooView(force: true)
        renderer.invalidate()

        panel.orderFrontRegardless()
        // A demo is driven by its script and leaves Esc to whoever is using the Mac.
        if demo == nil {
            HotKeyCenter.shared.register(id: Self.escapeHotKey, keyCode: kVK_Escape, modifiers: 0) { [weak self] pressed in
                guard pressed, let self else { return }
                TriggerDebug.event("esc \(self.debugState)")
                self.sim.escape()
            }
        }
        startLink()
    }

    func dismiss() {
        TriggerDebug.log("dismiss \(debugState)")
        updateCursor()
        sim.dismiss()
    }

    func triggerReleased(missed: Bool = false) {
        TriggerDebug.log("triggerReleased \(debugState)")
        updateCursor()
        sim.triggerReleased(missed: missed)
    }

    func pointerDown() {
        TriggerDebug.log("wheel click down \(debugState)")
        updateCursor()
        sim.pointerDown()
    }

    func pointerUp() {
        TriggerDebug.log("wheel click up \(debugState)")
        updateCursor()
        sim.pointerUp()
    }

    func secondaryClick() {
        TriggerDebug.log("wheel right-click \(debugState)")
        updateCursor()
        sim.secondaryClick()
    }

    /// A scroll over the wheel adjusts the slider or stepper under the cursor, or an open bar.
    func scrolled(_ event: NSEvent) {
        // A trackpad's coasting after the fingers lift would overshoot. Turns that also arrived
        // from the mouse itself are counted from there.
        guard event.momentumPhase.isEmpty, !MouseWheelEvents.isActive(within: 0.5) else { return }
        let inverted = event.isDirectionInvertedFromDevice
        var dy = Double(event.scrollingDeltaY)
        var dx = Double(event.scrollingDeltaX)
        if inverted {
            dy = -dy
            dx = -dx
        }
        let precise = event.hasPreciseScrollingDeltas
        // A wheel's events are in lines. A fast spin comes as fewer, larger ones.
        let limit = precise ? 400.0 : 4.0
        updateCursor()
        sim.scroll(up: min(max(dy, -limit), limit), right: min(max(-dx, -limit), limit), precise: precise)
    }

    /// ⌘Z and ⇧⌘Z while configuring. Returns whether the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, sim.config.active else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if let text = panel.firstResponder as? NSTextView {
            return editText(text, key: Int(event.keyCode), modifiers: modifiers)
        }
        if let recorder = panel.firstResponder as? KeyRecording {
            recorder.record(event)
            return true
        }
        switch (Int(event.keyCode), modifiers) {
        case (kVK_ANSI_Z, [.command]): sim.undo()
        case (kVK_ANSI_Z, [.command, .shift]): sim.redo()
        case (kVK_Escape, []): sim.escape()
        default: return false
        }
        return true
    }

    /// The app has no Edit menu, so a field's editing shortcuts are sent to it from here.
    /// ⌘Z undoes typing, not the wheel.
    private func editText(_ text: NSTextView, key: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch (key, modifiers) {
        case (kVK_ANSI_Z, [.command]):
            text.undoManager?.undo()
            // Undo doesn't report the change by itself, and the panel has to hear about it.
            text.didChangeText()
        case (kVK_ANSI_Z, [.command, .shift]):
            text.undoManager?.redo()
            text.didChangeText()
        case (kVK_ANSI_X, [.command]): text.cut(nil)
        case (kVK_ANSI_C, [.command]): text.copy(nil)
        case (kVK_ANSI_V, [.command]): text.pasteAsPlainText(nil)
        case (kVK_ANSI_A, [.command]): text.selectAll(nil)
        default: return false
        }
        return true
    }

    func editorDemo(_ step: Int) {
        editors.demo(step)
    }

    // MARK: Demo input

    /// Sends a mouse event through the panel at the demo's cursor, the way the system
    /// delivers a real one: to whichever view is under it. The real pointer isn't touched.
    /// True between a press and a release sent through the window. While it is, the demo's
    /// cursor drags.
    private var demoPressed = false
    private var demoDragged = V2(0, 0)

    func demoMouse(_ type: NSEvent.EventType) {
        if type == .leftMouseDown { demoPressed = true; demoDragged = sim.cursor }
        if type == .leftMouseUp { demoPressed = false }
        let location = CGPoint(x: sim.cursor.x, y: Double(content.bounds.height) - sim.cursor.y)
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        panel.sendEvent(event)
    }

    /// Sends a key press through the panel to whatever has the keyboard focus in it.
    func demoKey(_ characters: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code
            ) else { continue }
            // A key with ⌘ is offered as a shortcut first, as the system does.
            if type == .keyDown, modifiers.contains(.command), content.performKeyEquivalent(with: event) { continue }
            panel.sendEvent(event)
        }
    }

    private func edited(_ feedback: EditFeedback) {
        let haptics = NSHapticFeedbackManager.defaultPerformer
        switch feedback {
        case .entered:
            haptics.perform(.levelChange, performanceTime: .now)
            tapMouse(.select)
            guard demo == nil else { return }
            // Stays key until the wheel closes. Handing key back while the panel is still up
            // would mean ordering it out and in again.
            panel.allowsKey = true
            panel.makeKey()
            panel.makeFirstResponder(content)
            // The pickers' lists take a moment to build. Have them ready before a panel opens.
            DispatchQueue.global(qos: .utility).async {
                _ = SymbolCatalog.all
                _ = AppIndex.shared
            }
        case .exited, .changed, .dropped:
            haptics.perform(.levelChange, performanceTime: .now)
            tapMouse(.select)
        case .lifted:
            haptics.perform(.alignment, performanceTime: .now)
            tapMouse(.open)
        case .refused:
            haptics.perform(.generic, performanceTime: .now)
            tapMouse(.refuse)
        }
    }

    private func updateCursor() {
        if demo == nil {
            sim.cursor = toSim(NSEvent.mouseLocation)
        }
    }

    private func hide() {
        TriggerDebug.log("hide \(debugState)")
        HotKeyCenter.shared.unregister(id: Self.escapeHotKey)
        panel.allowsKey = false
        layers.reset()
        editors.remove()
        guard demo == nil else { return }
        link?.isPaused = true
        panel.orderOut(nil)
        runner.wheelHidden()
    }

    // MARK: Demo stage

    /// Shows the panel with an opaque backdrop and runs the scripted cursor, for recordings.
    func startDemo(_ driver: DemoDriver) {
        guard let screen = NSScreen.main else { return }
        demo = driver
        sim.controls = demoControls
        // The stage sits in the bottom-right corner of the screen, out of the way of whoever
        // is using the Mac while a demo runs. The wheel opens at its center.
        let frame = DemoStage.frame(for: stageScript, on: screen)
        if captureDirectory != nil {
            // A run that only writes images is never seen. Its window is the stage and
            // nothing more, and sits behind the desktop picture.
            attach(frame: frame, visible: frame.insetBy(dx: -200, dy: -200), scale: screen.backingScaleFactor)
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            if stage == nil { stage = "dark" }
        } else {
            attach(to: screen)
        }
        let center = DemoStage.wheelCenter(in: frame, script: stageScript)
        driver.origin = toSim(center)
        driver.anchor = center
        if let stage {
            stageView.frame = frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            let gradient = CAGradientLayer()
            gradient.frame = stageView.bounds
            gradient.cornerRadius = captureDirectory == nil ? DemoStage.cornerRadius : 0
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            switch stage {
            case "light": gradient.colors = [NSColor(white: 0.93, alpha: 1).cgColor, NSColor(white: 0.84, alpha: 1).cgColor]
            case "color": gradient.colors = [NSColor(srgbRed: 0.98, green: 0.55, blue: 0.35, alpha: 1).cgColor, NSColor(srgbRed: 0.45, green: 0.3, blue: 0.85, alpha: 1).cgColor]
            default: gradient.colors = [NSColor(white: 0.2, alpha: 1).cgColor, NSColor(white: 0.11, alpha: 1).cgColor]
            }
            stageView.layer?.addSublayer(gradient)
            stageView.isHidden = false
        }
        layers.enableDemoCursor()
        // The demo is driven by its script. Real clicks go through to whatever is underneath.
        panel.ignoresMouseEvents = true
        panel.actsKey = true
        panel.orderFrontRegardless()
        positionGooView(force: true)
        if captureDirectory != nil { startCapture(driver) } else { startLink() }
    }

    // MARK: Capture

    /// A folder to write images of the demo into without showing it: one per named moment,
    /// or one per frame of a stretch of the script.
    var captureDirectory: String?
    /// Limits the named moments to those matching this pattern.
    var captureFilter: String?
    /// Start and end of a stretch of the script to write frame by frame, and how many per second.
    var captureFrames: (from: Double, to: Double, rate: Double)?
    private var captureQueue: [(name: String, time: Double)] = []
    /// False while the script is fast-forwarded between captures, when nothing needs drawing.
    private var drawsGoo = true

    private func startCapture(_ driver: DemoDriver) {
        driver.holdsAtEnd = true
        if let frames = captureFrames {
            let count = Int(((frames.to - frames.from) * frames.rate).rounded())
            captureQueue = (0...max(count, 0)).map { (String(format: "%04d", $0), frames.from + Double($0) / frames.rate) }
        } else {
            captureQueue = driver.marks.sorted { $0.1 < $1.1 }.filter { mark in
                captureFilter.map { mark.0.range(of: $0, options: .regularExpression) != nil } ?? true
            }
        }
        if let directory = captureDirectory {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        captureNext()
    }

    /// Plays the script as fast as it will go up to the next moment wanted, lets the views
    /// catch up, writes the image, and goes on.
    private func captureNext() {
        guard let demo, let (name, time) = captureQueue.first else {
            NSApp.terminate(nil)
            return
        }
        captureQueue.removeFirst()
        demo.stopAt = time
        drawsGoo = false
        var steps = 0
        while !demo.stopped, !demo.finished, steps < 2_000_000 {
            advance(1.0 / 240)
            steps += 1
        }
        drawsGoo = true
        // Views that load or lay out later get a moment on the run loop first. Frames of a
        // sequence follow each other closely and need less.
        DispatchQueue.main.asyncAfter(deadline: .now() + (captureFrames == nil ? 0.15 : 0.03)) {
            self.advance(0)
            self.writeCapture(named: name)
            self.captureNext()
        }
    }

    /// Has the system capture this window alone, which works whatever is in front of it.
    private func writeCapture(named name: String) {
        guard let directory = captureDirectory else { return }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        CATransaction.flush()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), directory + "/" + name + ".png"]
        do {
            try capture.run()
            capture.waitUntilExit()
        } catch {
            NSLog("Couldn't capture \(name): \(error)")
        }
    }

    // MARK: Frame loop

    private func startLink() {
        // A run that only writes images steps itself, frame by frame.
        guard captureDirectory == nil else { return }
        if link == nil {
            let created = gooView.displayLink(target: self, selector: #selector(tick(_:)))
            created.add(to: .main, forMode: .common)
            link = created
        }
        lastTimestamp = 0
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTimestamp == 0 ? link.duration : now - lastTimestamp
        lastTimestamp = now
        advance(min(max(dt, 1.0 / 480), 1.0 / 20) * timescale)
    }

    /// Moves the wheel on by `dt` and draws it.
    private func advance(_ dt: Double) {
        // A demo run faster than real time takes several steps per frame, so a fast-forwarded
        // script plays out the same way as one at normal speed.
        let wasClosed = sim.phase == .closed
        let steps = demo == nil ? 1 : max(1, Int(timescale.rounded(.up)))
        for _ in 0..<steps {
            if let demo {
                demo.advance(dt / Double(steps), controller: self)
                sim.cursor = demo.cursor
                if demoPressed, simd_distance(sim.cursor, demoDragged) > 0.5 {
                    demoDragged = sim.cursor
                    demoMouse(.leftMouseDragged)
                }
                if demo.stopped, captureDirectory == nil { timescale = 0 }
            } else {
                sim.cursor = toSim(NSEvent.mouseLocation)
            }
            sim.step(timescale == 0 || demo?.stopped == true ? 0 : dt / Double(steps))
        }
        // While a demo holds still for a capture, so does everything drawn on top of the goo.
        let dt = timescale == 0 || demo?.stopped == true ? 0 : dt

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updatePreview(dt)
        positionGooView()
        layers.apply(sim: sim, style: style, demoCursor: demo?.cursor)
        editors.update(sim: sim, dt: dt)
        if drawsGoo {
            renderer.draw(blobs: sim.blobs(), origin: gooOrigin, scale: Double(scale), style: style, in: gooView.metalLayer)
        }
        CATransaction.commit()

        if sim.phase != loggedPhase {
            TriggerDebug.log("phase \(loggedPhase) -> \(sim.phase) \(debugState)")
            loggedPhase = sim.phase
        }
        if sim.phase == .closed, !wasClosed {
            hide()
        }
    }

    /// Shows where the hovered Move Window bubble would put the front window, gliding from one
    /// layout to the next.
    private func updatePreview(_ dt: Double) {
        var target: CGRect?
        if demo == nil, sim.phase == .open, !sim.config.active, let b = sim.hoveredBubble,
           let item = b.entry.item, item.actionID == "window.move" {
            let key = b.key
            if preview.key != key {
                preview.key = key
                preview.frame = runner.previewFrame(item)
            }
            target = preview.frame
        } else {
            preview.key = nil
        }
        // Only on the screen the wheel is on.
        if let frame = target, frame.intersects(screenFrame) {
            preview.show(frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY), style: style)
        } else {
            preview.hide()
        }
        preview.step(dt)
    }

    // MARK: Mouse

    /// Logi Options+'s background agent. While it runs it takes the mouse's scroll wheel, and
    /// any request this app sends the mouse hands the wheel to this app instead for up to four
    /// seconds, during which scrolling stops everywhere.
    private static let optionsPlusAgent = "com.logi.cp-dev-mgr"
    private var optionsPlusRunning = false
    private var mouseReadAt = Date.distantPast

    /// A tap from the mouse's own haptic motor. With Options+ running it goes over Options+'s
    /// Bluetooth channel, so Options+ keeps the scroll wheel.
    private func tapMouse(_ kind: MouseHaptics.Kind) {
        guard demo == nil else { return }
        MouseHaptics.play(kind, over: optionsPlusRunning ? .bluetooth : .hid)
    }

    /// Reads the mouse's settings and battery for the bubbles that show them. With Options+
    /// running this costs the scroll wheel a few seconds, so then at most once a minute.
    private func refreshMouse() {
        let shown = sim.store.root.flatMap { [$0] + ($0.children ?? []) }.contains {
            $0.actionID?.hasPrefix("mouse.") == true || $0.actionID?.hasPrefix("device.") == true
        }
        guard shown, !optionsPlusRunning || Date().timeIntervalSince(mouseReadAt) > 60 else { return }
        mouseReadAt = Date()
        MouseActions.refresh()
    }

    private var loggedPhase = WheelSim.Phase.closed
    /// Made-up states for the scripted demo.
    private let demoControls = DemoControls()
    private lazy var toast = Toast(device: renderer.device)
    /// Where the wheel's hub last was, in screen coordinates: where a toast comes from.
    private var toastPoint: CGPoint?

    private func screenPoint(_ p: V2) -> CGPoint {
        CGPoint(x: screenFrame.minX + p.x, y: screenFrame.maxY - p.y)
    }

    /// Shows what an action did, where the wheel was, or mid-screen when there was no wheel.
    private func showToast(_ message: Toast.Message) {
        guard demo == nil else { return }
        let fallback = NSScreen.main.map { CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero
        toast.show(message, at: toastPoint ?? fallback)
    }
}
