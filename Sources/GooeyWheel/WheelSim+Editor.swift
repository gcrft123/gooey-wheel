import Foundation
import simd

/// An editing panel's outline at rest.
struct PanelShape {
    var half: V2
    /// Radius of the top corners, and of the bottom ones.
    var cornerTop: Double
    var cornerBottom: Double
    /// The back and save buttons sit in cutouts in the bottom corners. Otherwise they sit
    /// beside the panel, left and right.
    var notched: Bool

    static func shape(for option: EditOption) -> PanelShape {
        switch option {
        case .action: return PanelShape(half: V2(390, 250), cornerTop: 44, cornerBottom: 44, notched: true)
        // A pill on top, where the color wheel fills the half circle.
        case .color: return PanelShape(half: V2(140, 250), cornerTop: 140, cornerBottom: 44, notched: true)
        case .icon: return PanelShape(half: V2(204, 272), cornerTop: 44, cornerBottom: 44, notched: true)
        case .rename, .remove: return PanelShape(half: V2(150, 30), cornerTop: 30, cornerBottom: 30, notched: false)
        }
    }
}

enum EditorHit: Equatable {
    case none, outside, panel, back, save
}

/// One editing panel, from the moment a bubble starts turning into it until it has turned back.
struct EditorState {
    let option: EditOption
    let itemID: UUID
    /// The bubble that became the panel, and the ring it belongs to.
    let anchor: BubbleKey
    let levelID: Int
    let shape: PanelShape
    /// The item was added for this panel. Leaving without saving removes it again.
    let provisional: Bool
    /// Where the panel rests, kept on screen.
    var center: V2

    var pos: Spring2
    var halfW: Spring
    var halfH: Spring
    var cornerTop: Spring
    var cornerBottom: Spring
    /// 0 is the bubble, 1 the open panel. The contents and the firm edge follow it.
    var open: Spring
    var tint: Spring
    var back: PanelButton
    var save: PanelButton
    var dirty = false
    var saved = false
    var closing = false
    /// The wheel is closing with the panel open. It shrinks away where it is.
    var dismissed = false
    var hit = EditorHit.none
    var press: EditorHit?
}

/// The back or save button of a panel. It is a bubble like the wheel's: it drips out of the
/// panel on the same springs, swells and fills under the cursor, and gives when pressed.
struct PanelButton {
    var pos: Spring2
    var tail: Spring2
    var radius: Spring
    var tint: Spring
    /// 0 while it is inside the panel, 1 once it is out. The panel's cutout opens with it.
    var out: Spring
    var shown = false
    var appeared = false

    init(tuning t: Tuning) {
        pos = Spring2(V2(0, 0), t.enterPos)
        tail = Spring2(V2(0, 0), t.tailPos)
        radius = Spring(0, t.radiusRest)
        tint = Spring(0, t.tint)
        out = Spring(0, SpringConfig.critical(k: 260))
    }
}

extension WheelSim {
    /// Clear space between a panel and the buttons in its corners or at its ends.
    static let panelButtonGap = 12.0

    var editorIsOpen: Bool { config.editor != nil }

    /// The panel's frame at rest, for the views that fill it.
    var editorRect: (center: V2, half: V2)? {
        config.editor.map { ($0.center, $0.shape.half) }
    }

    /// 0 until the panel is most of the way open, then up to 1.
    var editorContentAlpha: Double {
        guard let e = config.editor, !e.dismissed else { return 0 }
        return smooth01((e.open.value - 0.62) / 0.3)
    }

    func isEditorAnchor(_ key: BubbleKey, in level: Level) -> Bool {
        config.editor.map { $0.anchor == key && $0.levelID == level.id } ?? false
    }

    // MARK: Opening and closing

