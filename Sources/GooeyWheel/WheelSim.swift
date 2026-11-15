import Foundation
import simd

final class WheelSim {
    enum Phase { case closed, open, closing }
    enum Mode { case held, sticky }

    var tuning = Tuning()
    var store = WheelStore.temporary()
    private(set) var phase = Phase.closed
    var mode = Mode.sticky
    private(set) var time = 0.0
    var cursor = V2(0, 0)

    /// The open rings, root first. The last one is active.
    private(set) var levels: [Level] = []
    private(set) var dying: [Level] = []
    var bubbles: [Bubble] = []
    var hovered: Int?
    /// The cursor points back at the parent ring.
    var hoverBack = false
    private var nextID = 0
    private var openedAt = 0.0
    private var lastCenter = V2(0, 0)

    // Opening and leaving folders by resting the cursor
    var dwell = 0.0
    /// The folder just returned from. It can't reopen until the cursor has left it.
    private var reopenBlock: BubbleKey?
    /// A ring that opened under the cursor ignores it until it moves.
    var armed = true
    var armOrigin = V2(0, 0)

    /// 0 shows the hub's glyph, 1 shows the hovered action's name.
    private(set) var labelMix = Spring(0, Tuning().fade)
    private(set) var labelTitles = ["", ""]
    private(set) var labelFades = [Spring(0, Tuning().fade), Spring(0, Tuning().fade)]
    private var labelSlot = 0
    private var labelHeld = false

    // The droplet that carries the selection from the hub to a bubble.
    private(set) var dropPos = Spring2(V2(0, 0), Tuning().dropPos)
    private(set) var dropRadius = Spring(0, Tuning().dropSize)
    private(set) var dropTint = Spring(0, Tuning().tint)
    /// The hovered item's color, kept while the droplet drains.
    private(set) var dropColor: SIMD3<Float>?

    // First-launch hint
    var showHint = false
    private(set) var hintPresence = Spring(0, SpringConfig(k: 300, c: 26))
    var hintHalfWidth = 80.0

    /// Everything that exists only while the wheel is being rearranged.
    var config = ConfigState()

    var labelWidth: (String) -> Double = { _ in 60 }
    var clampCenter: (V2) -> V2 = { $0 }
    var onHover: (() -> Void)?
    var onSelect: ((WheelItem) -> Void)?
    /// One of a picker's choices was made and the wheel is closing.
    var onChoose: ((LiveChoice, WheelItem) -> Void)?
    /// A ring opened from a bubble: a folder, a picker, a slider's bar, or an item's edit options.
    var onEnter: (() -> Void)?
    /// The active ring closed back to its parent.
    var onBack: (() -> Void)?
    /// Something chosen can't be done here.
    var onRefuse: (() -> Void)?

    // In-item controls
    /// Where the state of items' actions comes from.
    weak var controls: ControlSource?
    var liveStates: [UUID: LiveState] = [:]
    /// The bar a slider has turned into, while it is open.
    var barDrive: BarDrive?
    /// Part of a scroll not yet a whole step of a stepper.
    var scrollCarry = 0.0
    /// When to read pickers' choices and items' states again.
    var pendingRefresh: Double?
    /// When each slider was last changed from here.
    var adjustedAt: [UUID: Double] = [:]
    private var liveRefreshAt = 0.0
    /// The wheel's contents changed, or a change was refused.
    var onEdit: ((EditFeedback) -> Void)?
    /// A panel started to open, its save button was pressed, and it started to close.
    var onEditorOpen: ((EditorRequest) -> Void)?
    var onEditorSave: (() -> Void)?
    var onEditorClose: (() -> Void)?
    /// Looks up a named place inside the open panel, for the demo's cursor.
    var panelPoint: ((String) -> V2?)?
    /// Keeps a panel of the given half size on screen.
    var clampPanel: (V2, V2) -> V2 = { center, _ in center }

    var activeLevel: Level? { levels.last }
    var allLevels: [Level] { dying + levels }
    var center: V2 { levels.last?.center ?? lastCenter }
    /// What the goo's view is centered on: the wheel, or the panel that is open over it.
    var viewCenter: V2 { config.editor?.center ?? center }
    var hubPosition: V2 { levels.last?.hubPos.value ?? lastCenter }

