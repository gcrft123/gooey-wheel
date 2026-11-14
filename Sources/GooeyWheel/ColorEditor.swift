import AppKit
import simd

extension ItemColor {
    init(hue: Double, saturation: Double, brightness: Double) {
        let c = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(.sRGB) ?? .white
        self.init(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }

    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }
}

/// A pill with a hue and saturation wheel in its round top, a hex field, and swatches:
/// the default, a few presets, and the colors saved before.
final class ColorEditor: EditorContent {
    private static let presets = ["#FF453A", "#FF9F0A", "#30D158", "#0A84FF", "#BF5AF2"].compactMap(ItemColor.init(hex:))

    private let wheel: ColorWheelView
    private let hex: WellField
    private var swatches: [SwatchView] = []

    override init(context: EditorContext) {
        let theme = EditorTheme(context.style)
        wheel = ColorWheelView(theme: theme)
        hex = WellField(theme: theme, placeholder: "#", font: .monospacedSystemFont(ofSize: 15, weight: .medium), centered: true)
        super.init(context: context)

        // The wheel is concentric with the pill's round top.
        let radius = bounds.width / 2
        let margin: CGFloat = 16
        wheel.frame = CGRect(x: margin, y: margin, width: 2 * (radius - margin), height: 2 * (radius - margin))
        wheel.onPick = { [weak self] color in self?.set(color, from: .wheel) }
        addSubview(wheel)

        let pad = EditorTheme.padding
        hex.frame = CGRect(x: pad, y: 2 * radius + 8, width: bounds.width - 2 * pad, height: EditorTheme.fieldHeight)
        hex.onChange = { [weak self] text in
            // A field that is cleared goes back to the default. A partial code changes nothing yet.
            if text.trimmingCharacters(in: .whitespaces).isEmpty { self?.set(nil, from: .field) }
            else if let color = ItemColor(hex: text) { self?.set(color, from: .field) }
        }
        hex.onReturn = { [weak self] in self?.onSubmit?() }
        addSubview(hex)

        // The default first, then presets, then saved colors on a second row.
        let rows: [[ItemColor?]] = [[nil] + Self.presets.map(Optional.some), context.store.savedColors.map(Optional.some)]
        let size: CGFloat = 30
        let inset = pad + 4
        let gap = (bounds.width - 2 * inset - 6 * size) / 5
        for (r, row) in rows.enumerated() {
            for (i, color) in row.prefix(6).enumerated() {
                let swatch = SwatchView(color: color, theme: theme)
                swatch.frame = CGRect(x: inset + CGFloat(i) * (size + gap), y: hex.frame.maxY + 16 + CGFloat(r) * (size + 10), width: size, height: size)
                swatch.onPick = { [weak self] in self?.set(color, from: .swatch) }
                addSubview(swatch)
                swatches.append(swatch)
            }
        }
        show(draft.color, except: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private enum Source { case wheel, field, swatch }

    private func set(_ color: ItemColor?, from source: Source) {
        draft.color = color
        show(color, except: source)
    }

    /// Brings every control in line with the color, apart from the one being used.
    private func show(_ color: ItemColor?, except source: Source?) {
        if source != .wheel { wheel.color = color }
        if source != .field { hex.text = color?.hex ?? "" }
        for swatch in swatches { swatch.isChosen = swatch.color?.hex == color?.hex }
    }

    override func focus() {
        hex.focus(selectAll: true)
    }

    override func commit(joined: Bool) {
        super.commit(joined: joined)
        if let color = draft.color { context.store.remember(color) }
    }

    override func demoPoint(_ name: String) -> CGPoint? {
        if name == "hex" { return hex.demoPoint }
        if name.hasPrefix("swatch:"), let i = Int(name.dropFirst(7)), swatches.indices.contains(i) {
            return swatches[i].convert(CGPoint(x: swatches[i].bounds.midX, y: swatches[i].bounds.midY), to: nil)
        }
        // "wheel:angle,saturation", the angle in degrees counterclockwise from 3 o'clock.
        let parts = name.dropFirst(6).split(separator: ",").compactMap { Double($0) }
        guard name.hasPrefix("wheel:"), parts.count == 2 else { return nil }
        let r = wheel.bounds.width / 2
        let a = parts[0] * .pi / 180
        return wheel.convert(CGPoint(x: r + CGFloat(cos(a) * parts[1]) * r, y: r - CGFloat(sin(a) * parts[1]) * r), to: nil)
    }

    override func demo(_ step: Int) {
        set(ItemColor(hex: "#FF5C8A"), from: .swatch)
    }
}

/// Hue around, saturation outward. The knob shows the color itself; it glides to a color
/// set from the field or a swatch, and swells while it is held.
private final class ColorWheelView: NSView, EditorAnimated {
    var color: ItemColor? {
        didSet {
            guard color?.hex != oldValue?.hex else { return }
            if let color {
                let target = point(for: color)
                // From no color, the knob appears in place. From another, it travels.
                if oldValue == nil || dragging { knob.snap(V2(target.x, target.y)) } else { knob.target = V2(target.x, target.y) }
            }
            needsDisplay = true
        }
    }
    var onPick: ((ItemColor) -> Void)?
    private let theme: EditorTheme
    private var image: CGImage?
    private var dragging = false
    private var knob = Spring2(V2(0, 0), SpringConfig(k: 420, c: 30))
    private var size = Spring(0, SpringConfig(k: 520, c: 25))

    init(theme: EditorTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func point(for color: ItemColor) -> CGPoint {
        let (h, s, _) = color.hsb
        let r = bounds.width / 2
        let a = h * 2 * .pi
        return CGPoint(x: r + CGFloat(cos(a) * s) * r, y: r - CGFloat(sin(a) * s) * r)
    }

    override func layout() {
        super.layout()
        if let color {
            let p = point(for: color)
            knob.snap(V2(p.x, p.y))
        }
    }

    private func wheelImage(pixels: Int) -> CGImage? {
        if let image, image.width == pixels { return image }
        var data = [UInt8](repeating: 0, count: pixels * pixels * 4)
        let c = Double(pixels) / 2
        for y in 0..<pixels {
            for x in 0..<pixels {
                let dx = (Double(x) + 0.5 - c) / c
                let dy = (Double(y) + 0.5 - c) / c
                let d = (dx * dx + dy * dy).squareRoot()
                guard d <= 1.02 else { continue }
                let rgb = ItemColor.rgb(hue: atan2(dy, dx) / (2 * .pi), saturation: min(d, 1))
                // One pixel of soft edge.
                let alpha = min(max((1 - d) * c + 0.5, 0), 1)
                let i = (y * pixels + x) * 4
                data[i] = UInt8(rgb.x * alpha * 255)
                data[i + 1] = UInt8(rgb.y * alpha * 255)
                data[i + 2] = UInt8(rgb.z * alpha * 255)
                data[i + 3] = UInt8(alpha * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        image = CGImage(
            width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
        return image
    }

    func tick(_ dt: Double, pointer: CGPoint?) {
        size.target = color == nil ? 0 : (dragging ? 15 : 11)
        size.step(dt)
        knob.step(dt)
        let moving = abs(size.value - size.target) > 0.02 || simd_distance(knob.value, knob.target) > 0.05
        if moving { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        if let image = wheelImage(pixels: Int(bounds.width * scale)) {
            context.draw(image, in: bounds)
        }
        // The default has no place on the wheel, so it shows no knob.
        let r = CGFloat(size.value)
        guard let color, r > 0.5 else { return }
        let p = CGPoint(x: knob.value.x, y: knob.value.y)
        let disc = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 5, color: CGColor(gray: 0, alpha: 0.35))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: disc)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(color.nsColor.cgColor)
        context.fillEllipse(in: disc.insetBy(dx: 3.5, dy: 3.5))
    }

    private func pick(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = bounds.width / 2
        let dx = Double((p.x - r) / r)
        let dy = Double((r - p.y) / r)
        var hue = atan2(dy, dx) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let picked = ItemColor(hue: hue, saturation: min((dx * dx + dy * dy).squareRoot(), 1), brightness: 1)
        color = picked
        onPick?(picked)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        pick(event)
    }

    override func mouseDragged(with event: NSEvent) { pick(event) }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }
}

private extension ItemColor {
    /// Full-brightness color for the wheel's pixels.
    static func rgb(hue: Double, saturation s: Double) -> SIMD3<Double> {
        var h = hue
        h -= h.rounded(.down)
        let k = h * 6
        let f = k - k.rounded(.down)
        let p = 1 - s, q = 1 - s * f, t = 1 - s * (1 - f)
        switch Int(k) % 6 {
        case 0: return SIMD3(1, t, p)
        case 1: return SIMD3(q, 1, p)
        case 2: return SIMD3(p, 1, t)
        case 3: return SIMD3(p, q, 1)
        case 4: return SIMD3(t, p, 1)
        default: return SIMD3(1, p, q)
        }
    }
}

/// One round swatch. Nil is the default, drawn as an empty ring with a stroke through it.
/// Like a bubble, it swells under the pointer; the chosen one wears a ring.
private final class SwatchView: NSView, EditorAnimated {
    let color: ItemColor?
    var onPick: (() -> Void)?
    var isChosen = false
    private let theme: EditorTheme
    private var swell = Spring(0, SpringConfig(k: 520, c: 25))
    private var ring = Spring(0, SpringConfig(k: 520, c: 30))

    init(color: ItemColor?, theme: EditorTheme) {
        self.color = color
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    func tick(_ dt: Double, pointer: CGPoint?) {
        let over = pointer.map { bounds.insetBy(dx: -3, dy: -3).contains(convert($0, from: nil)) } ?? false
        swell.target = over ? 1 : 0
        ring.target = isChosen ? 1 : 0
        let moving = abs(swell.value - swell.target) > 0.005 || abs(ring.value - ring.target) > 0.005
        swell.step(dt)
        ring.step(dt)
        if moving { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let chosen = CGFloat(clamp01(ring.value))
        // The disc makes room for the ring when chosen, and grows a little under the pointer.
        let inset = 4 + 2.5 * chosen - 2 * CGFloat(swell.value)
        let inner = bounds.insetBy(dx: inset, dy: inset)
        if let color {
            color.nsColor.setFill()
            NSBezierPath(ovalIn: inner).fill()
        } else {
            theme.secondary.setStroke()
            let outline = NSBezierPath(ovalIn: inner.insetBy(dx: 0.75, dy: 0.75))
            outline.lineWidth = 1.5
            outline.stroke()
            let slash = NSBezierPath()
            let d = inner.width / 2 * 0.707 - 1
            slash.move(to: CGPoint(x: bounds.midX - d, y: bounds.midY - d))
            slash.line(to: CGPoint(x: bounds.midX + d, y: bounds.midY + d))
            slash.lineWidth = 1.5
            slash.stroke()
        }
        if chosen > 0.01 {
            (color?.nsColor ?? theme.text).withAlphaComponent(chosen).setStroke()
            let outline = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.25, dy: 1.25))
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }
}
