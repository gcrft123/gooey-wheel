import AppKit
import simd

/// What a panel's views are built from.
struct EditorContext {
    let item: WheelItem
    let store: WheelStore
    let style: GooStyle
    let shape: PanelShape

    var size: CGSize { CGSize(width: 2 * shape.half.x, height: 2 * shape.half.y) }
}

/// Colors and metrics shared by the panels, so they match the wheel.
struct EditorTheme {
    let text: NSColor
    let secondary: NSColor
    /// Fill behind fields and behind the row under the cursor.
    let well: NSColor
    let hairline: NSColor
    let accent: NSColor
    let onAccent: NSColor

    /// Space between a panel's edge and what is in it. With the field height below, a field
    /// in a corner is concentric with the panel's corner: 22 + 22 = 44.
    static let padding: CGFloat = 22
    static let corner: CGFloat = 44
    static let rowHeight: CGFloat = 38
    /// Fields are pills.
    static let fieldHeight: CGFloat = 44
    static let font = NSFont.systemFont(ofSize: 15)
    static let strong = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let mono = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    /// Radius of a back or save button, and the room its cutout takes from a bottom corner.
    static let button: CGFloat = 30
    static let cutout: CGFloat = 2 * 30 + 12
    /// Critically damped everywhere, for the Reduce Motion setting.
    static var reducedMotion = false

    init(_ style: GooStyle) {
        func color(_ rgb: SIMD3<Float>, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: alpha)
        }
        text = color(style.icon, 0.92)
        secondary = color(style.icon, 0.5)
        well = color(style.icon, 0.075)
        hairline = color(style.icon, 0.1)
        accent = color(style.accent)
        onAccent = color(style.iconOnAccent)
    }
}

/// A view inside a panel that moves on springs. It is stepped once a frame with the time
/// that passed and where the pointer is, in the window's coordinates, or nil when the
/// pointer isn't over the panel.
protocol EditorAnimated: NSView {
    func tick(_ dt: Double, pointer: CGPoint?)
}

/// A highlight that glides from one place to the next instead of jumping: each edge is a
/// spring, and the edge that leads the move is stiffer than the one that trails, so the
/// shape stretches on the way and gathers itself when it arrives, the way the goo does.
struct GlidingRect {
    private var minX = Spring(0, lead), maxX = Spring(0, lead), minY = Spring(0, lead), maxY = Spring(0, lead)
    var alpha = Spring(0, SpringConfig.critical(k: 700))
    private static let lead = SpringConfig(k: 620, c: 40)
    private static let trail = SpringConfig(k: 300, c: 27)
    private static let still = SpringConfig.critical(k: 600)

    var rect: CGRect {
        CGRect(x: minX.value, y: minY.value, width: max(maxX.value - minX.value, 0), height: max(maxY.value - minY.value, 0))
    }

    var target: CGRect {
        CGRect(x: minX.target, y: minY.target, width: maxX.target - minX.target, height: maxY.target - minY.target)
    }

    var isVisible: Bool { alpha.value > 0.01 }

    var isMoving: Bool {
        [minX, maxX, minY, maxY, alpha].contains { abs($0.value - $0.target) > 0.05 || abs($0.velocity) > 0.5 }
    }

    /// Shows the highlight at `rect`. From hidden it appears there; otherwise it glides.
    mutating func show(at rect: CGRect) {
        if alpha.value < 0.05, alpha.target <= 0 {
            minX.snap(rect.minX)
            maxX.snap(rect.maxX)
            minY.snap(rect.minY)
            maxY.snap(rect.maxY)
        } else {
            let reduced = EditorTheme.reducedMotion
            let right = rect.midX >= target.midX
            let down = rect.midY >= target.midY
            minX.config = reduced ? Self.still : (right ? Self.trail : Self.lead)
            maxX.config = reduced ? Self.still : (right ? Self.lead : Self.trail)
            minY.config = reduced ? Self.still : (down ? Self.trail : Self.lead)
            maxY.config = reduced ? Self.still : (down ? Self.lead : Self.trail)
            minX.target = rect.minX
            maxX.target = rect.maxX
            minY.target = rect.minY
            maxY.target = rect.maxY
        }
        alpha.target = 1
    }

    mutating func hide() {
        alpha.target = 0
    }

    mutating func step(_ dt: Double) {
        minX.step(dt)
        maxX.step(dt)
        minY.step(dt)
        maxY.step(dt)
        alpha.step(dt)
    }
}

/// The views inside one editing panel. A panel edits a copy of the item and writes it back
/// only when saved.
class EditorContent: NSView {
    let original: WheelItem
    var draft: WheelItem {
        didSet { if draft != oldValue { onChange?() } }
    }
    let theme: EditorTheme
    let context: EditorContext
    /// The draft changed.
    var onChange: (() -> Void)?
    /// Return was pressed somewhere it means "done".
    var onSubmit: (() -> Void)?

    init(context: EditorContext) {
        self.context = context
        original = context.item
        draft = context.item
        theme = EditorTheme(context.style)
        super.init(frame: CGRect(origin: .zero, size: context.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var isDirty: Bool { draft != original }

    /// Puts the cursor where typing should go once the panel is open.
    func focus() {}

    /// Writes the draft to the store as one change. For an item that was added for this
    /// panel, adding and setting it up are one change together.
    func commit(joined: Bool) {
        let draft = self.draft
        context.store.update(original.id, joined: joined) { $0 = draft }
    }

    /// The panel's corner buttons are bubbles in the goo underneath, not views. A click in
    /// their cutouts, or anywhere else outside the panel's outline, isn't for these views.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        guard outline.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    /// One scripted interaction, for the demo.
    func demo(_ step: Int) {}

    /// Where something in the panel is, by name, in the window's coordinates: a row, a
    /// field, a control. The demo's cursor aims for these.
    func demoPoint(_ name: String) -> CGPoint? { nil }

    /// Steps every animated view in the panel.
    func step(_ dt: Double, pointer: CGPoint?) {
        func visit(_ view: NSView) {
            (view as? EditorAnimated)?.tick(dt, pointer: pointer)
            for child in view.subviews { visit(child) }
        }
        visit(self)
    }

    /// The panel's outline at rest, in this view's coordinates: where its views take the pointer.
    private(set) lazy var outline = makeOutline()

    private func makeOutline() -> CGPath {
        let shape = context.shape
        let w = bounds.width
        let h = bounds.height
        let top = min(CGFloat(shape.cornerTop), w / 2, h / 2)
        let bottom = min(CGFloat(shape.cornerBottom), w / 2, h / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: top, y: 0))
        path.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: h), radius: top)
        path.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: 0, y: h), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: 0), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: w, y: 0), radius: top)
        path.closeSubpath()
        guard shape.notched else { return path }
        var result: CGPath = path
        let r = EditorTheme.button
        let reach = EditorTheme.cutout - r
        for x in [r, w - r] {
            let disc = CGPath(ellipseIn: CGRect(x: x - reach, y: h - r - reach, width: 2 * reach, height: 2 * reach), transform: nil)
            let corner = CGPath(rect: CGRect(x: x < w / 2 ? -1 : x, y: h - r, width: r + 1, height: r + 1), transform: nil)
            result = result.subtracting(disc).subtracting(corner)
        }
        return result
    }
}