    /// 1 while a bubble is in place, falling to 0 over the first moments of its retreat.
    /// Icons also fade as their ring shrinks into the background.
    func iconFade(_ b: Bubble) -> Double {
        let ring = smooth01((b.level.scale.value - 0.6) / 0.3)
        guard b.leaving, time >= b.leaveAt else { return ring }
        return ring * (1 - smooth01((time - b.leaveAt) / 0.07))
    }

    // MARK: Lifecycle

    /// `formed` opens with the hub already at its size and place, for a wheel that takes over
    /// from a hub something else has drawn on the same spot.
    func open(center c: V2, cursor cur: V2, mode m: Mode, hint: Bool, formed: Bool = false) {
        let t = tuning
        // Reopening next to a wheel that's still closing lets the old one finish draining.
        let continuing = phase == .closing && simd_distance(hubPosition, c) < 150
        if continuing {
            for level in levels { level.role = .dying }
            dying.append(contentsOf: levels)
        } else {
            bubbles.removeAll()
            dying.removeAll()
            dropPos.snap(cur)
            dropRadius.snap(0)
            dropTint.snap(0)
            hintPresence.snap(0)
        }
        levels.removeAll()
        resetLabel()

        mode = m
        cursor = cur
        phase = .open
        openedAt = time
        hovered = nil
        hoverBack = false
        showHint = hint
        labelHeld = false
        dwell = 0
        reopenBlock = nil
        armed = true
        dropPos.config = t.dropPos
        dropRadius.config = t.dropSize
        config = ConfigState()

        barDrive = nil
        scrollCarry = 0
        pendingRefresh = nil

        nextID += 1
        let root = Level(id: nextID, kind: .ring(.root), entries: entries(for: .ring(.root)), symbol: nil, color: nil, center: c, tuning: t)
        if formed {
            root.hubHalfW.snap(t.hubRadius)
            root.hubHalfH.snap(t.hubRadius)
            root.hubPos.snap(c + Self.hubLean(cursor: cur, center: c))
        }
        levels.append(root)
        lastCenter = c
        spawn(root, delay: 0.02)
        refreshLive()
        liveRefreshAt = time + 0.5
    }

    /// How far a hub leans toward the cursor.
    static func hubLean(cursor: V2, center: V2) -> V2 {
        clampLength((cursor - center) * 0.045, 4)
    }

    func dismiss() {
        guard phase == .open else { return }
        endConfiguration()
        phase = .closing
        hovered = nil
        hoverBack = false
        for level in levels { retreat(level) }
    }

    /// The summon key came up. Releasing over an item picks it, a quick tap leaves the wheel open.
    /// `missed` is a release the mouse never reported, recovered later, so when the button came
    /// up isn't known. It's taken as a tap.
    func triggerReleased(missed: Bool = false) {
        guard phase == .open, mode == .held else { return }
        if missed {
            mode = .sticky
            return
        }
        refreshHover()
        if hoverBack {
            mode = .sticky
            back()
        } else if let b = hoveredBubble {
            if b.entry.opens {
                mode = .sticky
                enter(b)
            } else {
                select(b)
            }
        } else if levels.last?.isControl == true {
            // Letting go ends the adjustment and closes the wheel.
            dismiss()
        } else if time - openedAt < tuning.pinTapDuration {
            mode = .sticky
        } else {
            dismiss()
        }
    }

    func click() {
        guard phase == .open, let level = levels.last else { return }
        refreshHover()
        if level.isControl {
            // A bar is done with by clicking anywhere but the parent ring.
            if hoverBack { back() } else { dismiss() }
        } else if hoverBack {
            back()
        } else if let b = hoveredBubble {
            if b.entry.opens {
                enter(b)
            } else if b.entry.control == .slider, isAvailable(b) {
                // Pressing on a slider opens its bar under the button: dragging adjusts it and
                // letting go closes it again. A press without a drag leaves it open.
                openBar(b, springLoaded: true)
            } else {
                select(b)
            }
        } else if simd_distance(cursor, level.center) < tuning.deadZoneEnter + 8, levels.count > 1 {
            back()
        } else {
            dismiss()
        }
    }

    func escape() {
        guard phase == .open else { return }
        if config.active {
            escapeConfiguration()
        } else if levels.count > 1 {
            back()
        } else {
            dismiss()
        }
    }

    // MARK: Navigation

    var hoveredBubble: Bubble? {
        guard phase == .open, let h = hovered else { return nil }
        return currentBubble(h)
    }

