import AppKit
import simd

/// The welcome panel's body, drawn in goo like the wheel's editing panels: a firm panel with a
/// round button in each bottom corner, sitting in a cutout. The buttons drip out of the panel,
/// swell and fill under the cursor, and give when pressed. Views added to `content` are clipped
/// to the panel's outline, cutouts included.
final class WelcomeGoo: NSView {
    /// What the right button shows: Continue, then Done.
    enum NextMark: String {
        case forward = "chevron.right"
        case done = "checkmark"
    }

    /// The panel's frame inside this view. Around it is room for the goo's shadow.
    let panelFrame: CGRect
    let content: NSView
    var onBack: (() -> Void)?
    var onNext: (() -> Void)?

    /// The back button is out of the panel. It goes back in when false.
    var backShown = false
    var nextMark = NextMark.forward {
        didSet {
            guard nextMark != oldValue else { return }
            next.radius.velocity += 140
            marks[1].mask = Self.symbol(nextMark.rawValue)
        }
    }

    private static let corner = 44.0
    private static let yellow = SIMD3<Float>(1, 0.78, 0.1)
    private static let gap = 12.0

    private let renderer: GooRenderer?
    private let gooView: GooView?
    /// Clips the content to the panel as the goo draws it, cutouts included.
    private let mask = PanelMask()
    private let marks = [CALayer(), CALayer()]
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var tuning = Tuning()
    private var style = GooStyle.resolve(dark: true, accent: .gooeyYellow)
    private var back: Button
    private var next: Button
    private var cursor = V2(-1000, -1000)
    private var hit: Side?
    private var press: Side?
    /// Seconds since the panel came up.
    private var age = 0.0

    // The way in: a hub pops up and throws out a ring of eight bubbles, as the wheel does when
    // it opens. The bubbles turn yellow and fall back into the hub, which swallows each with a
    // gulp and then spreads out into the panel, wide first and tall a beat later, its yellow
    // draining into the gradient as the contents come up. The right button drips out last.
    private struct Drop {
        let angle: Double
        var pos: Spring2
        var radius: Spring
        var launched = false
        var falling = false
    }

    private var drops: [Drop] = []
    private var bodyW: Spring
    private var bodyH: Spring
    private var bodyCorner: Spring
    private var bodyTint: Spring
    private var reduced = false
    private static let hubRadius = 22.0
    private static let ringAt = 0.12
    private static let fallAt = 0.92
    private static let spreadAt = 1.3

    /// How much of its full size the panel has, 0 to 1.
    private var progress: Double {
        clamp01(min(bodyW.value / half.x, bodyH.value / half.y))
    }
    private lazy var elements = [ButtonElement(self, .back), ButtonElement(self, .next)]

    private enum Side { case back, next }

    private struct Button {
        var pos: Spring2
        var tail: Spring2
        var radius: Spring
        var tint: Spring
        /// 0 while it is inside the panel, 1 once it is out. The cutout opens with it.
        var out: Spring
        var shown = false
        var appeared = false

        init(_ t: Tuning) {
            pos = Spring2(V2(0, 0), t.enterPos)
            tail = Spring2(V2(0, 0), t.tailPos)
            radius = Spring(0, t.radiusRest)
            tint = Spring(0, t.tint)
            out = Spring(0, SpringConfig.critical(k: 260))
        }
    }