    /// Turns a bubble into its panel: an edit option, or a new item whose action is being chosen.
    func openEditor(_ option: EditOption, from b: Bubble, provisional: Bool = false) {
        guard config.editor == nil, let level = levels.last, b.level === level else { return }
        let itemID: UUID
        switch level.kind {
        case .edit(let id): itemID = id
        case .ring:
            guard let item = b.entry.item else { return }
            itemID = item.id
        }
        let t = tuning
        let shape = PanelShape.shape(for: option)
        let r = max(b.radius.value, 8)
        // The panel opens over the item it edits. One for a new item opens over the middle
        // of the wheel the item was added to.
        let anchorHome = level.center
        var e = EditorState(
            option: option, itemID: itemID, anchor: b.key, levelID: level.id, shape: shape, provisional: provisional,
            center: clampPanel(anchorHome, panelExtent(shape)),
            pos: Spring2(b.pos.value, t.panelPos), halfW: Spring(r, t.panelSize), halfH: Spring(r, t.panelSize),
            cornerTop: Spring(r, t.panelSize), cornerBottom: Spring(r, t.panelSize),
            open: Spring(0, t.panelOpen), tint: Spring(clamp01(b.tint.value), t.tint),
            back: PanelButton(tuning: t), save: PanelButton(tuning: t)
        )
        e.pos.velocity = b.pos.velocity
        config.editor = e
        config.hit = .none
        setHover(nil, back: false)

        bubbles.removeAll { $0 === b }
        retreat(level)
        if levels.count >= 2 { bury(levels[levels.count - 2]) }
        onEditorOpen?(EditorRequest(option: option, itemID: itemID))
    }

    /// The room a panel needs around its center, with its buttons.
    private func panelExtent(_ shape: PanelShape) -> V2 {
        let side = shape.notched ? 0 : 2 * tuning.bubbleRadius + Self.panelButtonGap
        return shape.half + V2(side, 0)
    }

    /// Turns the panel back into its bubble. What was changed in it is already saved or is dropped.
    func closeEditor() {
        guard var e = config.editor, !e.closing else { return }
        e.closing = true
        e.press = nil
        e.hit = .none
        config.editor = e
        if e.provisional, !e.saved {
            store.discardInsert(e.itemID)
        }
        syncLevels()
        if let level = levels.last, level.id == e.levelID {
            level.retreating = false
            level.hubClosing = false
            level.hubHalfW.snap(0)
            level.hubHalfH.snap(0)
            level.hubHalfW.config = tuning.hubMorph
            level.hubHalfH.config = tuning.hubMorph
            spawn(level, delay: 0.04)
            if levels.count >= 2 { resurrect(levels[levels.count - 2]) }
            // The cursor is wherever the panel's button was. The ring ignores it until it moves.
            armed = false
            armOrigin = cursor
        }
        onEditorClose?()
    }

    /// The contents changed, or went back to what they were.
    func setEditorDirty(_ dirty: Bool) {
        config.editor?.dirty = dirty
    }

    /// The panel's changes were written to the store.
    func editorSaved() {
        config.editor?.saved = true
        config.editor?.dirty = false
        closeEditor()
    }

    // MARK: Pointer

    private func editorHit(_ p: V2) -> EditorHit {
        guard let e = config.editor, !e.closing else { return .none }
        if e.back.shown, simd_distance(p, e.back.pos.value) < e.back.radius.value + 3 { return .back }
        if e.save.shown, simd_distance(p, e.save.pos.value) < e.save.radius.value + 3 { return .save }
        let q = simd_abs(p - e.pos.value)
        if q.x < e.halfW.value, q.y < e.halfH.value { return .panel }
        return q.x < e.halfW.value + 24 && q.y < e.halfH.value + 24 ? .panel : .outside
    }

    func refreshEditorHover() {
        guard config.editor != nil else { return }
        let hit = phase == .open ? editorHit(cursor) : .none
        if hit != config.editor?.hit {
            config.editor?.hit = hit
            if hit == .back || hit == .save { onHover?() }
        }
    }

    func editorPointerDown() {
        refreshEditorHover()
        let hit = config.editor?.hit
        config.editor?.press = hit
    }