    func currentBubble(_ slot: Int) -> Bubble? {
        guard let level = levels.last else { return nil }
        return bubbles.first { $0.level === level && $0.slot == slot && !$0.leaving }
    }

    func currentBubble(_ key: BubbleKey) -> Bubble? {
        guard let level = levels.last else { return nil }
        return bubbles.first { $0.level === level && $0.key == key && !$0.leaving }
    }

    private func select(_ b: Bubble) {
        if b.entry.choice != nil {
            choose(b)
            return
        }
        guard let item = b.entry.item else { return }
        guard isAvailable(b) else {
            refuse(b)
            return
        }
        switch b.entry.control {
        case .slider?:
            mode = .sticky
            openBar(b, springLoaded: false)
            return
        case .readout?:
            // There is nothing to do, only something to read.
            b.radius.velocity += 200
            onHover?()
            return
        default:
            break
        }
        if item.actionID == WheelActions.customize {
            b.radius.velocity += 240
            onHover?()
            enterConfiguration()
            return
        }
        onSelect?(item)
        b.radius.velocity += 240
        closeAfterChoosing(b)
    }

    /// The wheel closes around a chosen bubble, which holds its color a moment longer.
    func closeAfterChoosing(_ b: Bubble) {
        phase = .closing
        labelHeld = true
        hovered = nil
        hoverBack = false
        for level in levels {
            if level === b.level {
                retreat(level, selected: b, hold: 0.13, hubDelay: 0.24)
            } else {
                retreat(level)
            }
        }
    }

    /// Opens a new ring centered on a bubble: a folder's items, or the edit options for the
    /// bubble's item. The bubble becomes the new hub where it stands, and the ring it came from
    /// shrinks behind it.
    func enter(_ b: Bubble, editing: Bool = false) {
        guard let item = b.entry.item else { return }
        if editing {
            enter(b, as: .edit(item.id))
        } else if item.isFolder {
            enter(b, as: .ring(.folder(item.id)))
        } else if b.entry.control == .picker {
            guard !entries(for: .picker(item.id)).isEmpty else {
                refuse(b)
                return
            }
            enter(b, as: .picker(item.id))
        }
    }

    /// Opens a level of `kind` from a bubble. A bar is placed by its caller.
    func enter(_ b: Bubble, as kind: Level.Kind, center: V2? = nil) {
        guard let parent = levels.last, let item = b.entry.item else { return }
        let t = tuning
        let editing = kind == .edit(item.id)
        let isBar: Bool
        if case .control = kind { isBar = true } else { isBar = false }
        let phi = parent.angle(b.slot)
        var home = center ?? parent.center + t.ringRadius * V2(cos(phi), sin(phi))

        // If the new ring would run off the screen, slide the whole wheel over.
        let shift = isBar ? V2(0, 0) : clampCenter(home) - home
        if simd_length(shift) > 0.5 {
            for level in levels { level.center += shift }
            home += shift
        }

        if levels.count >= 2 { bury(levels[levels.count - 2]) }
        parent.role = .ghost
        parent.openKey = b.key
        parent.hubHalfW.config = t.hubClose
        parent.hubHalfH.config = t.hubClose

        nextID += 1
        let child = Level(id: nextID, kind: kind, entries: entries(for: kind), symbol: symbol(for: b), color: item.color, center: home, tuning: t)
        if !isBar {
            child.arcMid = phi
            child.arcLimit = t.childArc
            child.reversed = cos(phi) < -0.01
        }
        // The hub starts inside the bubble, small enough not to swell it, and takes over
        // while the bubble itself retreats to its place in the shrunken ring.
        child.hubPos.snap(b.pos.value)
        child.hubPos.velocity = b.pos.velocity
        child.hubHalfW.snap(isBar ? max(b.radius.value, 16) : editing ? 20 : 16)
        child.hubHalfH.snap(isBar ? max(b.radius.value, 16) : editing ? 20 : 16)
        // In normal use the bubble is already filled when it opens. While configuring it may not be.
        child.hubTint.snap(config.active ? clamp01(b.tint.value) : isBar ? 0 : 1)
        levels.append(child)
        lastCenter = home

        hovered = nil
        hoverBack = false
        dwell = 0
        reopenBlock = nil
        armed = false
        armOrigin = cursor
        resetLabel()
        adoptDragged(into: child)
        spawn(child, delay: 0.05)
        // The new ring's items show their state from their first frame.
        refreshLive()
        onEnter?()
    }

