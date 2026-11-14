import AppKit
import QuartzCore
import simd

/// A short message after an action, such as "Copied #A1B2C3", or why it couldn't run. It
/// grows out of the spot where the wheel's hub was, as a pill of the same goo, and drains
/// away a moment later.
final class Toast: NSObject {
    struct Message {
        let text: String
        let symbol: String
        /// The glyph's color. Nil is the usual glyph color.
        var color: SIMD3<Float>? = nil
        var isError = false
        /// A color shown as a disc in place of the glyph, such as a color that was picked.
        var swatch: SIMD3<Float>? = nil
        /// Seconds it stays up, for one that waits on something. Nil scales with the text.
        var lasts: TimeInterval? = nil
    }

    private static let size = CGSize(width: 640, height: 180)
    private static let halfHeight = 19.0
    private static let padding = 16.0
    private static let gap = 9.0
    /// The space around a swatch, the same all the way round: it sits in the pill's rounded end.
    private static let swatchInset = 5.0
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)

    private let renderer: GooRenderer?
    private let panel: NSPanel
    private let gooView: GooView
    private let host = CALayer()
    private let glyph = CALayer()
    private let glyphMask = CALayer()
    private let swatch = CALayer()
    private let label = CATextLayer()
    /// Half the width of whatever sits in the pill's rounded end.
    private var markHalfWidth = 8.0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    private var halfW = Spring(0, SpringConfig(k: 420, c: 24))
    private var halfH = Spring(0, SpringConfig(k: 420, c: 24))
    private var content = Spring(0, SpringConfig.critical(k: 500))
    private var hideAt: CFTimeInterval = 0
    private var clock: CFTimeInterval = 0
    private var shown = false
    private var targetHalfW = 0.0
    private var style = GooStyle.resolve(dark: true, accent: .controlAccentColor)
    private var scale: CGFloat = 2
    private var hasSwatch = false

    init(device: MTLDevice) {
        renderer = GooRenderer()
        gooView = GooView(device: renderer?.device ?? device)
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let content = NSView(frame: CGRect(origin: .zero, size: Self.size))
        content.wantsLayer = true
        gooView.frame = content.bounds
        content.addSubview(gooView)
        let overlay = NSView(frame: content.bounds)
        overlay.wantsLayer = true
        overlay.layer = host
        content.addSubview(overlay)
        panel.contentView = content
        glyph.mask = glyphMask
        label.alignmentMode = .left
        swatch.borderWidth = 1
        for layer in [glyph, swatch, label] {
            layer.opacity = 0
            host.addSublayer(layer)
        }
    }

    /// The toast's window, for capturing it.
    var windowNumber: Int { panel.windowNumber }

    /// Shows `message` centered on `point`, in screen coordinates. A message already showing
    /// turns into the new one.
    func show(_ message: Message, at point: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        scale = screen?.backingScaleFactor ?? 2
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        style = GooStyle.resolve(dark: dark, accent: .controlAccentColor)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let grow = reduced ? SpringConfig.critical(k: 600) : SpringConfig(k: 420, c: 24)
        halfW.config = grow
        halfH.config = grow

        // Kept inside the screen, whatever the size.
        var frame = CGRect(x: point.x - Self.size.width / 2, y: point.y - Self.size.height / 2, width: Self.size.width, height: Self.size.height)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX - Self.size.width / 2 + 160), visible.maxX - Self.size.width / 2 - 160)
            frame.origin.y = min(max(frame.minY, visible.minY - 40), visible.maxY - Self.size.height + 40)
        }
        panel.setFrame(frame, display: false)
        gooView.configure(scale: scale)
        host.contentsScale = scale
        label.contentsScale = scale
        glyphMask.contentsScale = scale

        let color = message.isError ? Palette.danger : (message.color ?? style.icon)
        let text = NSAttributedString(string: message.text, attributes: [
            .font: Self.font,
            .foregroundColor: NSColor(srgbRed: CGFloat(style.icon.x), green: CGFloat(style.icon.y), blue: CGFloat(style.icon.z), alpha: 0.95),
        ])
        let textSize = text.size()
        label.string = text
        label.bounds = CGRect(x: 0, y: 0, width: ceil(textSize.width) + 2, height: ceil(textSize.height))
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: message.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let imageSize = image?.size ?? CGSize(width: 16, height: 16)
        glyphMask.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        glyph.bounds = CGRect(origin: .zero, size: imageSize)
        glyphMask.frame = glyph.bounds
        glyph.backgroundColor = CGColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)

        if let rgb = message.swatch {
            let radius = Self.halfHeight - Self.swatchInset
            swatch.bounds = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
            swatch.cornerRadius = radius
            swatch.backgroundColor = CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
            // A hairline keeps a color close to the pill's own from disappearing into it.
            swatch.borderColor = CGColor(srgbRed: CGFloat(style.icon.x), green: CGFloat(style.icon.y), blue: CGFloat(style.icon.z), alpha: 0.18)
            markHalfWidth = radius
        } else {
            markHalfWidth = Double(imageSize.width) / 2
        }
        hasSwatch = message.swatch != nil
        // The mark sits centered in the pill's rounded end, the words after it.
        let width = Self.halfHeight + markHalfWidth + Self.gap + Double(ceil(textSize.width)) + Self.padding
        targetHalfW = width / 2
        if !shown {
            // It starts as a drop where the hub was.
            halfW.snap(Self.halfHeight * 0.45)
            halfH.snap(Self.halfHeight * 0.45)
            content.snap(0)
        } else {
            // Turning into the next message, the old words go first.
            content.snap(min(content.value, 0.2))
        }
        shown = true
        clock = 0
        hideAt = message.lasts ?? 1.5 + Double(message.text.count) * 0.025 + (message.isError ? 1.2 : 0)
        panel.orderFrontRegardless()
        renderer?.invalidate()
        startLink()
    }

    /// Drains the message showing now, if any.
    func dismiss() {
        guard shown else { return }
        hideAt = min(hideAt, clock)
    }

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
        let dt = min(max(lastTimestamp == 0 ? link.duration : now - lastTimestamp, 1.0 / 480), 1.0 / 20)
        lastTimestamp = now
        clock += dt
        let leaving = clock >= hideAt
        // The words go first, then the pill drains.
        if leaving, clock < hideAt + 0.12 {
            content.target = 0
        } else if leaving {
            halfW.config = .critical(k: 520)
            halfH.config = .critical(k: 520)
            halfW.target = -4
            halfH.target = -4
            content.target = 0
        } else {
            halfW.target = targetHalfW
            halfH.target = Self.halfHeight
            // The words come in once the pill has most of its width.
            content.target = halfW.value > targetHalfW * 0.75 ? 1 : 0
        }
        halfW.step(dt)
        halfH.step(dt)
        content.step(dt)
        draw()
        if leaving, halfW.value < 0.5 || halfH.value < 0.5 {
            shown = false
            link.isPaused = true
            panel.orderOut(nil)
        }
    }

    private func draw() {
        let size = Self.size
        let center = V2(Double(size.width) / 2, Double(size.height) / 2)
        let w = max(halfW.value, 0)
        let h = max(halfH.value, 0)
        var blobs: [Blob] = []
        if w > 0.3, h > 0.3 {
            blobs.append(Blob(center: center, half: V2(w, h), corner: min(w, h), tint: 0))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Never more of the words than the pill has room for.
        let alpha = Float(clamp01(content.value) * clamp01((w / max(targetHalfW, 1) - 0.6) / 0.3))
        let left = Double(size.width) / 2 - w
        let midY = Double(size.height) / 2
        // The center of the pill's rounded end, which follows the pill's height as it grows.
        let markX = left + min(h, w)
        glyph.position = CGPoint(x: markX, y: midY)
        swatch.position = CGPoint(x: markX, y: midY)
        let swatchScale = CGFloat(clamp01(h / Self.halfHeight))
        swatch.transform = CATransform3DMakeScale(swatchScale, swatchScale, 1)
        label.position = CGPoint(x: markX + markHalfWidth + Self.gap + Double(label.bounds.width) / 2, y: midY)
        glyph.opacity = hasSwatch ? 0 : alpha
        swatch.opacity = hasSwatch ? alpha : 0
        label.opacity = alpha
        renderer?.draw(blobs: blobs, origin: V2(0, 0), scale: Double(scale), style: style, in: gooView.metalLayer)
        CATransaction.commit()
    }
}

/// Where actions report what they did, or why they couldn't, for the toast.
enum ActionFeedback {
    /// Set by the wheel. Called on the main thread.
    static var show: ((Toast.Message) -> Void)?

    static func confirm(_ text: String, symbol: String) {
        post(Toast.Message(text: text, symbol: symbol))
    }

    /// A confirmation that shows a color as a disc, such as one just picked.
    static func confirm(_ text: String, swatch: NSColor) {
        let rgb = swatch.usingColorSpace(.sRGB).map { SIMD3<Float>(Float($0.redComponent), Float($0.greenComponent), Float($0.blueComponent)) }
        post(Toast.Message(text: text, symbol: "circle.fill", swatch: rgb))
    }

    static func failed(_ text: String) {
        post(Toast.Message(text: text, symbol: "exclamationmark.triangle.fill", isError: true))
    }

    private static func post(_ message: Toast.Message) {
        if Thread.isMainThread {
            show?(message)
        } else {
            DispatchQueue.main.async { show?(message) }
        }
    }
}