    init(panel size: CGSize, margin: CGFloat) {
        panelFrame = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        content = NSView(frame: panelFrame)
        renderer = GooRenderer()
        gooView = renderer.map { GooView(device: $0.device) }
        back = Button(tuning)
        next = Button(tuning)
        bodyW = Spring(0, tuning.hubMorph)
        bodyH = Spring(0, tuning.hubMorph)
        bodyCorner = Spring(Self.hubRadius, tuning.panelSize)
        bodyTint = Spring(0, tuning.tint)
        super.init(frame: CGRect(x: 0, y: 0, width: size.width + 2 * margin, height: size.height + 2 * margin))
        wantsLayer = true

        if let gooView {
            gooView.frame = bounds
            gooView.autoresizingMask = [.width, .height]
            addSubview(gooView)
        }
        content.wantsLayer = true
        content.layer?.mask = mask.layer
        addSubview(content)
        for (index, mark) in marks.enumerated() {
            mark.mask = Self.symbol(index == 0 ? "chevron.left" : nextMark.rawValue)
            mark.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
            mark.opacity = 0
            mark.zPosition = 10
            layer?.addSublayer(mark)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Running

    /// A pointer drawn at this point of the view and used in place of the real one, for
    /// recording the panel without touching the real pointer.
    var scriptedCursor: CGPoint? {
        didSet {
            guard let scriptedCursor else { return }
            if cursorLayer.superlayer == nil {
                let arrow = NSCursor.arrow
                cursorLayer.contents = arrow.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                cursorLayer.bounds = CGRect(origin: .zero, size: arrow.image.size)
                cursorLayer.anchorPoint = CGPoint(x: arrow.hotSpot.x / arrow.image.size.width, y: 1 - arrow.hotSpot.y / arrow.image.size.height)
                cursorLayer.zPosition = 20
                layer?.addSublayer(cursorLayer)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.position = scriptedCursor
            CATransaction.commit()
        }
    }
    private let cursorLayer = CALayer()

    /// Presses and releases at the scripted pointer.
    func scriptedPress() {
        cursor = scriptedCursor.map(sim) ?? cursor
        hit = hitTest(cursor)
        press = hit
    }

    func scriptedRelease() {
        let pressed = press
        press = nil
        if let pressed, hitTest(cursor) == pressed { perform(pressed) }
    }

    /// Starts the way in. A recording steps the frames itself and runs no display link.
    func start(manual: Bool = false) {
        reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        tuning = reduced ? .reducedMotion : Tuning()
        age = 0
        leftAt = nil
        handedOff = false
        beginIntro()
        guard let gooView, !manual else { return }
        if link == nil {
            let created = gooView.displayLink(target: self, selector: #selector(tick(_:)))
            created.add(to: .main, forMode: .common)
            link = created
        }
        lastTimestamp = 0
        link?.isPaused = false
        step(0)
    }

    func stop() {
        link?.isPaused = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTimestamp == 0 ? link.duration : now - lastTimestamp
        lastTimestamp = now
        step(min(max(dt, 1.0 / 480), 1.0 / 20))
    }

    /// Steps the springs on by `dt` and draws a frame. A preview with no display link calls it directly.
    func step(_ dt: Double) {
        age += dt
        if let scriptedCursor {
            cursor = sim(scriptedCursor)
        } else if let window, dt > 0 {
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            cursor = sim(p)
        }
        let newHit = leftAt == nil ? hitTest(cursor) : nil
        if newHit != hit {
            hit = newHit
            if newHit != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        if leftAt == nil { stepIntro(dt) } else { stepOutro(dt) }
        let open = progress > 0.93 && leftAt == nil
        stepButton(&back, side: -1, shown: open && backShown, hovered: hit == .back, pressed: press == .back && hit == .back, dt)
        stepButton(&next, side: 1, shown: open, hovered: hit == .next, pressed: press == .next && hit == .next, dt)
        // The contents come up once the panel has most of its size.
        let alpha = reduced ? clamp01(age / 0.3) : smooth01((progress - 0.72) / 0.25)
        if abs(Double(content.alphaValue) - alpha) > 0.003 { content.alphaValue = alpha }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateMask()
        updateMarks()
        if let renderer, let gooView {
            renderer.draw(blobs: blobs(), origin: V2(0, 0), scale: Double(window?.backingScaleFactor ?? 2), style: style, in: gooView.metalLayer)
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        gooView?.configure(scale: window?.backingScaleFactor ?? 2)
        renderer?.invalidate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStyle()
    }

    private func updateStyle() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        style = GooStyle.resolve(dark: dark, accent: .gooeyYellow)
        renderer?.invalidate()
    }

    // MARK: Geometry, in the goo's coordinates: points from the top-left, y down

    private func sim(_ p: CGPoint) -> V2 { V2(Double(p.x), Double(bounds.height - p.y)) }
    private func view(_ p: V2) -> CGPoint { CGPoint(x: p.x, y: Double(bounds.height) - p.y) }

    private var center: V2 { sim(CGPoint(x: panelFrame.midX, y: panelFrame.midY)) }
    private var half: V2 { V2(Double(panelFrame.width / 2), Double(panelFrame.height / 2)) }

    /// Where a button rests, tucked into a bottom corner.
    private func rest(_ side: Double) -> V2 {
        let r = tuning.bubbleRadius
        return center + V2(side * (half.x - r), half.y - r)
    }

    /// Where a button waits inside the panel before it comes out.
    private func origin(_ side: Double) -> V2 {
        let inside = rest(side) + V2(-side, -1) * 44
        guard leftAt != nil else { return inside }
        // A panel on its way out takes its buttons in with it instead of leaving them outside.
        let room = simd_max(V2(bodyW.value, bodyH.value) - tuning.bubbleRadius, V2(0, 0))
        return center + simd_clamp(inside - center, -room, room)
    }

    private func hitTest(_ p: V2) -> Side? {
        if back.shown, simd_distance(p, back.pos.value) < back.radius.value + 3 { return .back }
        if next.shown, simd_distance(p, next.pos.value) < next.radius.value + 3 { return .next }
        return nil
    }

    private func stepButton(_ button: inout Button, side: Double, shown: Bool, hovered: Bool, pressed: Bool, _ dt: Double) {
        let t = tuning
        let rest = rest(side)
        let origin = origin(side)
        let travel = simd_distance(rest, origin)
        if shown, !button.shown {
            // Like a bubble leaving the hub: it starts small, inside.
            button.pos.snap(origin)
            button.tail.snap(origin)
            button.radius.snap(t.bubbleRadius * 0.45)
            button.appeared = true
        }
        button.shown = shown
        guard button.appeared else { return }
        if shown {
            var home = rest
            if hovered { home += clampLength((cursor - rest) * 0.22, 7) }
            button.pos.config = t.enterPos
            button.pos.target = home
            // It grows as it leaves, so the panel doesn't bulge while it holds it.
            let emerge = max(0.5, clamp01(simd_distance(button.pos.value, origin) / (travel * 0.5)))
            button.radius.config = hovered ? t.radiusHover : t.radiusRest
            button.radius.target = (hovered ? t.hoverRadius : t.bubbleRadius) * (pressed ? 0.93 : 1) * emerge
            button.tint.target = hovered ? 1 : 0
        } else {
            let left = simd_distance(button.pos.value, origin)
            button.pos.config = t.retractPos
            button.pos.target = origin
            button.radius.config = t.radiusLeave
            button.radius.target = left < 5 || leftAt != nil ? -3 : t.bubbleRadius * clamp01(left / max(travel, 1))
            button.tint.target = 0
        }
        button.out.target = shown ? 1 : 0
        button.pos.step(dt)
        button.tail.target = button.pos.value
        button.tail.step(dt)
        button.radius.step(dt)
        button.tint.step(dt)
        button.out.step(dt)
    }

    // MARK: The way in

    private func beginIntro() {
        let t = tuning
        bodyTint = Spring(0, SpringConfig.critical(k: 120))
        bodyCorner = Spring(Self.hubRadius, t.panelSize)
        guard !reduced else {
            // Reduce Motion: the panel is there, and its contents fade in.
            drops = []
            bodyW = Spring(half.x, t.panelSize)
            bodyH = Spring(half.y, t.panelSize)
            bodyCorner.snap(Self.corner)
            return
        }
        bodyW = Spring(0, t.hubMorph)
        bodyH = Spring(0, t.hubMorph)
        bodyW.target = Self.hubRadius
        bodyH.target = Self.hubRadius
        drops = (0..<8).map { i in
            Drop(angle: Double(i) / 8 * 2 * .pi - .pi / 2, pos: Spring2(center, t.enterPos), radius: Spring(0, t.radiusRest))
        }
    }

    private func stepIntro(_ dt: Double) {
        let t = tuning
        for i in drops.indices {
            var d = drops[i]
            let order = Double(i)
            if !d.launched, age >= Self.ringAt + order * 0.035 {
                d.launched = true
                d.radius.snap(t.bubbleRadius * 0.45)
                d.radius.target = t.bubbleRadius
                d.pos.target = center + t.ringRadius * V2(cos(d.angle), sin(d.angle))
            }
            if !d.falling, age >= Self.fallAt + order * 0.03 {
                d.falling = true
                d.pos.config = t.retractPos
                d.pos.target = center
                d.radius.config = t.radiusLeave
            }
            if d.falling {
                d.radius.target = t.bubbleRadius * clamp01(simd_distance(d.pos.value, center) / t.ringRadius + 0.25)
            }
            d.pos.step(dt)
            d.radius.step(dt)
            drops[i] = d
        }
        // The hub gulps as each bubble lands in it.
        let landed = drops.filter { $0.falling && simd_distance($0.pos.value, center) < 14 }.count
        if landed > 0 {
            drops.removeAll { $0.falling && simd_distance($0.pos.value, center) < 14 }
            if age < Self.spreadAt {
                bodyW.velocity += 90 * Double(landed)
                bodyH.velocity += 90 * Double(landed)
                bodyW.target += 2.5 * Double(landed)
                bodyH.target += 2.5 * Double(landed)
            }
        }
        if !reduced {
            if age >= Self.fallAt { bodyTint.target = 1 }
            if age >= Self.spreadAt {
                bodyW.config = t.panelSize
                bodyW.target = half.x
                bodyCorner.target = Self.corner
                bodyTint.config = SpringConfig.critical(k: 110)
                bodyTint.target = 0
            }
            // Tall a beat after wide, so it opens as a bar that then drops open.
            if age >= Self.spreadAt + 0.09 {
                bodyH.config = t.panelSize
                bodyH.target = half.y
            }
        }
        bodyW.step(dt)
        bodyH.step(dt)
        bodyCorner.step(dt)
        bodyTint.step(dt)
    }

    // MARK: The way out

    /// The way out is the way in, backwards, and ends as the wheel: the buttons go back into
    /// the panel, the panel drops shut to a bar and then draws in to a hub, turning yellow as
    /// it goes. The hub is the wheel's in size, color, and place, down to the wheel's lean
    /// toward the cursor, so once its yellow has drained the wheel can open with its own hub
    /// already formed on the same spot and nothing shows of the change. `onHandoff` is called
    /// then, with the wheel's center in this view.
    var onHandoff: ((CGPoint) -> Void)?
    private var leftAt: Double?
    private var handedOff = false

    func leave() {
        guard leftAt == nil else { return }
        leftAt = age
        press = nil
    }

    private func stepOutro(_ dt: Double) {
        guard let leftAt else { return }
        let t = tuning
        let since = age - leftAt
        let hub = t.hubRadius
        drops = []
        // Nearly no overshoot, so it arrives round, the shape of the wheel's hub.
        let settle = SpringConfig(k: 300, c: 32)
        // The buttons get a moment to go in first.
        if since >= 0.1 {
            bodyH.config = settle
            bodyH.target = hub
            bodyCorner.target = hub
            if abs(bodyW.value - hub) >= 1.5 || abs(bodyH.value - hub) >= 1.5 {
                bodyTint.config = SpringConfig.critical(k: 90)
                bodyTint.target = 1
            }
        }
        if since >= 0.2 {
            bodyW.config = settle
            bodyW.target = hub
        }
        bodyW.step(dt)
        bodyH.step(dt)
        bodyCorner.step(dt)
        bodyTint.step(dt)
        // Round and the right size: the yellow drains, and then the wheel takes over.
        if since > 0.3, abs(bodyW.value - hub) < 1.5, abs(bodyH.value - hub) < 1.5 {
            bodyTint.config = SpringConfig.critical(k: 320)
            bodyTint.target = 0
            if !handedOff, bodyTint.value < 0.02 {
                handedOff = true
                bodyW.snap(hub)
                bodyH.snap(hub)
                onHandoff?(CGPoint(x: panelFrame.midX, y: panelFrame.midY))
            }
        }
    }

    /// The cutout a button sits in: wider than it by the gap, opening from the corner as it comes out.
    private func cutout(_ button: Button, side: Double) -> Blob.Cutout? {
        let out = clamp01(button.out.value)
        guard out > 0.002 else { return nil }
        let corner = center + V2(side * half.x, half.y)
        let rest = rest(side)
        let lean = button.shown ? button.pos.target - rest : V2(0, 0)
        return Blob.Cutout(center: corner + (rest - corner) * out + lean * out, radius: (max(button.radius.value, tuning.bubbleRadius) + Self.gap) * out)
    }

    /// The panel as the goo draws it, or nil before there is any of it.
    private func panelBlob() -> Blob? {
        let w = max(bodyW.value, 0)
        let h = max(bodyH.value, 0)
        guard w > 0.3, h > 0.3 else { return nil }
        // On the way out it takes up the wheel's lean toward the cursor as it nears a hub's size.
        var lean = V2(0, 0)
        if leftAt != nil {
            lean = WheelSim.hubLean(cursor: cursor, center: center) * (1 - smooth01((progress - 0.06) / 0.4))
        }
        var panel = Blob(center: center + lean, half: V2(w, h), corner: min(max(bodyCorner.value, 0), w, h), tint: clamp01(bodyTint.value), color: Self.yellow)
        // Soft while it is a hub among its bubbles, so they fuse. Firm once it is a panel.
        panel.firm = smooth01(progress)
        panel.cutoutLeft = cutout(back, side: -1)
        panel.cutoutRight = cutout(next, side: 1)
        return panel
    }

    private func blobs() -> [Blob] {
        var out: [Blob] = []
        let tint = clamp01(bodyTint.value)
        if let panel = panelBlob() { out.append(panel) }
        for drop in drops where drop.launched && drop.radius.value > 0.3 {
            let r = drop.radius.value
            out.append(Blob(center: drop.pos.value, half: V2(r, r), corner: r, tint: tint, color: Self.yellow))
        }
        for button in [back, next] {
            let r = button.radius.value
            guard r > 0.3 else { continue }
            let tint = clamp01(button.tint.value)
            // Soft on its way out, so it draws out of the panel like a drop. Firm once out.
            let firm = smooth01(button.out.value)
            out.append(Blob(center: button.pos.value, half: V2(r, r), corner: r, tint: tint, firm: firm))
            let tr = r * 0.72 * clamp01(simd_distance(button.tail.value, button.pos.value) / 9)
            if tr > 0.5 {
                out.append(Blob(center: button.tail.value, half: V2(tr, tr), corner: tr, tint: tint, firm: firm))
            }
        }
        return out
    }

    private func updateMask() {
        // The content's top-left corner in the goo's coordinates, which run top-down.
        let origin = V2(Double(panelFrame.minX), Double(bounds.height - panelFrame.maxY))
        mask.update(panel: panelBlob(), origin: origin, size: panelFrame.size, scale: window?.backingScaleFactor ?? 2)
    }

    /// A quiet glyph at rest, and the fill's contrasting color once the button fills under the
    /// cursor. The right button's mark rests in the accent color.
    private func updateMarks() {
        for (index, (button, side)) in [(back, -1.0), (next, 1.0)].enumerated() {
            let mark = marks[index]
            let along = simd_distance(button.pos.value, origin(side)) / max(simd_distance(rest(side), origin(side)), 1)
            let scale = button.radius.value / tuning.bubbleRadius
            let t = Float(clamp01(button.tint.value))
            let restColor = index == 0 ? style.icon : style.accent
            let rgb = restColor + (style.iconOnAccent - restColor) * t
            let alpha = index == 0 ? 0.8 + 0.2 * t : 1
            mark.backgroundColor = CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: CGFloat(alpha))
            mark.position = view(button.pos.value)
            let s = min(max(scale, 0), 1.3)
            mark.transform = CATransform3DMakeScale(s, s, 1)
            mark.opacity = Float(clamp01(min((scale - 0.5) / 0.35, smooth01((along - 0.6) / 0.3))))
        }
    }

    /// A symbol as a mask: its shape in white on clear, colored by the layer's background.
    private static func symbol(_ name: String) -> CALayer {
        let mask = CALayer()
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            var rect = CGRect(origin: .zero, size: image.size)
            mask.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: 2))])
            mask.bounds = CGRect(origin: .zero, size: image.size)
            mask.position = CGPoint(x: 13, y: 13)
            mask.contentsScale = 2
        }
        return mask
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        guard leftAt == nil else { return }
        cursor = sim(convert(event.locationInWindow, from: nil))
        hit = hitTest(cursor)
        guard let hit else {
            // Anywhere else on the panel moves the window.
            window?.performDrag(with: event)
            return
        }
        press = hit
    }

    override func mouseUp(with event: NSEvent) {
        cursor = sim(convert(event.locationInWindow, from: nil))
        let pressed = press
        press = nil
        guard let pressed, hitTest(cursor) == pressed else { return }
        perform(pressed)
    }

    private func perform(_ side: Side) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        switch side {
        case .back:
            back.radius.velocity += 200
            onBack?()
        case .next:
            next.radius.velocity += 200
            onNext?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks in the shadow around the panel go through to whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if hitTest(sim(p)) != nil { return self }
        guard panelFrame.contains(p) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + elements.filter { $0.side == .back ? back.shown : next.shown }
    }

    private final class ButtonElement: NSAccessibilityElement {
        weak var owner: WelcomeGoo?
        let side: Side

        init(_ owner: WelcomeGoo, _ side: Side) {
            self.owner = owner
            self.side = side
            super.init()
            setAccessibilityRole(.button)
            setAccessibilityParent(owner)
        }

        override func accessibilityLabel() -> String? {
            switch side {
            case .back: return "Back"
            case .next: return owner?.nextMark == .done ? "Done" : "Continue"
            }
        }

        override func accessibilityFrame() -> NSRect {
            guard let owner, let window = owner.window else { return .zero }
            let button = side == .back ? owner.back : owner.next
            let p = owner.view(button.pos.value)
            let r = CGFloat(owner.tuning.bubbleRadius)
            let rect = owner.convert(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), to: nil)
            return window.convertToScreen(rect)
        }

        override func accessibilityPerformPress() -> Bool {
            owner?.perform(side)
            return true
        }
    }
}

extension NSColor {
    static let gooeyYellow = NSColor(srgbRed: 1, green: 0.78, blue: 0.1, alpha: 1)
}
