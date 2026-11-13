import AppKit
import QuartzCore
import simd

/// Icons and labels. These are ordinary layers drawn above the goo and never pass through it,
/// so glyphs stay sharp while the surface under them stretches.
final class WheelLayers {
    let root = CALayer()
    var height: CGFloat = 0
    var scale: CGFloat = 2 {
        didSet {
            guard scale != oldValue else { return }
            imageCache.removeAll()
            for layer in [labelA, labelB, hintLabel] { layer.contentsScale = scale }
        }
    }

    static let labelFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let hintFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    var hintText = "Hold ⌃⌥Space to open" {
        didSet { if hintText != oldValue { hintLabel.string = nil } }
    }

    private var icons: [Int: TintedIcon] = [:]
    private var imageCache: [String: (CGImage, CGSize)] = [:]
    /// One glyph per ring's hub: a close mark at the root, the folder's symbol inside a folder.
    private var hubGlyphs: [Int: TintedIcon] = [:]
    private let labelA = CATextLayer()
    private let labelB = CATextLayer()
    private var labelStrings = ["", ""]
    private let hintLabel = CATextLayer()
    private let cursorLayer = CALayer()
    private var labelColor = SIMD3<Float>(repeating: -1)

    private final class TintedIcon {
        let layer = CALayer()
        private let mask = CALayer()
        private var tint = SIMD4<Float>(repeating: -1)

        init(image: CGImage, size: CGSize) {
            layer.bounds = CGRect(origin: .zero, size: size)
            mask.frame = layer.bounds
            mask.contents = image
            layer.mask = mask
        }

