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
            for label in [labelA, labelB, tagLabel, barValue] { label.layer.contentsScale = scale }
            hintLabel.contentsScale = scale
        }
    }

    static let labelFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let hintFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    var hintText = "Press the thumb button to open" {
        didSet { if hintText != oldValue { hintLabel.string = nil } }
    }

    private var icons: [Int: TintedIcon] = [:]
    /// The remove or edit button on each bubble while configuring.
    private var badges: [Int: Badge] = [:]
    private var imageCache: [String: (CGImage, CGSize)] = [:]
    /// One glyph per ring's hub inside a folder or around an edited item: the item's symbol.
    private var hubGlyphs: [Int: TintedIcon] = [:]
    /// The close mark in a ring's hub. It turns 45° into a plus while configuring.
    private var hubMarks: [Int: TintedIcon] = [:]
    /// The dotted border around an item that is being edited.
    private var borders: [Int: CAShapeLayer] = [:]
    /// The level a slider's bubble shows around its rim: a faint track and the filled part.
    private var levelRings: [Int: (track: CAShapeLayer, fill: CAShapeLayer)] = [:]
    /// The reading at the high end of an open bar, such as "45%".
    private let barValue = TextLabel()
    /// An open bar's fill: a rounded well the size of the bar, less a rim, filled from the low end.
    private let barWell = CALayer()
    private let barFill = CALayer()
    /// The back and save marks on an editing panel's buttons. Index 0 is back.
    private var panelMarks: [Int: TintedIcon] = [:]
    private let labelA = TextLabel()
    private let labelB = TextLabel()
    private let tagLabel = TextLabel()
    private let hintLabel = CATextLayer()
    private let cursorLayer = CALayer()
    private var hintColor = SIMD3<Float>(repeating: -1)

    private static let borderRadius = 26.0
    /// Matches `Tuning.badgeRadius`.
    private let badgeRadius = Tuning().badgeRadius

    private final class TintedIcon {
        let layer = CALayer()
        let name: String
        private let mask = CALayer()
        private var tint = SIMD4<Float>(repeating: -1)

        init(name: String, image: CGImage, size: CGSize) {
            self.name = name
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

    /// A small round button: a disc with a glyph on it.
    private final class Badge {
        let layer = CALayer()
        let glyph: TintedIcon
        private var fill = SIMD4<Float>(repeating: -1)

        init(glyph: TintedIcon, radius: Double) {
            self.glyph = glyph
            layer.bounds = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
            layer.cornerRadius = radius
            glyph.layer.position = CGPoint(x: radius, y: radius)
            layer.addSublayer(glyph.layer)
        }

        func setFill(_ rgb: SIMD3<Float>, alpha: Float) {
            let next = SIMD4(rgb, alpha)
            guard simd_reduce_max(simd_abs(next - fill)) > 0.004 else { return }
            fill = next
            layer.backgroundColor = CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: CGFloat(alpha))
        }
    }

    private final class TextLabel {
        let layer = CATextLayer()
        private var text = ""
        private var color = SIMD3<Float>(repeating: -1)

        func set(_ next: String, color rgb: SIMD3<Float>) {
            guard next != text || simd_reduce_max(simd_abs(rgb - color)) > 0.004 else { return }
            text = next
            color = rgb
            let cg = CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            // Two lines sit close, so they read as one label.
            paragraph.maximumLineHeight = 16
            paragraph.minimumLineHeight = 16
            let string = NSAttributedString(string: next, attributes: [
                .font: WheelLayers.labelFont, .foregroundColor: NSColor(cgColor: cg) ?? .white, .paragraphStyle: paragraph,
            ])
            layer.string = string
            let size = string.boundingRect(with: CGSize(width: 1000, height: 200), options: [.usesLineFragmentOrigin]).size
            layer.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 4, height: ceil(size.height))
        }
    }

    init() {
        for layer in [labelA.layer, labelB.layer, tagLabel.layer, barValue.layer, hintLabel] {
            layer.alignmentMode = .center
            layer.contentsScale = scale
            layer.opacity = 0
            root.addSublayer(layer)
        }
        hintLabel.zPosition = 1
        barValue.layer.zPosition = 1.5
        barWell.masksToBounds = true
        barWell.zPosition = 0.5
        barWell.opacity = 0
        barWell.addSublayer(barFill)
        root.addSublayer(barWell)
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

    /// Returns the icon stored under `id`, replacing it when it shows a different symbol.
    private func icon(in store: inout [Int: TintedIcon], id: Int, name: String, pointSize: CGFloat, weight: NSFont.Weight) -> TintedIcon? {
        if let existing = store[id] {
            if existing.name == name { return existing }
            existing.layer.removeFromSuperlayer()
            store[id] = nil
        }
        guard let (image, size) = symbol(name, pointSize: pointSize, weight: weight) else { return nil }
        let icon = TintedIcon(name: name, image: image, size: size)
        root.addSublayer(icon.layer)
        store[id] = icon
        return icon
    }

    /// A folder's badge edits it. Any other item's removes it. An item that becomes a folder
    /// gets a new badge.
    private func badge(for id: Int, folder: Bool) -> Badge? {
        let name = folder ? "pencil" : "xmark"
        if let existing = badges[id] {
            if existing.glyph.name == name { return existing }
            existing.layer.removeFromSuperlayer()
            badges[id] = nil
        }
        guard let (image, size) = symbol(name, pointSize: folder ? 9 : 7.5, weight: folder ? .bold : .heavy) else { return nil }
        let badge = Badge(glyph: TintedIcon(name: name, image: image, size: size), radius: badgeRadius)
        badge.layer.zPosition = 2
        root.addSublayer(badge.layer)
        badges[id] = badge
        return badge
    }

    private func prune(_ store: inout [Int: TintedIcon], keeping seen: Set<Int>) {
        for (id, icon) in store where !seen.contains(id) {
            icon.layer.removeFromSuperlayer()
            store[id] = nil
        }
    }

    private func point(_ p: V2) -> CGPoint {
        CGPoint(x: p.x, y: Double(height) - p.y)
    }

    private func place(_ layer: CALayer, at p: V2, scale s: Double, opacity: Double, rotation: Double = 0) {
        layer.position = point(p)
        var transform = CATransform3DMakeScale(s, s, 1)
        if rotation != 0 { transform = CATransform3DRotate(transform, rotation, 0, 0, 1) }
        layer.transform = transform
        layer.opacity = Float(clamp01(opacity))
    }

    func reset() {
        for badge in badges.values { badge.layer.removeFromSuperlayer() }
        for store in [icons, hubGlyphs, hubMarks, panelMarks] {
            for icon in store.values { icon.layer.removeFromSuperlayer() }
        }
        icons.removeAll()
        badges.removeAll()
        hubGlyphs.removeAll()
        hubMarks.removeAll()
        panelMarks.removeAll()
        for border in borders.values { border.removeFromSuperlayer() }
        borders.removeAll()
        for ring in levelRings.values {
            ring.track.removeFromSuperlayer()
            ring.fill.removeFromSuperlayer()
        }
        levelRings.removeAll()
        barValue.layer.opacity = 0
        barWell.opacity = 0
    }

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    /// Call inside a CATransaction with actions disabled.
    func apply(sim: WheelSim, style: GooStyle, demoCursor: V2?) {
        let t = sim.tuning

        // Bubble icons
        var seen = Set<Int>()
        var seenBadges = Set<Int>()
        var seenRings = Set<Int>()
        for b in sim.bubbles where b.active {
            seen.insert(b.id)
            guard let icon = icon(in: &icons, id: b.id, name: sim.symbol(for: b), pointSize: 19, weight: .medium) else { continue }
            let r = b.radius.value
            let grow = r / t.bubbleRadius
            let tint = Float(clamp01(b.tint.value))
            // An item with its own color shows it in the glyph at rest and in the fill when chosen.
            // A toggle that is on, and the choice in effect, show the accent instead.
            let fill = sim.bubbleColor(b)
            let rest = sim.isLit(b) ? style.accent : (fill ?? style.icon)
            let chosen = fill.map(GooStyle.glyphColor(on:)) ?? style.iconOnAccent
            // An action this Mac can't run is shown faded.
            let available: Float = sim.isAvailable(b) ? 1 : 0.38
            icon.setTint(Self.mix(rest, chosen, tint), alpha: (0.9 + 0.1 * tint) * available)
            let wobble = sim.jiggle(b)
            let fade = sim.iconFade(b)
            place(icon.layer, at: sim.displayPosition(b), scale: min(max(grow, 0.01), 1.4), opacity: (grow - 0.5) / 0.35 * fade, rotation: wobble.rotation)

            if let level = sim.shownLevel(b) {
                seenRings.insert(b.id)
                let ring = levelRings[b.id] ?? makeLevelRing(for: b.id)
                let hot = Float(clamp01(b.tint.value))
                // On a filled bubble the ring takes the glyph's color, so it stays visible.
                let lit = Self.mix(fill ?? style.accent, chosen, hot)
                ring.fill.strokeColor = CGColor(srgbRed: CGFloat(lit.x), green: CGFloat(lit.y), blue: CGFloat(lit.z), alpha: 0.95)
                let base = Self.mix(style.icon, chosen, hot)
                ring.track.strokeColor = CGColor(srgbRed: CGFloat(base.x), green: CGFloat(base.y), blue: CGFloat(base.z), alpha: 0.16)
                ring.fill.strokeEnd = CGFloat(level)
                let ringScale = max(r - 4.5, 1) / Self.levelRingRadius
                let opacity = (grow - 0.6) / 0.3 * fade
                place(ring.track, at: sim.displayPosition(b), scale: ringScale, opacity: opacity)
                place(ring.fill, at: sim.displayPosition(b), scale: ringScale, opacity: opacity)
            }

            let out = clamp01(b.badge.value)
            guard out > 0.02, let item = b.entry.item, let badge = badge(for: b.id, folder: item.isFolder) else { continue }
            seenBadges.insert(b.id)
            // Quiet until the cursor is on it: then red for remove, the accent for edit.
            let hot = Float(clamp01(b.badgeTint.value))
            let hotFill = item.isFolder ? (item.color?.rgb ?? style.accent) : Palette.danger
            // The disc is solid, so it reads as a button where it overhangs the bubble's edge.
            let quiet = Self.mix(style.neutral, style.icon, 0.22)
            badge.setFill(Self.mix(quiet, hotFill, hot), alpha: 1)
            badge.glyph.setTint(Self.mix(style.icon, GooStyle.glyphColor(on: hotFill), hot), alpha: 0.85 + 0.15 * hot)
            place(badge.layer, at: sim.badgeCenter(b), scale: sim.badgeScale(b), opacity: (out - 0.3) / 0.4 * fade)
        }
        prune(&icons, keeping: seen)
        for (id, ring) in levelRings where !seenRings.contains(id) {
            ring.track.removeFromSuperlayer()
            ring.fill.removeFromSuperlayer()
            levelRings[id] = nil
        }
        for (id, badge) in badges where !seenBadges.contains(id) {
            badge.layer.removeFromSuperlayer()
            badges[id] = nil
        }

        // Hubs
        let active = sim.activeLevel
        let mix = clamp01(sim.labelMix.value)
        let configuring = clamp01(sim.config.presence.value)
        var seenGlyphs = Set<Int>()
        var seenMarks = Set<Int>()
        var seenBorders = Set<Int>()
        var barShown = false
        for level in sim.allLevels {
            let presence = clamp01(level.hubHalfH.value / 13)
            // A ring in the background shows no glyph. One that is draining keeps its glyph until its hub is gone.
            let background = level.role == .ghost || level.role == .buried
            let full = background ? 0 : smooth01((level.scale.value - 0.6) / 0.3)
            let labelMix = level === active ? mix : 0
            let opacity = (1 - labelMix) * (1 - labelMix) * presence * full
            let scale = (0.6 + 0.4 * (1 - labelMix)) * (0.5 + 0.5 * presence)
            let position = sim.hubDisplayPosition(level)
            let hubTint = Float(clamp01(level.hubTint.value))
            let fill = level.color?.rgb
            let chosen = fill.map(GooStyle.glyphColor(on:)) ?? style.iconOnAccent
            // While configuring, a ring's hub is its add button.
            let adding = level.isEdit ? 0 : configuring

            if level.isControl, let bar = sim.barGeometry(level) {
                // A bar carries its glyph at the low end, on the fill, and its reading at the high end.
                let symbol = sim.levelSymbol(level) ?? level.symbol ?? "slider.horizontal.3"
                let open = sim.barOpenness(level)
                let accent = fill ?? style.accent
                let onFill = GooStyle.glyphColor(on: accent)
                // How far the fill reaches along the bar, from its low end.
                let span = simd_distance(bar.low, bar.high)
                let reach = 3 + clamp01(bar.value) * max(span - 6, 0)
                func covered(_ at: Double) -> Float { Float(clamp01((reach - at) / 10 + 0.5)) }
                if level === active {
                    placeBarFill(level, bar: bar, color: accent, opacity: open, corner: sim.barCorner(level, thickness: bar.thickness))
                    barShown = true
                }
                if let glyph = icon(in: &hubGlyphs, id: level.id, name: symbol, pointSize: 17, weight: .medium) {
                    seenGlyphs.insert(level.id)
                    glyph.layer.zPosition = 1.5
                    let along = bar.thickness / 2
                    glyph.setTint(Self.mix(style.icon, onFill, covered(along)), alpha: 0.95)
                    let presence = clamp01(bar.thickness / 2 / 13)
                    // The bubble's glyph slides from the middle to the low end as the bar opens.
                    let at = hubPosition(level) + (bar.low + level.barAxis * along - hubPosition(level)) * open
                    place(glyph.layer, at: at, scale: 0.75 + 0.25 * open, opacity: presence * Double(clamp01(level.alpha.value)))
                }
                if level === active, let reading = sim.barReading(level) {
                    let inset = abs(level.barAxis.x) > 0.5 ? 26.0 : 16.0
                    let along = span - inset
                    barValue.set(reading, color: covered(along) > 0.5 ? onFill : style.icon)
                    let at = bar.high - level.barAxis * inset
                    place(barValue.layer, at: at, scale: 0.85 + 0.15 * open, opacity: (open - 0.5) / 0.4)
                }
            } else if let symbol = level.symbol,
               let glyph = icon(in: &hubGlyphs, id: level.id, name: symbol, pointSize: 19, weight: .medium) {
                seenGlyphs.insert(level.id)
                glyph.setTint(Self.mix(fill ?? style.icon, chosen, hubTint), alpha: 0.9)
                // An edited item keeps its bubble's size as the hub. A folder's hub is smaller.
                let size = level.isEdit ? max(level.hubHalfW.value, 0) / t.bubbleRadius : t.hubRadius / t.bubbleRadius
                place(glyph.layer, at: position, scale: scale * size * (1 - 0.3 * adding), opacity: opacity * (1 - adding))
            }
            if !level.isEdit, !level.isControl, level.symbol == nil || adding > 0.01,
               let mark = icon(in: &hubMarks, id: level.id, name: "xmark", pointSize: 11, weight: .bold) {
                seenMarks.insert(level.id)
                let enabled: Float = sim.hasRoom(level) ? 0.92 : 0.24
                let alpha = style.glyphAlpha + (enabled - style.glyphAlpha) * Float(adding)
                mark.setTint(Self.mix(style.icon, chosen, hubTint), alpha: alpha)
                let shown = level.symbol == nil ? 1 : adding
                place(mark.layer, at: position, scale: scale * (1 + 0.2 * adding), opacity: opacity * shown, rotation: .pi / 4 * adding)
            }
            if level.isEdit {
                seenBorders.insert(level.id)
                let border = borders[level.id] ?? makeBorder(for: level.id)
                let removing = level === active && sim.hoveredBubble?.entry.option?.isDestructive == true
                let rgb = removing ? Palette.danger : style.icon
                border.strokeColor = CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: removing ? 0.95 : 0.55)
                let radius = max(level.hubHalfW.value - 4.5, 1)
                // The dots drift around the item slowly, so the border reads as live.
                let turn = t.jiggle > 0 ? -sim.time * 0.35 : 0
                place(border, at: position, scale: radius / Self.borderRadius, opacity: presence * full, rotation: turn)
            }
        }
        prune(&hubGlyphs, keeping: seenGlyphs)
        prune(&hubMarks, keeping: seenMarks)
        if !barShown {
            barValue.layer.opacity = 0
            barWell.opacity = 0
        }
        for (id, border) in borders where !seenBorders.contains(id) {
            border.removeFromSuperlayer()
            borders[id] = nil
        }
        let hubP = active.map(sim.hubDisplayPosition) ?? sim.hubPosition
        let presence = clamp01((active?.hubHalfH.value ?? 0) / 13)

        for (i, label) in [labelA, labelB].enumerated() {
            label.set(sim.labelTitles[i], color: style.icon)
            let fade = clamp01(sim.labelFades[i].value)
            place(label.layer, at: hubP, scale: (0.9 + 0.1 * fade) * (0.7 + 0.3 * presence), opacity: fade * mix * presence)
        }

        // An editing panel's back and save buttons
        // Like the wheel's bubbles: a quiet glyph at rest, and the fill's contrasting color
        // once the button fills under the cursor. The save mark rests in the accent color.
        let buttons = [(sim.editorBackButton, "chevron.left", style.icon), (sim.editorSaveButton, "checkmark", style.accent)]
        var seenMarks2 = Set<Int>()
        for (index, (button, name, rest)) in buttons.enumerated() {
            guard let button, let mark = icon(in: &panelMarks, id: index, name: name, pointSize: 16, weight: .bold) else { continue }
            seenMarks2.insert(index)
            mark.layer.zPosition = 3
            mark.setTint(Self.mix(rest, style.iconOnAccent, Float(button.tint)), alpha: index == 0 ? 0.8 + 0.2 * Float(button.tint) : 1)
            place(mark.layer, at: button.center, scale: min(button.scale, 1.3), opacity: min((button.scale - 0.5) / 0.35, button.opacity))
        }
        prune(&panelMarks, keeping: seenMarks2)

        // The hovered edit option's name
        let tag = clamp01(sim.config.tag.presence.value)
        if tag > 0.02, let center = sim.tagCenter {
            let removing = sim.config.tag.key == .option(.remove)
            tagLabel.set(sim.config.tag.title, color: removing ? Palette.danger : style.icon)
            place(tagLabel.layer, at: center, scale: 0.8 + 0.2 * tag, opacity: (tag - 0.4) / 0.5)
        } else {
            tagLabel.layer.opacity = 0
        }

        // Hint
        if hintLabel.string == nil || hintColor != style.icon {
            hintColor = style.icon
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

    private func hubPosition(_ level: Level) -> V2 { level.hubPos.value }

    /// Lays the fill over the bar's goo: a well inside its rim, filled from the low end to the level.
    private func placeBarFill(_ level: Level, bar: (low: V2, high: V2, knob: V2, value: Double, thickness: Double), color: SIMD3<Float>, opacity: Double, corner: Double) {
        let rim = WheelSim.barRim
        let minP = simd_min(bar.low, bar.high) - V2(bar.thickness / 2, bar.thickness / 2) * V2(abs(level.barAxis.y), abs(level.barAxis.x))
        let maxP = simd_max(bar.low, bar.high) + V2(bar.thickness / 2, bar.thickness / 2) * V2(abs(level.barAxis.y), abs(level.barAxis.x))
        let w = max(maxP.x - minP.x - 2 * rim, 0)
        let h = max(maxP.y - minP.y - 2 * rim, 0)
        barWell.frame = CGRect(x: minP.x + rim, y: Double(height) - maxP.y + rim, width: w, height: h)
        // Concentric with the bar's own corners.
        barWell.cornerRadius = CGFloat(max(min(corner - rim, min(w, h) / 2), 0))
        let horizontal = abs(level.barAxis.x) > 0.5
        let length = horizontal ? w : h
        let filled = length * clamp01(bar.value)
        // Layer coordinates run bottom-up: a standing bar fills from the bottom, a lying one from the left.
        barFill.frame = horizontal ? CGRect(x: 0, y: 0, width: filled, height: h) : CGRect(x: 0, y: 0, width: w, height: filled)
        barFill.backgroundColor = CGColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        barWell.opacity = Float(clamp01((opacity - 0.15) / 0.5) * clamp01(level.alpha.value))
    }

    private static let levelRingRadius = 26.0

    /// A circle drawn from 12 o'clock clockwise, so its stroke end can show a level.
    private func makeLevelRing(for id: Int) -> (track: CAShapeLayer, fill: CAShapeLayer) {
        let r = Self.levelRingRadius
        func ring() -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.bounds = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
            let path = CGMutablePath()
            // Layer coordinates run bottom-up: start at the top and go clockwise on screen.
            path.addArc(center: .zero, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            layer.path = path
            layer.fillColor = nil
            layer.lineWidth = 2.6
            layer.lineCap = .round
            layer.zPosition = 1
            root.addSublayer(layer)
            return layer
        }
        let pair = (track: ring(), fill: ring())
        levelRings[id] = pair
        return pair
    }

    private func makeBorder(for id: Int) -> CAShapeLayer {
        let border = CAShapeLayer()
        let r = Self.borderRadius
        border.bounds = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
        border.path = CGPath(ellipseIn: border.bounds, transform: nil)
        border.fillColor = nil
        border.lineWidth = 2
        border.lineCap = .round
        // Round caps on a near-zero dash draw dots. 32 of them fit the circle exactly.
        let period = 2 * Double.pi * r / 32
        border.lineDashPattern = [0.01, NSNumber(value: period - 0.01)]
        root.addSublayer(border)
        borders[id] = border
        return border
    }
}
