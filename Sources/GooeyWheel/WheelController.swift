import AppKit
import Carbon.HIToolbox
import QuartzCore
import simd

/// Borderless panel that covers one screen while the wheel is up. It takes clicks without
/// activating the app, so the frontmost app keeps its focus.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayContentView: NSView {
    weak var controller: WheelController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.handleClick() }
    override func rightMouseDown(with event: NSEvent) { controller?.dismiss() }
}

final class WheelController: NSObject {
    static let gooViewSize: CGFloat = 760
    private static let escapeHotKey: UInt32 = 2

    let sim = WheelSim()
    private let renderer: GooRenderer
    private let panel: OverlayPanel
    private let content = OverlayContentView()
    private let stageView = NSView()
    private let gooView: GooView
    private let hostView = NSView()
    private let layers = WheelLayers()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var screenFrame = CGRect.zero
    private var scale: CGFloat = 2
    private var style = GooStyle.resolve(dark: true, accent: .controlAccentColor)
    private var gooOrigin = V2(0, 0)

    var timescale = 1.0
    var demo: DemoDriver?
    var stage: String?
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

    init?(renderer: GooRenderer) {
        self.renderer = renderer
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

        content.controller = self
        content.wantsLayer = true
        panel.contentView = content

        stageView.wantsLayer = true
        stageView.isHidden = true
        content.addSubview(stageView)
        content.addSubview(gooView)
        hostView.layer = layers.root
        hostView.wantsLayer = true
        content.addSubview(hostView)

        sim.labelWidth = { WheelLayers.labelWidth($0) }
        sim.hintHalfWidth = layers.hintWidth() / 2 + 14
        sim.onHover = {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        sim.onSelect = { _ in
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    // MARK: Coordinates

    /// Screen coordinates (origin bottom-left) to wheel coordinates (origin top-left of the panel).
    private func toSim(_ p: CGPoint) -> V2 {
        V2(Double(p.x - screenFrame.minX), Double(screenFrame.maxY - p.y))
    }

    private func attach(to screen: NSScreen) {
        screenFrame = screen.frame
        scale = screen.backingScaleFactor
        panel.setFrame(screenFrame, display: false)
        hostView.frame = content.bounds
        layers.height = content.bounds.height
        layers.scale = scale

        let visible = screen.visibleFrame
        let t = sim.tuning
        let inset = t.ringRadius + t.hoverRadius + 14
        let minX = Double(visible.minX - screenFrame.minX) + inset
        let maxX = Double(visible.maxX - screenFrame.minX) - inset
        let minY = Double(screenFrame.maxY - visible.maxY) + inset
        let maxY = Double(screenFrame.maxY - visible.minY) - inset
        sim.clampCenter = { c in
            V2(min(max(c.x, minX), max(minX, maxX)), min(max(c.y, minY), max(minY, maxY)))
        }
    }

    private func positionGooView(force: Bool = false) {
        let size = Double(Self.gooViewSize)
        let origin = V2((sim.center.x - size / 2).rounded(), (sim.center.y - size / 2).rounded())
        guard force || origin != gooOrigin else { return }
        gooOrigin = origin
        gooView.frame = CGRect(x: origin.x, y: Double(content.bounds.height) - origin.y - size, width: size, height: size)
        gooView.configure(scale: scale)
    }

    // MARK: Open and close

    var isOpen: Bool { sim.phase == .open }

    /// Opens at `point` in screen coordinates, or at the cursor when nil.
    func open(at point: CGPoint? = nil, mode: WheelSim.Mode, hint: Bool = false, cursor: V2? = nil) {
        let mouse = NSEvent.mouseLocation
        let anchor = point ?? mouse
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        if sim.phase == .closed || screen.frame != screenFrame {
            attach(to: screen)
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        style = GooStyle.resolve(dark: dark, accent: .controlAccentColor)
        sim.tuning = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .reducedMotion : Tuning()

        let center = sim.clampCenter(toSim(anchor))
        sim.open(center: center, cursor: cursor ?? toSim(mouse), mode: mode, hint: hint)
        positionGooView(force: true)
        renderer.invalidate()

        panel.orderFrontRegardless()
        HotKeyCenter.shared.register(id: Self.escapeHotKey, keyCode: kVK_Escape, modifiers: 0) { [weak self] pressed in
            if pressed { self?.sim.escape() }
        }
        startLink()
    }

    func dismiss() {
        updateCursor()
        sim.dismiss()
    }

    func triggerReleased() {
        updateCursor()
        sim.triggerReleased()
    }

    func handleClick() {
        updateCursor()
        sim.click()
    }

    private func updateCursor() {
        if demo == nil {
            sim.cursor = toSim(NSEvent.mouseLocation)
        }
    }

    private func hide() {
        HotKeyCenter.shared.unregister(id: Self.escapeHotKey)
        layers.reset()
        guard demo == nil else { return }
        link?.isPaused = true
        panel.orderOut(nil)
    }

    // MARK: Demo stage

    /// Shows the panel with an opaque backdrop and runs the scripted cursor, for recordings.
    func startDemo(_ driver: DemoDriver) {
        guard let screen = NSScreen.main else { return }
        demo = driver
        attach(to: screen)
        let center = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        driver.origin = toSim(center)
        driver.anchor = center
        if let stage {
            let size = CGSize(width: 860, height: 660)
            stageView.frame = CGRect(x: content.bounds.midX - size.width / 2 + 50, y: content.bounds.midY - size.height / 2, width: size.width, height: size.height)
            let gradient = CAGradientLayer()
            gradient.frame = stageView.bounds
            gradient.cornerRadius = 36
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
        panel.orderFrontRegardless()
        positionGooView(force: true)
        startLink()
    }

    // MARK: Frame loop

    private func startLink() {
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
        var dt = lastTimestamp == 0 ? link.duration : now - lastTimestamp
        lastTimestamp = now
        dt = min(max(dt, 1.0 / 480), 1.0 / 20) * timescale

        if let demo {
            demo.advance(dt, controller: self)
            sim.cursor = demo.cursor
        } else {
            sim.cursor = toSim(NSEvent.mouseLocation)
        }

        let wasClosed = sim.phase == .closed
        sim.step(dt)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        positionGooView()
        layers.apply(sim: sim, style: style, demoCursor: demo?.cursor)
        renderer.draw(blobs: sim.blobs(), origin: gooOrigin, scale: Double(scale), style: style, in: gooView.metalLayer)
        CATransaction.commit()

        if sim.phase == .closed, !wasClosed {
            hide()
        }
    }
}

/// Moves a drawn cursor through a fixed path and clicks, so the motion can be recorded
/// without touching the real pointer.
final class DemoDriver {
    enum Event { case open, click, escape, finish }

    var origin = V2(0, 0)
    var anchor = CGPoint.zero
    private(set) var cursor = V2(0, 0)
    private var time = 0.0
    private var fired = 0
    private let path: [(Double, V2)]
    private let events: [(Double, Event)]
    private let exitWhenDone: Bool

    init(exitWhenDone: Bool) {
        self.exitWhenDone = exitWhenDone
        let s = 76.4 // ring radius on the diagonal
        path = [
            (0.0, V2(0, 0)),
            (0.9, V2(0, 0)),
            (1.25, V2(s, -s)),          // Mission Control
            (1.6, V2(s, -s)),
            (2.3, V2(s, s)),            // sweep past Media to Emoji
            (2.6, V2(s, s)),
            (2.95, V2(0, 0)),           // back to the hub
            (3.2, V2(0, 0)),
            (3.55, V2(108, 0)),         // rest on Media, which opens
            (4.3, V2(108, 0)),
            (4.65, V2(206, -45)),       // Next
            (4.95, V2(206, -45)),
            (5.3, V2(139, -103)),       // Play/Pause
            (5.7, V2(139, -103)),
            (6.1, V2(10, 0)),           // rest on the parent ring, which returns
            (6.6, V2(10, 0)),
            (6.95, V2(108, 0)),         // Media again
            (7.5, V2(108, 0)),
            (7.85, V2(139, -103)),      // Play/Pause
            (9.2, V2(139, -103)),
        ]
        events = [(0.3, .open), (8.2, .click), (9.0, .finish)]
    }

    func advance(_ dt: Double, controller: WheelController) {
        time += dt
        var p = path[path.count - 1].1
        for i in 1..<path.count where time < path[i].0 {
            let (t0, p0) = path[i - 1]
            let (t1, p1) = path[i]
            p = p0 + (p1 - p0) * smooth01((time - t0) / (t1 - t0))
            break
        }
        cursor = origin + p

        while fired < events.count, events[fired].0 <= time {
            let event = events[fired].1
            fired += 1
            switch event {
            case .open: controller.open(at: anchor, mode: .sticky, cursor: cursor)
            case .click: controller.handleClick()
            case .escape: controller.sim.escape()
            case .finish:
                if exitWhenDone {
                    NSApp.terminate(nil)
                } else {
                    time = 0
                    fired = 0
                }
            }
        }
    }
}