        func setTint(_ rgb: SIMD3<Float>, alpha: Float) {
            let next = SIMD4(rgb, alpha)
            guard simd_reduce_max(simd_abs(next - tint)) > 0.004 else { return }
            tint = next
            layer.backgroundColor = CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: CGFloat(alpha))
        }
    }

    init() {
        for layer in [labelA, labelB, hintLabel] {
            layer.alignmentMode = .center
            layer.contentsScale = scale
            layer.opacity = 0
            root.addSublayer(layer)
        }
        hintLabel.zPosition = 1
        cursorLayer.zPosition = 10
        cursorLayer.isHidden = true
        root.addSublayer(cursorLayer)
    }

    static func labelWidth(_ text: String) -> Double {
        Double(NSAttributedString(string: text, attributes: [.font: labelFont]).size().width)
    }

    func hintWidth() -> Double {
        Double(NSAttributedString(string: hintText, attributes: [.font: Self.hintFont]).size().width)
    }

    /// Shows a drawn pointer at the scripted cursor position during the demo.
    func enableDemoCursor() {
        let cursor = NSCursor.arrow
        let image = cursor.image
        cursorLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cursorLayer.bounds = CGRect(origin: .zero, size: image.size)
        // Anchor at the hot spot. Layer coordinates run bottom-up, the hot spot is measured top-down.
        cursorLayer.anchorPoint = CGPoint(x: cursor.hotSpot.x / image.size.width, y: 1 - cursor.hotSpot.y / image.size.height)
        cursorLayer.isHidden = false
    }

    private func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> (CGImage, CGSize)? {
        let key = "\(name)-\(pointSize)-\(weight.rawValue)"
        if let cached = imageCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil))?
            .withSymbolConfiguration(config) else { return nil }
        let size = image.size
        // Rasterized above screen density so the icon stays sharp when its bubble swells.
        let density = scale * 1.5
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * density).rounded(.up)),
            pixelsHigh: Int((size.height * density).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        imageCache[key] = (cg, size)
        return (cg, size)
    }

    private func makeIcon(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> TintedIcon? {
        guard let (image, size) = symbol(name, pointSize: pointSize, weight: weight) else { return nil }
        let icon = TintedIcon(image: image, size: size)
        root.addSublayer(icon.layer)
        return icon
    }

    private func point(_ p: V2) -> CGPoint {
        CGPoint(x: p.x, y: Double(height) - p.y)
    }

    private func place(_ layer: CALayer, at p: V2, scale s: Double, opacity: Double) {
        layer.position = point(p)
        layer.transform = CATransform3DMakeScale(s, s, 1)
        layer.opacity = Float(clamp01(opacity))
    }

    private func setLabel(_ layer: CATextLayer, index: Int, text: String, color: SIMD3<Float>, colorChanged: Bool) {
        guard labelStrings[index] != text || colorChanged else { return }
        labelStrings[index] = text
        let cg = CGColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        let string = NSAttributedString(string: text, attributes: [.font: Self.labelFont, .foregroundColor: NSColor(cgColor: cg) ?? .white])
        layer.string = string
        let size = string.size()
        layer.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 4, height: ceil(size.height))
    }

    func reset() {
        for icon in icons.values { icon.layer.removeFromSuperlayer() }
        icons.removeAll()
        for glyph in hubGlyphs.values { glyph.layer.removeFromSuperlayer() }
        hubGlyphs.removeAll()
    }

    /// Call inside a CATransaction with actions disabled.
    func apply(sim: WheelSim, style: GooStyle, demoCursor: V2?) {
        let t = sim.tuning

        // Bubble icons
        var seen = Set<Int>()
        for b in sim.bubbles where b.active {
            seen.insert(b.id)
            var icon = icons[b.id]
            if icon == nil {
                icon = makeIcon(b.action.symbol, pointSize: 19, weight: .medium)
                icons[b.id] = icon
            }
            guard let icon else { continue }
            let r = b.radius.value
            let grow = r / t.bubbleRadius
            let tint = Float(clamp01(b.tint.value))
            icon.setTint(style.icon + (style.iconOnAccent - style.icon) * tint, alpha: 0.9 + 0.1 * tint)
            place(icon.layer, at: b.pos.value, scale: min(max(grow, 0.01), 1.4), opacity: (grow - 0.5) / 0.35 * sim.iconFade(b))
        }
        for (id, icon) in icons where !seen.contains(id) {
            icon.layer.removeFromSuperlayer()
            icons[id] = nil
        }

        // Hubs
        let active = sim.activeLevel
        let mix = clamp01(sim.labelMix.value)
        var seenLevels = Set<Int>()
        for level in sim.allLevels {
            seenLevels.insert(level.id)
            var glyph = hubGlyphs[level.id]
            if glyph == nil {
                glyph = level.symbol.map { makeIcon($0, pointSize: 19, weight: .medium) }
                    ?? makeIcon("xmark", pointSize: 11, weight: .bold)
                hubGlyphs[level.id] = glyph
            }
            guard let glyph else { continue }
            let presence = clamp01(level.hubHalfH.value / 13)
            // A ring in the background shows no glyph. One that is draining keeps its glyph until its hub is gone.
            let background = level.role == .ghost || level.role == .buried
            let full = background ? 0 : smooth01((level.scale.value - 0.6) / 0.3)
            let labelMix = level === active ? mix : 0
            let opacity = (1 - labelMix) * (1 - labelMix) * presence * full
            var scale = (0.6 + 0.4 * (1 - labelMix)) * (0.5 + 0.5 * presence)
            if level.symbol == nil {
                glyph.setTint(style.icon, alpha: style.glyphAlpha)
            } else {
                let tint = Float(clamp01(level.hubTint.value))
                glyph.setTint(style.icon + (style.iconOnAccent - style.icon) * tint, alpha: 0.9)
                scale *= t.hubRadius / t.bubbleRadius
            }
            place(glyph.layer, at: level.hubPos.value, scale: scale, opacity: opacity)
        }
        for (id, glyph) in hubGlyphs where !seenLevels.contains(id) {
            glyph.layer.removeFromSuperlayer()
            hubGlyphs[id] = nil
        }
        let hubP = sim.hubPosition
        let presence = clamp01((active?.hubHalfH.value ?? 0) / 13)

        let colorChanged = labelColor != style.icon
        labelColor = style.icon
        for (i, layer) in [labelA, labelB].enumerated() {
            setLabel(layer, index: i, text: sim.labelTitles[i], color: style.icon, colorChanged: colorChanged)
            let fade = clamp01(sim.labelFades[i].value)
            place(layer, at: hubP, scale: (0.9 + 0.1 * fade) * (0.7 + 0.3 * presence), opacity: fade * mix * presence)
        }

        // Hint
        if hintLabel.string == nil || colorChanged {
            let cg = CGColor(srgbRed: CGFloat(style.icon.x), green: CGFloat(style.icon.y), blue: CGFloat(style.icon.z), alpha: 0.86)
            let string = NSAttributedString(string: hintText, attributes: [.font: Self.hintFont, .foregroundColor: NSColor(cgColor: cg) ?? .white])
            hintLabel.string = string
            let size = string.size()
            hintLabel.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 4, height: ceil(size.height))
        }
        let hint = clamp01(sim.hintPresence.value)
        place(hintLabel, at: sim.hintCenter, scale: 0.8 + 0.2 * hint, opacity: (hint - 0.4) / 0.5)

        if let demoCursor {
            cursorLayer.position = point(demoCursor)
        }
    }
}