    func editorPointerUp() {
        guard let e = config.editor, let press = e.press else { return }
        config.editor?.press = nil
        refreshEditorHover()
        guard config.editor?.hit == press else { return }
        switch press {
        case .back:
            config.editor?.back.radius.velocity += 200
            closeEditor()
        case .save:
            config.editor?.save.radius.velocity += 200
            onEditorSave?()
        case .outside:
            // Nothing to lose closes the panel. Otherwise the save button jumps, to ask for a decision.
            if e.dirty {
                config.editor?.save.radius.velocity += 260
                onEdit?(.refused)
            } else {
                closeEditor()
            }
        case .panel, .none:
            break
        }
    }

    // MARK: Step

    func stepEditor(_ dt: Double) {
        guard var e = config.editor else { return }
        let t = tuning
        let r = t.bubbleRadius
        let level = levels.last { $0.id == e.levelID }

        if e.dismissed {
            e.halfW.target = -4
            e.halfH.target = -4
            e.open.target = 0
        } else if e.closing {
            // Back to the bubble it came from, at its place in the ring. An item that was
            // dropped has no place: the panel drains into the hub.
            var home = level?.hubPos.value ?? e.pos.value
            var size = -4.0
            if let level, let slot = level.slot(of: e.anchor) {
                let a = level.angle(slot)
                home = level.center + t.ringRadius * V2(cos(a), sin(a))
                size = r
            }
            e.pos.target = home
            e.halfW.target = size
            e.halfH.target = size
            e.cornerTop.target = r
            e.cornerBottom.target = r
            e.open.target = 0
        } else {
            e.pos.target = e.center
            e.halfW.target = e.shape.half.x
            e.halfH.target = e.shape.half.y
            e.cornerTop.target = e.shape.cornerTop
            e.cornerBottom.target = e.shape.cornerBottom
            e.open.target = 1
        }
        e.tint.target = 0
        e.pos.step(dt)
        e.halfW.step(dt)
        e.halfH.step(dt)
        e.cornerTop.step(dt)
        e.cornerBottom.step(dt)
        e.open.step(dt)
        e.tint.step(dt)

        // The back button comes out once the panel has most of its size. The save button
        // comes out when there is something to save.
        let ready = !e.closing && !e.dismissed && e.open.value > 0.5
        stepButton(&e.back, in: e, side: -1, shown: ready, hit: .back, dt)
        stepButton(&e.save, in: e, side: 1, shown: ready && e.dirty, hit: .save, dt)
        config.editor = e

        if e.dismissed {
            if e.halfW.value < 0.5 { config.editor = nil }
            return
        }
        guard e.closing, e.open.value < 0.06 else { return }
        // The panel is a bubble again. Hand it back to its ring.
        config.editor = nil
        guard let level, let slot = level.slot(of: e.anchor) else { return }
        let b = addBubble(level.entries[slot], slot: slot, level: level, at: time)
        b.active = true
        b.pos.snap(e.pos.value)
        b.pos.velocity = e.pos.velocity
        b.tail.snap(e.pos.value)
        b.radius.snap(max(e.halfW.value, 4))
    }

    /// Where a button rests: tucked into a bottom corner, or beside the end of a pill.
    private func buttonRest(_ e: EditorState, side: Double) -> V2 {
        let r = tuning.bubbleRadius
        if e.shape.notched {
            return e.pos.value + V2(side * (e.halfW.value - r), e.halfH.value - r)
        }
        return e.pos.value + V2(side * (e.halfW.value + Self.panelButtonGap + r), 0)
    }

    /// Where a button waits inside the panel before it comes out, and where it goes back to.
    private func buttonOrigin(_ e: EditorState, side: Double) -> V2 {
        let rest = buttonRest(e, side: side)
        return e.shape.notched ? rest + V2(-side, -1) * 44 : rest + V2(-side * (2 * tuning.bubbleRadius + Self.panelButtonGap), 0)
    }