    func back() {
        guard levels.count >= 2 else { return }
        let t = tuning
        let child = levels.removeLast()
        child.role = .dying
        if child.isControl {
            // A bar flows back to its bubble's place and gives way to the bubble there.
            barDrive = nil
            child.center = child.barHome
            child.retreating = true
            child.hubCloseAt = time + 0.12
            child.hubHalfW.config = t.hubClose
            child.hubHalfH.config = t.hubClose
        } else {
            retreat(child, hubDelay: 0)
        }
        dying.append(child)

        let parent = levels[levels.count - 1]
        parent.role = .active
        reopenBlock = parent.openKey
        parent.openKey = nil
        parent.hubHalfW.config = t.hubSize
        parent.hubHalfH.config = t.hubSize
        lastCenter = parent.center
        if levels.count >= 2 { resurrect(levels[levels.count - 2]) }

        hovered = nil
        hoverBack = false
        dwell = 0
        // After a bar the cursor is wherever the adjustment left it. The ring waits for it to move.
        armed = !child.isControl
        armOrigin = cursor
        resetLabel()
        onBack?()
    }

    func bury(_ level: Level) {
        level.role = .buried
        retreat(level)
    }

    func resurrect(_ level: Level) {
        let t = tuning
        level.role = .ghost
        level.retreating = false
        level.hubClosing = false
        level.hubHalfW.snap(0)
        level.hubHalfH.snap(0)
        level.hubHalfW.config = t.hubMorph
        level.hubHalfH.config = t.hubMorph
        level.scale.snap(t.parentScale)
        level.alpha.snap(t.parentAlpha)
        spawn(level, delay: 0)
    }

    func spawn(_ level: Level, delay: Double) {
        for (i, entry) in level.entries.enumerated() where !isDragged(entry.key) && !isEditorAnchor(entry.key, in: level) {
            addBubble(entry, slot: i, level: level, at: time + delay + Double(i) * tuning.stagger)
        }
    }

    @discardableResult
    func addBubble(_ entry: Entry, slot: Int, level: Level, at activateAt: Double) -> Bubble {
        nextID += 1
        let b = Bubble(id: nextID, entry: entry, slot: slot, level: level, at: level.hubPos.value, activateAt: activateAt, tuning: tuning)
        bubbles.append(b)
        return b
    }

    /// Sends a level's bubbles back into its hub, which then closes.
    func retreat(_ level: Level, selected: Bubble? = nil, hold: Double = 0, hubDelay: Double = 0.03) {
        level.retreating = true
        level.hubCloseAt = time + hubDelay
        bubbles.removeAll { $0.level === level && !$0.leaving && !$0.active }
        for b in bubbles where b.level === level && !b.leaving {
            b.leaving = true
            if b === selected {
                b.selected = true
                b.leaveAt = time + hold
            } else {
                let order = selected.map { abs(ringDelta(b.slot, $0.slot, b.count)) } ?? b.slot
                b.leaveAt = time + Double(order) * (tuning.stagger > 0 ? 0.006 : 0)
            }
        }
    }

    /// Signed number of slots from `from` to `slot` going the short way around.
    func ringDelta(_ slot: Int, _ from: Int, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        var d = (slot - from) % count
        if d > count / 2 { d -= count }
        if d < -(count / 2) { d += count }
        if count % 2 == 0, abs(d) == count / 2 { return count / 2 }
        return d
    }

    // MARK: Contents

    func entries(for kind: Level.Kind) -> [Entry] {
        switch kind {
        case .ring(let container):
            return displayItems(in: container).map(Entry.item)
        case .edit(let id):
            return store.item(id).map { EditOption.options(for: $0).map(Entry.option) } ?? []
        case .picker(let id):
            guard let item = store.item(id), let controls else { return [] }
            // A ring of a folder's size at most.
            return controls.choices(item).prefix(WheelLimits.folderItems).map { Entry.choice(id, $0) }
        case .control:
            return []
        }
    }

    /// Whether the folder or item a level was opened from is still where it was.
    private func exists(_ level: Level, under parent: Level?) -> Bool {
        switch level.kind {
        case .ring(.root):
            return true
        case .ring(.folder(let id)):
            return store.item(id)?.isFolder == true
        case .edit(let id), .picker(let id), .control(let id):
            return store.location(of: id)?.container == parent?.container
        }
    }

    /// Brings every ring in line with the store after a change. Rings whose folder or item
    /// is gone close, new items drip out of the hub, removed ones drain into it, and the rest
    /// slide to their new places.
    func syncLevels() {
        while levels.count > 1, !exists(levels[levels.count - 1], under: levels[levels.count - 2]) {
            back()
        }
        for level in levels {
            level.entries = entries(for: level.kind)
            switch level.kind {
            case .ring(.folder(let id)), .edit(let id), .picker(let id), .control(let id):
                level.symbol = store.item(id)?.symbol
                level.color = store.item(id)?.color
            case .ring(.root):
                break
            }
            reconcile(level)
        }
        hovered = nil
        hoverBack = false
        reopenBlock = nil
    }

    func reconcile(_ level: Level) {
        var present = Set<BubbleKey>()
        for b in bubbles where b.level === level && !b.leaving {
            if let slot = level.slot(of: b.key) {
                b.slot = slot
                b.entry = level.entries[slot]
                present.insert(b.key)
            } else if b.active {
                b.leaving = true
                b.leaveAt = time
                // A dot in a shrunken ring drains at the size it has, even as its ring grows back.
                b.leaveRadius = b.radius.value
            }
        }
        bubbles.removeAll { $0.level === level && !$0.leaving && !$0.active && level.slot(of: $0.key) == nil }
        // A ring that has stepped aside for an editing panel comes back as a whole later.
        guard level.role == .active || level.role == .ghost, !level.retreating else { return }
        for (slot, entry) in level.entries.enumerated() where !present.contains(entry.key) {
            let between = angleBetweenNeighbors(of: slot, in: level)
            // Its neighbors get a head start, so it comes out into a gap that is already opening.
            let b = addBubble(entry, slot: slot, level: level, at: time + (between == nil || tuning.stagger == 0 ? 0 : 0.07))
            if let between { b.angle.snap(between) }
        }
    }

    /// Where a bubble joining a ring should come out: halfway between the bubbles that will
    /// be its neighbors, which then part to make room. Nil when it has no neighbor on one side.
    private func angleBetweenNeighbors(of slot: Int, in level: Level) -> Double? {
        let n = level.count
        guard n > 2 else { return nil }
        func settled(_ index: Int) -> Bubble? {
            let wrapped = level.arcMid == nil ? (index + n) % n : index
            return bubbles.first { $0.level === level && $0.slot == wrapped && $0.active && !$0.leaving }
        }
        guard let before = settled(slot - 1), let after = settled(slot + 1) else { return nil }
        var gap = after.angle.value - before.angle.value
        if level.arcMid == nil {
            gap = gap.truncatingRemainder(dividingBy: 2 * .pi)
            if gap <= 0 { gap += 2 * .pi }
        }
        return before.angle.value + gap / 2
    }

    // MARK: Hover

    func refreshHover() {
        if config.active {
            refreshConfigurationHover()
            return
        }
        let t = tuning
        if phase == .open, let level = levels.last, level.isControl {
            // A bar has nothing to point at. Only the parent ring, to go back.
            setHover(nil, back: overParentRing(cursor))
            return
        }
        var next: Int?
        var nextBack = false
        if phase == .open, let level = levels.last, level.count > 0 {
            let v = cursor - level.center
            let dist = simd_length(v)
            if !armed, dist < t.deadZoneExit || simd_distance(cursor, armOrigin) > 12 {
                armed = true
            }
            let inner = (hovered == nil && !hoverBack) ? t.deadZoneEnter : t.deadZoneExit
            if armed, dist >= inner, mode == .held || dist <= t.outerLimit {
                switch level.pick(angle: atan2(v.y, v.x), current: hovered, currentBack: hoverBack) {
                case .slot(let slot): next = slot
                case .back: nextBack = dist >= (hoverBack ? t.backZoneExit : t.backZoneEnter)
                }
            }
        }
        setHover(next, back: nextBack)
    }

    func setHover(_ next: Int?, back nextBack: Bool) {
        guard next != hovered || nextBack != hoverBack else { return }
        hovered = next
        hoverBack = nextBack
        dwell = 0
        scrollCarry = 0
        if nextBack {
            setLabel("Back")
            onHover?()
        } else if let h = next, let b = currentBubble(h) {
            setLabel(labelText(for: b))
            dropColor = bubbleColor(b)
            onHover?()
        } else {
            refreshLabel()
        }
    }