    private func stepButton(_ button: inout PanelButton, in e: EditorState, side: Double, shown: Bool, hit: EditorHit, _ dt: Double) {
        let t = tuning
        let rest = buttonRest(e, side: side)
        let origin = buttonOrigin(e, side: side)
        let travel = simd_distance(rest, origin)
        if shown, !button.shown {
            // Like a bubble leaving the hub: it starts small, inside.
            button.pos.snap(origin)
            button.tail.snap(origin)
            button.radius.snap(t.bubbleRadius * 0.45)
            button.appeared = true
        }
        button.shown = shown
        guard button.appeared else {
            // Until it first comes out there is nothing of it anywhere.
            button.pos.snap(origin)
            button.tail.snap(origin)
            return
        }
        if shown {
            let hovered = e.hit == hit
            let pressed = hovered && e.press == hit
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
            button.radius.target = left < 5 ? -3 : t.bubbleRadius * clamp01(left / max(travel, 1))
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

    // MARK: Output

    /// What the layers above the goo need to draw a button's mark.
    struct ButtonMark {
        var center: V2
        var scale: Double
        var tint: Double
        /// The mark shows once the button is out of the panel, not while it is still inside.
        var opacity: Double
    }

    var editorBackButton: ButtonMark? { mark(for: config.editor?.back, side: -1) }
    var editorSaveButton: ButtonMark? { mark(for: config.editor?.save, side: 1) }

    private func mark(for button: PanelButton?, side: Double) -> ButtonMark? {
        guard let button, let e = config.editor, !e.dismissed, button.radius.value > 1 else { return nil }
        // By how far the button has come from where it started inside the panel.
        let origin = buttonOrigin(e, side: side)
        let travel = max(simd_distance(buttonRest(e, side: side), origin), 1)
        let along = simd_distance(button.pos.value, origin) / travel
        return ButtonMark(
            center: button.pos.value, scale: button.radius.value / tuning.bubbleRadius,
            tint: clamp01(button.tint.value), opacity: smooth01((along - 0.6) / 0.3)
        )
    }

    /// The cutout a button sits in: centered on the button, wider than it by the gap, and
    /// opening from the corner as the button comes out.
    private func cutout(for button: PanelButton, in e: EditorState, side: Double) -> Blob.Cutout? {
        let out = clamp01(button.out.value)
        guard e.shape.notched, out > 0.002 else { return nil }
        let corner = e.pos.value + V2(side * e.halfW.value, e.halfH.value)
        let rest = buttonRest(e, side: side)
        let lean = button.shown ? button.pos.target - rest : V2(0, 0)
        return Blob.Cutout(center: corner + (rest - corner) * out + lean * out, radius: (max(button.radius.value, tuning.bubbleRadius) + Self.panelButtonGap) * out)
    }

    func editorBlobs(into out: inout [Blob]) {
        guard let e = config.editor else { return }
        let hw = e.halfW.value
        let hh = e.halfH.value
        guard hw > 0.3, hh > 0.3 else { return }
        let open = clamp01(e.open.value)
        var panel = Blob(center: e.pos.value, half: V2(hw, hh), corner: min(e.cornerTop.value, hw, hh), tint: clamp01(e.tint.value))
        panel.cornerBottom = min(e.cornerBottom.value, hw, hh)
        panel.firm = open
        panel.cutoutLeft = cutout(for: e.back, in: e, side: -1)
        panel.cutoutRight = cutout(for: e.save, in: e, side: 1)
        out.append(panel)
        guard !e.dismissed else { return }

        for button in [e.back, e.save] {
            let r = button.radius.value
            guard r > 0.3 else { continue }
            let tint = clamp01(button.tint.value)
            // Soft while it is on its way out, so it draws out of the panel like a drop. Firm
            // once it is out, so the gap around it stays clean.
            let firm = smooth01(button.out.value)
            out.append(Blob(center: button.pos.value, half: V2(r, r), corner: r, tint: tint, firm: firm))
            let tr = r * 0.72 * clamp01(simd_distance(button.tail.value, button.pos.value) / 9)
            if tr > 0.5 {
                out.append(Blob(center: button.tail.value, half: V2(tr, tr), corner: tr, tint: tint, firm: firm))
            }
        }
    }
}