    private func resetLabel() {
        labelMix.snap(0)
        labelFades[0].snap(0)
        labelFades[1].snap(0)
    }

    /// Shows `title` in the hub. `instant` replaces the text in place when only the reading
    /// after the name changed, as a slider's level does while it moves.
    func setLabel(_ text: String, instant: Bool = false) {
        let title = wrapLabel(text)
        guard labelTitles[labelSlot] != title || labelFades[labelSlot].target < 1 else { return }
        let name = { (text: String) in
            text.components(separatedBy: " · ").first?.components(separatedBy: "\n").first ?? text
        }
        if instant, labelFades[labelSlot].target >= 1, name(labelTitles[labelSlot]) == name(title) {
            labelTitles[labelSlot] = title
            return
        }
        if labelMix.value < 0.05 {
            labelTitles[labelSlot] = title
            labelFades[labelSlot].snap(1)
            labelFades[1 - labelSlot].snap(0)
        } else {
            labelFades[labelSlot].target = 0
            labelSlot = 1 - labelSlot
            labelTitles[labelSlot] = title
            labelFades[labelSlot].target = 1
        }
    }

    /// 0 to 1 while the cursor rests on the hovered folder, for the bud that swells before it opens.
    var folderDwellProgress: Double {
        guard !config.active, let b = hoveredBubble, b.entry.opens else { return 0 }
        return clamp01(dwell / tuning.folderDwell)
    }

    /// Opens a folder the cursor rests on, and goes back when it rests on the parent ring.
    private func updateDwell(_ dt: Double) {
        guard phase == .open, !config.active, let level = levels.last else { return }
        let t = tuning

        if let blocked = reopenBlock {
            if let slot = level.slot(of: blocked) {
                let a = level.angle(slot)
                let home = level.center + t.ringRadius * V2(cos(a), sin(a))
                if simd_distance(cursor, home) > t.bubbleRadius + 12 { reopenBlock = nil }
            } else {
                reopenBlock = nil
            }
        }

        if let b = hoveredBubble, b.entry.opens, reopenBlock != b.key {
            // Measured against the bubble's resting place, so a cursor passing along the inside
            // of the ring doesn't open a folder that leaned toward it.
            let a = level.angle(b.slot)
            let home = level.center + t.ringRadius * V2(cos(a), sin(a))
            if simd_distance(cursor, home) < t.bubbleRadius {
                dwell += dt
                if dwell >= t.folderDwell { enter(b) }
                return
            }
        } else if hoverBack, levels.count >= 2 {
            let parent = levels[levels.count - 2]
            let reach = t.ringRadius * t.parentScale + 22
            if simd_distance(cursor, parent.center) < reach {
                dwell += dt
                if dwell >= t.backDwell { back() }
                return
            }
        }
        dwell = 0
    }

    // MARK: Step

    func step(_ dt: Double) {
        guard phase != .closed else { return }
        time += dt
        refreshHover()
        updateDwell(dt)
        stepConfiguration(dt)
        stepEditor(dt)
        stepBar()
        if phase == .open, time >= liveRefreshAt || pendingRefresh.map({ time >= $0 }) == true {
            if pendingRefresh != nil { refreshChoices() }
            pendingRefresh = nil
            refreshLive()
            liveRefreshAt = time + 0.5
        }
        let t = tuning
        let ring = t.ringRadius
        let active = phase == .open ? levels.last : nil
        let pointing = hovered != nil || hoverBack
        // A picker's hub reads out what it is about, such as the track playing.
        let readsOut = levels.last.map { level -> Bool in
            guard case .picker(let id) = level.kind else { return false }
            return live(store.item(id))?.detail?.isEmpty == false
        } ?? false
        let showLabel = (phase == .open && (pointing || config.holdsLabel || readsOut) && showsHubLabel && active?.isControl != true)
            || (phase == .closing && labelHeld)

        labelMix.target = showLabel ? 1 : 0
        labelMix.step(dt)
        labelFades[0].step(dt)
        labelFades[1].step(dt)

        // Hubs
        for level in allLevels {
            switch level.role {
            case .active:
                level.scale.target = 1
                level.alpha.target = 1
            case .ghost:
                level.scale.target = t.parentScale * (hoverBack ? 1.14 : 1)
                level.alpha.target = hoverBack ? 0.92 : t.parentAlpha
            case .buried, .dying:
                break
            }
            level.scale.step(dt)
            level.alpha.step(dt)

            let lean = level === active && !level.isControl ? Self.hubLean(cursor: cursor, center: level.center) : V2(0, 0)
            level.hubPos.target = level.center + lean
            level.hubPos.step(dt)
            let hubP = level.hubPos.value

            if level.retreating, !level.hubClosing, time >= level.hubCloseAt,
               bubbles.allSatisfy({ $0.level !== level || $0.sink != nil || simd_distance($0.pos.value, hubP) < 38 }) {
                level.hubClosing = true
                level.hubHalfW.config = t.hubClose
                level.hubHalfH.config = t.hubClose
            }
            if level.hubClosing {
                // Aim below zero: a spring only approaches its target, and a speck would linger at the end.
                level.hubHalfW.target = -4
                level.hubHalfH.target = -4
            } else if level.isControl {
                if let id = level.itemID, let value = live(store.item(id))?.level { level.barShown.target = value }
                // While the cursor drives the fill it keeps up exactly; jumps from a scroll glide.
                if barDrive?.engaged == true, level === levels.last, abs(level.barShown.target - level.barShown.value) < 0.03 {
                    level.barShown.snap(level.barShown.target)
                }
                level.barShown.step(dt)
                if level.role == .dying || level !== levels.last {
                    level.barStretch.target = 0
                    level.barGrow.target = 0
                }
                level.barStretch.step(dt)
                level.barGrow.step(dt)
                let half = barTarget(level)
                level.hubHalfW.target = half.x
                level.hubHalfH.target = half.y
            } else if level.role == .ghost {
                level.hubHalfW.target = t.hubRadius * level.scale.value
                level.hubHalfH.target = t.hubRadius * level.scale.value
            } else if showLabel, level === levels.last {
                level.hubHalfW.config = t.hubMorph
                level.hubHalfH.config = t.hubMorph
                let label = labelSize(labelTitles[labelSlot])
                level.hubHalfW.target = max(t.pillHalfHeight + 6, label.width / 2 + t.pillPadding)
                // A second line makes the pill taller by one line.
                level.hubHalfH.target = t.pillHalfHeight + Double(label.lines - 1) * 8.5
            } else {
                let r = level.hubRadius(t) + (level === active ? hubSwell : 0)
                level.hubHalfW.target = r
                level.hubHalfH.target = r
            }
            level.hubHalfW.step(dt)
            level.hubHalfH.step(dt)
            level.hubTint.target = level === active ? hubFill : 0
            level.hubTint.step(dt)
        }

        // Bubbles
        for b in bubbles {
            let level = b.level
            let hubP = level.hubPos.value
            if !b.active {
                b.pos.snap(hubP)
                b.tail.snap(hubP)
                guard time >= b.activateAt else { continue }
                b.active = true
                b.radius.snap(t.bubbleRadius * 0.45 * level.bubbleScale(t))
                // A slider's rim fills to its level as the bubble comes out.
                if b.entry.control == .slider, let value = live(b.entry.item)?.level {
                    b.levelShown.snap(0)
                    b.levelShown.target = value
                    b.levelKnown = true
                }
            }
            let dist = simd_distance(b.pos.value, hubP)
            if b.leaving, time >= b.leaveAt {
                // A bubble that was dropped onto another drains into it. The rest go to the hub.
                let drain = b.sink?.pos.value ?? hubP
                let left = simd_distance(b.pos.value, drain)
                b.pos.config = t.retractPos
                b.pos.target = drain
                b.radius.config = t.radiusLeave
                let full = t.bubbleRadius * level.bubbleScale(t) * clamp01(left / (ring * 0.9))
                b.radius.target = left < 5 ? -3 : min(full, b.leaveRadius ?? full)
                b.tint.target = b.selected ? 1 : 0
                b.lift.target = 0
                b.push.target = 0
            } else if isDragged(b) {
                stepDragged(b)
            } else {
                let s = level.scale.value
                let isHovered = b.leaving ? b.selected : (level === active && hovered == b.slot)
                let isOpen = level.openKey == b.key
                let isTarget = isDropTarget(b)
                let slotAngle = level.angle(b.slot)
                // An arc never wraps, so its bubbles don't take a shortcut across the parent ring.
                b.angle.target = level.arcMid == nil ? b.angle.value + wrapAngle(slotAngle - b.angle.value) : slotAngle
                b.angle.step(dt)
                let angle = b.angle.value + b.push.value
                var home = level.center + ring * s * V2(cos(angle), sin(angle))
                if isHovered, !b.leaving {
                    home += clampLength((cursor - home) * 0.22, 7)
                }
                b.pos.target = home
                // Bubbles grow as they leave the hub, so the hub doesn't balloon while it holds them.
                let emerge = max(0.5, clamp01(dist / (ring * 0.5 * max(s, 0.05))))
                let front = level.role == .active
                b.pos.config = front ? t.enterPos : t.ghostTrack
                b.radius.config = front ? (isHovered || isTarget ? t.radiusHover : t.radiusRest) : t.ghostTrack
                let size = isTarget ? dropTargetRadius : (isHovered ? hoverRadius(b) : t.bubbleRadius * pressScale(b))
                b.radius.target = size * level.bubbleScale(t) * emerge
                b.tint.target = (isHovered && fillsOnHover(b)) || isOpen || isTarget ? 1 : 0
                b.lift.target = isHovered && !fillsOnHover(b) ? 1 : 0
                b.push.target = b.leaving ? 0 : pushAngle(for: b, active: active)
            }
            b.pos.step(dt)
            b.tail.target = b.pos.value
            b.tail.step(dt)
            b.radius.step(dt)
            b.tint.step(dt)
            b.lift.step(dt)
            b.push.step(dt)
            b.levelShown.step(dt)
            b.shake.step(dt)
            stepBadge(b, dt)
        }
        bubbles.removeAll { b in
            guard b.leaving, b.active, time >= b.leaveAt else { return false }
            let dist = simd_distance(b.pos.value, b.sink?.pos.value ?? b.level.hubPos.value)
            return (b.radius.value < 0.6 && dist < 10) || time > b.leaveAt + 0.7
        }
        dying.removeAll { level in
            level.hubClosing && level.hubGone && !bubbles.contains { $0.level === level }
        }

        // Droplet
        if let level = active, !editorIsOpen, !level.isControl {
            let v = cursor - level.center
            let d = simd_length(v)
            let hubHalf = V2(max(level.hubHalfW.value, 0), max(level.hubHalfH.value, 0))
            if pointing, showsDroplet, d > 0 {
                // The droplet goes out as far as the cursor, and never rests against the hub's
                // label: this near the hub it would sit on the label's edge as a bump.
                let dir = v / d
                let edge = min(hubHalf.x / max(abs(dir.x), 1e-6), hubHalf.y / max(abs(dir.y), 1e-6))
                let clear = min(edge + t.dropRadius + 20, ring)
                dropPos.target = level.center + dir * max(min(d, ring), clear)
                dropRadius.target = t.dropRadius
                dropTint.target = hoverBack ? 0 : 1
            } else {
                // At rest it stays inside the hub, whatever shape the hub has taken.
                let room = simd_max(hubHalf - V2(8, 8), V2(0, 0))
                dropPos.target = level.center + simd_clamp(clampLength(v, max(t.hubRadius - 11, 0)), -room, room)
                // Under a label there is no room for it: even inside, it would raise a bump
                // in the label's edge.
                dropRadius.target = showLabel ? -3 : 5
                dropTint.target = 0
            }
        } else {
            dropPos.target = hubPosition
            dropRadius.target = -3
            dropTint.target = labelHeld ? 1 : 0
        }
        dropPos.step(dt)
        dropRadius.step(dt)
        dropTint.step(dt)

        hintPresence.target = (showHint && phase == .open && levels.count == 1 && time - openedAt > 0.4) ? 1 : 0
        hintPresence.step(dt)

        if phase == .closing, dying.isEmpty, bubbles.isEmpty, config.editor == nil,
           levels.allSatisfy({ $0.hubClosing && $0.hubGone }) {
            phase = .closed
            levels.removeAll()
        }
    }

    private func pushAngle(for b: Bubble, active: Level?) -> Double {
        guard b.level === active, let h = hovered, h != b.slot else { return 0 }
        // On an arc the ends aren't neighbors, so count slots directly.
        let delta = b.level.arcMid == nil ? ringDelta(b.slot, h, b.count) : b.slot - h
        let sign: Double = (delta > 0) != b.level.reversed ? 1 : -1
        switch abs(delta) {
        case 1: return sign * 0.07
        case 2 where b.count > 4: return sign * 0.025
        default: return 0
        }
    }

    var hintCenter: V2 { (levels.first?.center ?? lastCenter) + V2(0, tuning.hintOffset) }
}
