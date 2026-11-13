import Foundation
import simd

/// What the parent ring does while one of its folders is open.
enum ParentStyle: String {
    /// It shrinks and dims in place, and hovering it goes back.
    case shrink
    /// It disappears.
    case hide
}

struct Tuning {
    var ringRadius = 108.0
    var bubbleRadius = 30.0
    var hoverRadius = 35.5
    var hubRadius = 26.0
    var pillHalfHeight = 16.0
    var pillPadding = 14.0
    /// The cursor has to leave this radius to start hovering, and come back inside the smaller one to stop.
    var deadZoneEnter = 25.0
    var deadZoneExit = 19.0
    /// Pointing back at the parent ring only counts this far from a folder's hub. A folder opens
    /// with the cursor already on its inner side, and that shouldn't read as heading back.
    var backZoneEnter = 44.0
    var backZoneExit = 38.0
    /// Past this distance a sticky wheel treats the cursor as outside.
    var outerLimit = 235.0
    /// A press shorter than this pins the wheel open. A longer one closes it on release.
    var pinTapDuration = 0.4
    var dropRadius = 11.0
    var stagger = 0.016
    var hintOffset = 190.0
    var hintHalfHeight = 14.0

    // Folders
    /// Size and opacity of a parent ring while its folder is open.
    var parentScale = 0.38
    var parentAlpha = 0.55
    /// Bubbles in a shrunken ring shrink further than the ring does, so they stay separate dots
    /// instead of merging into one shape.
    var parentDotScale = 0.58
    /// A folder's ring spans this arc, facing away from its parent. The rest is the way back.
    var childArc = 244.0 * .pi / 180
    /// Seconds the cursor rests on a folder before it opens, and on the parent ring before it returns.
    var folderDwell = 0.12
    var backDwell = 0.12

    // Springs. Stiffness and damping at mass 1, the same units as Gooey's presets.
    var enterPos = SpringConfig(k: 340, c: 22)
    var retractPos = SpringConfig(k: 700, c: 50)
    var radiusRest = SpringConfig(k: 300, c: 25)
    var radiusHover = SpringConfig(k: 520, c: 25)
    var radiusLeave = SpringConfig.critical(k: 900)
    var tint = SpringConfig.critical(k: 700)
    var push = SpringConfig(k: 300, c: 26)
    var hubPos = SpringConfig(k: 300, c: 24)
    var hubSize = SpringConfig(k: 520, c: 30)
    var hubMorph = SpringConfig(k: 400, c: 26)
    /// How loosely each bubble's tail follows it. The lag is what draws a bubble out into a teardrop.
    var tailPos = SpringConfig(k: 1500, c: 42)
    var hubClose = SpringConfig.critical(k: 520)
    var levelScale = SpringConfig.critical(k: 300)
    /// Bubbles of a shrunken ring follow its size closely and without bounce. Any overshoot
    /// makes the small dots merge and separate, which reads as a flash.
    var ghostTrack = SpringConfig.critical(k: 1600)
    var levelAlpha = SpringConfig.critical(k: 400)
    var dropPos = SpringConfig(k: 1300, c: 50)
    var dropSize = SpringConfig(k: 400, c: 26)
    var fade = SpringConfig.critical(k: 900)

    /// Critically damped everywhere and no stagger, for the Reduce Motion setting.
    static var reducedMotion: Tuning {
        var t = Tuning()
        t.stagger = 0
        t.enterPos = .critical(k: 600)
        t.radiusRest = .critical(k: 600)
        t.radiusHover = .critical(k: 600)
        t.push = .critical(k: 600)
        t.hubPos = .critical(k: 600)
        t.hubSize = .critical(k: 600)
        t.hubMorph = .critical(k: 600)
        t.tailPos = .critical(k: 900)
        t.levelScale = .critical(k: 600)
        t.dropPos = .critical(k: 1300)
        t.dropSize = .critical(k: 600)
        return t
    }
}

/// One rounded box in the goo field. A circle is a box whose corner radius equals its half size.
struct Blob {
    var center: V2
    var half: V2
    var corner: Double
    /// 0 is the neutral fill, 1 is the accent color.
    var tint: Double
    var alpha: Double = 1
}

/// One ring of the wheel with its hub. The root is a level, and so is every open folder.
final class Level {
    enum Role {
        /// The ring the cursor is choosing from.
        case active
        /// The parent of the active ring, shown small behind it.
        case ghost
        /// An ancestor further up. It has no bubbles until it becomes the ghost again.
        case buried
        /// Left behind by going back or by reopening. It drains and is removed.
        case dying
    }

    enum Pick: Equatable {
        case slot(Int)
        case back
    }

    let id: Int
    let items: [WheelAction]
    /// The folder's symbol, shown in the hub. Nil at the root.
    let symbol: String?
    var center: V2
    /// Direction this ring faces, away from its parent. Nil for a full ring.
    var arcMid: Double?
    var arcSpan = 0.0
    /// Rings that open to the left run counterclockwise so their first item is still on top.
    var reversed = false
    var role = Role.active
    /// The slot of the folder that is open from this ring.
    var openSlot: Int?

    var hubPos: Spring2
    var hubHalfW: Spring
    var hubHalfH: Spring
    var hubTint: Spring
    var scale: Spring
    var alpha: Spring
    var retreating = false
    var hubCloseAt = 0.0
    var hubClosing = false

    init(id: Int, items: [WheelAction], symbol: String?, center: V2, tuning t: Tuning) {
        self.id = id
        self.items = items
        self.symbol = symbol
        self.center = center
        hubPos = Spring2(center, t.hubPos)
        hubHalfW = Spring(0, t.hubSize)
        hubHalfH = Spring(0, t.hubSize)
        hubTint = Spring(0, t.tint)
        scale = Spring(1, t.levelScale)
        alpha = Spring(1, t.levelAlpha)
    }

    var hubGone: Bool { hubHalfW.value < 0.5 || hubHalfH.value < 0.5 }

    /// Scale for this ring's bubbles: equal to `scale` at full size, smaller once shrunk.
    func bubbleScale(_ t: Tuning) -> Double {
        let s = scale.value
        let full = smooth01((s - t.parentScale) / (1 - t.parentScale))
        return s * (t.parentDotScale + (1 - t.parentDotScale) * full)
    }

    private var arcStep: Double { items.count > 1 ? arcSpan / Double(items.count - 1) : 0 }

    func angle(_ slot: Int) -> Double {
        let n = items.count
        guard let mid = arcMid, n > 1 else {
            return -Double.pi / 2 + Double(slot) * 2 * .pi / Double(max(n, 1))
        }
        let index = reversed ? n - 1 - slot : slot
        return mid - arcSpan / 2 + Double(index) * arcStep
    }

    /// The slot the cursor's direction points at, or `.back` when it points at the parent.
    func pick(angle a: Double, current: Int?, currentBack: Bool) -> Pick {
        let n = items.count
        let slice = arcMid == nil ? 2 * Double.pi / Double(n) : arcStep
        // Stay on the current choice until the cursor is clearly past its edge.
        if let h = current, h < n, abs(wrapAngle(a - angle(h))) < slice / 2 + 0.07 {
            return .slot(h)
        }
        guard let mid = arcMid, n > 1 else {
            let raw = Int((wrapAngle(a + .pi / 2) / slice).rounded())
            return .slot(((raw % n) + n) % n)
        }
        let rel = wrapAngle(a - mid)
        let edge = arcSpan / 2 + slice / 2
        if abs(rel) > edge - (currentBack ? 0.07 : 0) { return .back }
        let index = min(max(Int(((rel + arcSpan / 2) / slice).rounded()), 0), n - 1)
        return .slot(reversed ? n - 1 - index : index)
    }
}

final class Bubble {
    let id: Int
    let action: WheelAction
    let slot: Int
    let count: Int
    unowned let level: Level
    var pos: Spring2
    var tail: Spring2
    var radius: Spring
    var tint: Spring
    /// Angular displacement away from the hovered neighbor, in radians.
    var push: Spring
    var activateAt: Double
    var active = false
    var leaving = false
    var leaveAt = 0.0
    var selected = false

    init(id: Int, action: WheelAction, slot: Int, level: Level, at p: V2, activateAt: Double, tuning t: Tuning) {
        self.id = id
        self.action = action
        self.slot = slot
        self.count = level.items.count
        self.level = level
        self.activateAt = activateAt
        pos = Spring2(p, t.enterPos)
        tail = Spring2(p, t.tailPos)
        radius = Spring(0, t.radiusRest)
        tint = Spring(0, t.tint)
        push = Spring(0, t.push)
    }
}

final class WheelSim {
    enum Phase { case closed, open, closing }
    enum Mode { case held, sticky }

    var tuning = Tuning()
    var parentStyle = ParentStyle.shrink
    private(set) var phase = Phase.closed
    private(set) var mode = Mode.sticky
    private(set) var time = 0.0
    var cursor = V2(0, 0)

    /// The open rings, root first. The last one is active.
    private(set) var levels: [Level] = []
    private(set) var dying: [Level] = []
    private(set) var bubbles: [Bubble] = []
    private(set) var hovered: Int?
    /// The cursor points back at the parent ring.
    private(set) var hoverBack = false
    private var nextID = 0
    private var openedAt = 0.0
    private var lastCenter = V2(0, 0)

    // Opening and leaving folders by resting the cursor
    private var dwell = 0.0
    /// The folder just returned from. It can't reopen until the cursor has left it.
    private var reopenBlock: Int?
    /// A ring that opened under the cursor ignores it until it moves.
    private var armed = true
    private var armOrigin = V2(0, 0)

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

    // First-launch hint
    private var showHint = false
    private(set) var hintPresence = Spring(0, SpringConfig(k: 300, c: 26))
    var hintHalfWidth = 80.0

    var labelWidth: (String) -> Double = { _ in 60 }
    var clampCenter: (V2) -> V2 = { $0 }
    var onHover: (() -> Void)?
    var onSelect: ((WheelAction) -> Void)?

    var activeLevel: Level? { levels.last }
    var allLevels: [Level] { dying + levels }
    var center: V2 { levels.last?.center ?? lastCenter }
    var hubPosition: V2 { levels.last?.hubPos.value ?? lastCenter }

    /// 1 while a bubble is in place, falling to 0 over the first moments of its retreat.
    /// Icons also fade as their ring shrinks into the background.
    func iconFade(_ b: Bubble) -> Double {
        let ring = smooth01((b.level.scale.value - 0.6) / 0.3)
        guard b.leaving, time >= b.leaveAt else { return ring }
        return ring * (1 - smooth01((time - b.leaveAt) / 0.07))
    }

    // MARK: Lifecycle

    func open(center c: V2, cursor cur: V2, mode m: Mode, hint: Bool) {
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
        labelMix.snap(0)
        labelFades[0].snap(0)
        labelFades[1].snap(0)

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

        nextID += 1
        let root = Level(id: nextID, items: WheelContent.root, symbol: nil, center: c, tuning: t)
        levels.append(root)
        lastCenter = c
        spawn(root, delay: 0.02)
    }

    func dismiss() {
        guard phase == .open else { return }
        phase = .closing
        hovered = nil
        hoverBack = false
        for level in levels { retreat(level) }
    }

    /// The summon key came up. Releasing over an item picks it, a quick tap leaves the wheel open.
    func triggerReleased() {
        guard phase == .open, mode == .held else { return }
        refreshHover()
        if hoverBack {
            mode = .sticky
            back()
        } else if let b = hoveredBubble {
            if b.action.isFolder {
                mode = .sticky
                enterFolder(b)
            } else {
                select(b)
            }
        } else if time - openedAt < tuning.pinTapDuration {
            mode = .sticky
        } else {
            dismiss()
        }
    }

    func click() {
        guard phase == .open, let level = levels.last else { return }
        refreshHover()
        if hoverBack {
            back()
        } else if let b = hoveredBubble {
            if b.action.isFolder { enterFolder(b) } else { select(b) }
        } else if simd_distance(cursor, level.center) < tuning.deadZoneEnter + 8, levels.count > 1 {
            back()
        } else {
            dismiss()
        }
    }

    func escape() {
        guard phase == .open else { return }
        if levels.count > 1 { back() } else { dismiss() }
    }

    // MARK: Navigation

    private var hoveredBubble: Bubble? {
        guard phase == .open, let h = hovered else { return nil }
        return currentBubble(h)
    }

    private func currentBubble(_ slot: Int) -> Bubble? {
        guard let level = levels.last else { return nil }
        return bubbles.first { $0.level === level && $0.slot == slot && !$0.leaving }
    }

    private func select(_ b: Bubble) {
        onSelect?(b.action)
        b.radius.velocity += 240
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

    /// Opens a folder as a new ring centered on the folder's bubble. The bubble becomes the new
    /// hub where it stands, and the ring it came from shrinks behind it.
    private func enterFolder(_ b: Bubble) {
        guard let parent = levels.last else { return }
        let t = tuning
        let phi = parent.angle(b.slot)
        var home = parent.center + t.ringRadius * V2(cos(phi), sin(phi))

        // If the new ring would run off the screen, slide the whole wheel over.
        let shift = clampCenter(home) - home
        if simd_length(shift) > 0.5 {
            for level in levels { level.center += shift }
            home += shift
        }

        if levels.count >= 2 { bury(levels[levels.count - 2]) }
        parent.role = .ghost
        parent.openSlot = b.slot
        parent.hubHalfW.config = t.hubClose
        parent.hubHalfH.config = t.hubClose

        nextID += 1
        let child = Level(id: nextID, items: b.action.children, symbol: b.action.symbol, center: home, tuning: t)
        if parentStyle == .shrink {
            child.arcMid = phi
            child.arcSpan = t.childArc
            child.reversed = cos(phi) < -0.01
        }
        // The hub starts inside the folder's bubble, small enough not to swell it, and takes over
        // while the bubble itself retreats to its place in the shrunken ring.
        child.hubPos.snap(b.pos.value)
        child.hubPos.velocity = b.pos.velocity
        child.hubHalfW.snap(16)
        child.hubHalfH.snap(16)
        child.hubTint.snap(1)
        levels.append(child)
        lastCenter = home

        hovered = nil
        hoverBack = false
        dwell = 0
        reopenBlock = nil
        armed = false
        armOrigin = cursor
        labelMix.snap(0)
        labelFades[0].snap(0)
        labelFades[1].snap(0)
        spawn(child, delay: 0.05)
    }

    private func back() {
        guard levels.count >= 2 else { return }
        let t = tuning
        let child = levels.removeLast()
        child.role = .dying
        retreat(child, hubDelay: 0)
        dying.append(child)

        let parent = levels[levels.count - 1]
        parent.role = .active
        reopenBlock = parent.openSlot
        parent.openSlot = nil
        parent.hubHalfW.config = t.hubSize
        parent.hubHalfH.config = t.hubSize
        lastCenter = parent.center
        if levels.count >= 2 { resurrect(levels[levels.count - 2]) }

        hovered = nil
        hoverBack = false
        dwell = 0
        armed = true
        labelMix.snap(0)
        labelFades[0].snap(0)
        labelFades[1].snap(0)
    }

    private func bury(_ level: Level) {
        level.role = .buried
        retreat(level)
    }

    private func resurrect(_ level: Level) {
        let t = tuning
        level.role = .ghost
        level.retreating = false
        level.hubClosing = false
        level.hubHalfW.snap(0)
        level.hubHalfH.snap(0)
        level.hubHalfW.config = t.hubMorph
        level.hubHalfH.config = t.hubMorph
        level.scale.snap(parentStyle == .shrink ? t.parentScale : 0)
        level.alpha.snap(parentStyle == .shrink ? t.parentAlpha : 0)
        spawn(level, delay: 0)
    }

    private func spawn(_ level: Level, delay: Double) {
        for (i, action) in level.items.enumerated() {
            nextID += 1
            bubbles.append(Bubble(
                id: nextID, action: action, slot: i, level: level,
                at: level.hubPos.value, activateAt: time + delay + Double(i) * tuning.stagger, tuning: tuning
            ))
        }
    }

    /// Sends a level's bubbles back into its hub, which then closes.
    private func retreat(_ level: Level, selected: Bubble? = nil, hold: Double = 0, hubDelay: Double = 0.03) {
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
    private func ringDelta(_ slot: Int, _ from: Int, _ count: Int) -> Int {
        var d = (slot - from) % count
        if d > count / 2 { d -= count }
        if d < -(count / 2) { d += count }
        if count % 2 == 0, abs(d) == count / 2 { return count / 2 }
        return d
    }

    // MARK: Hover

    func refreshHover() {
        let t = tuning
        var next: Int?
        var nextBack = false
        if phase == .open, let level = levels.last, !level.items.isEmpty {
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
        guard next != hovered || nextBack != hoverBack else { return }
        hovered = next
        hoverBack = nextBack
        dwell = 0
        if nextBack {
            setLabel("Back")
            onHover?()
        } else if let h = next, let b = currentBubble(h) {
            setLabel(b.action.title)
            onHover?()
        }
    }

    private func setLabel(_ title: String) {
        guard labelTitles[labelSlot] != title || labelFades[labelSlot].target < 1 else { return }
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
    private var folderDwellProgress: Double {
        guard let b = hoveredBubble, b.action.isFolder else { return 0 }
        return clamp01(dwell / tuning.folderDwell)
    }

    /// Opens a folder the cursor rests on, and goes back when it rests on the parent ring.
    private func updateDwell(_ dt: Double) {
        guard phase == .open, let level = levels.last else { return }
        let t = tuning

        if let blocked = reopenBlock {
            let a = level.angle(blocked)
            let home = level.center + t.ringRadius * V2(cos(a), sin(a))
            if simd_distance(cursor, home) > t.bubbleRadius + 12 { reopenBlock = nil }
        }

        if let b = hoveredBubble, b.action.isFolder, reopenBlock != b.slot {
            // Measured against the bubble's resting place, so a cursor passing along the inside
            // of the ring doesn't open a folder that leaned toward it.
            let a = level.angle(b.slot)
            let home = level.center + t.ringRadius * V2(cos(a), sin(a))
            if simd_distance(cursor, home) < t.bubbleRadius {
                dwell += dt
                if dwell >= t.folderDwell { enterFolder(b) }
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
        let t = tuning
        let ring = t.ringRadius
        let active = phase == .open ? levels.last : nil
        let showLabel = (phase == .open && (hovered != nil || hoverBack)) || (phase == .closing && labelHeld)

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
                let shown = parentStyle == .shrink
                level.scale.target = shown ? t.parentScale * (hoverBack ? 1.14 : 1) : 0
                level.alpha.target = shown ? (hoverBack ? 0.92 : t.parentAlpha) : 0
            case .buried, .dying:
                break
            }
            level.scale.step(dt)
            level.alpha.step(dt)

            let lean = level === active ? clampLength((cursor - level.center) * 0.045, 4) : V2(0, 0)
            level.hubPos.target = level.center + lean
            level.hubPos.step(dt)
            let hubP = level.hubPos.value

            if level.retreating, !level.hubClosing, time >= level.hubCloseAt,
               bubbles.allSatisfy({ $0.level !== level || simd_distance($0.pos.value, hubP) < 38 }) {
                level.hubClosing = true
                level.hubHalfW.config = t.hubClose
                level.hubHalfH.config = t.hubClose
            }
            if level.hubClosing {
                // Aim below zero: a spring only approaches its target, and a speck would linger at the end.
                level.hubHalfW.target = -4
                level.hubHalfH.target = -4
            } else if level.role == .ghost {
                level.hubHalfW.target = t.hubRadius * level.scale.value
                level.hubHalfH.target = t.hubRadius * level.scale.value
            } else if showLabel, level === levels.last {
                level.hubHalfW.config = t.hubMorph
                level.hubHalfH.config = t.hubMorph
                level.hubHalfW.target = max(t.pillHalfHeight + 6, labelWidth(labelTitles[labelSlot]) / 2 + t.pillPadding)
                level.hubHalfH.target = t.pillHalfHeight
            } else {
                level.hubHalfW.target = t.hubRadius
                level.hubHalfH.target = t.hubRadius
            }
            level.hubHalfW.step(dt)
            level.hubHalfH.step(dt)
            level.hubTint.target = 0
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
            }
            let dist = simd_distance(b.pos.value, hubP)
            if b.leaving, time >= b.leaveAt {
                b.pos.config = t.retractPos
                b.pos.target = hubP
                b.radius.config = t.radiusLeave
                b.radius.target = dist < 5 ? -3 : t.bubbleRadius * level.bubbleScale(t) * clamp01(dist / (ring * 0.9))
                b.tint.target = b.selected ? 1 : 0
                b.push.target = 0
            } else {
                let s = level.scale.value
                let isHovered = b.leaving ? b.selected : (level === active && hovered == b.slot)
                let isOpenFolder = level.openSlot == b.slot
                let angle = level.angle(b.slot) + b.push.value
                var home = level.center + ring * s * V2(cos(angle), sin(angle))
                if isHovered, !b.leaving {
                    home += clampLength((cursor - home) * 0.22, 7)
                }
                b.pos.target = home
                // Bubbles grow as they leave the hub, so the hub doesn't balloon while it holds them.
                let emerge = max(0.5, clamp01(dist / (ring * 0.5 * max(s, 0.05))))
                let front = level.role == .active
                b.pos.config = front ? t.enterPos : t.ghostTrack
                b.radius.config = front ? (isHovered ? t.radiusHover : t.radiusRest) : t.ghostTrack
                b.radius.target = (isHovered ? t.hoverRadius : t.bubbleRadius) * level.bubbleScale(t) * emerge
                b.tint.target = isHovered || isOpenFolder ? 1 : 0
                b.push.target = b.leaving ? 0 : pushAngle(for: b, active: active)
            }
            b.pos.step(dt)
            b.tail.target = b.pos.value
            b.tail.step(dt)
            b.radius.step(dt)
            b.tint.step(dt)
            b.push.step(dt)
        }
        bubbles.removeAll { b in
            guard b.leaving, b.active, time >= b.leaveAt else { return false }
            let dist = simd_distance(b.pos.value, b.level.hubPos.value)
            return (b.radius.value < 0.6 && dist < 10) || time > b.leaveAt + 0.7
        }
        dying.removeAll { level in
            level.hubClosing && level.hubGone && !bubbles.contains { $0.level === level }
        }

        // Droplet
        if let level = active {
            let v = cursor - level.center
            let d = simd_length(v)
            if hovered != nil || hoverBack, d > 0 {
                dropPos.target = level.center + v / d * min(d, ring)
                dropRadius.target = t.dropRadius
                dropTint.target = hoverBack ? 0 : 1
            } else {
                dropPos.target = level.center + clampLength(v, max(t.hubRadius - 11, 0))
                dropRadius.target = 5
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

        if phase == .closing, dying.isEmpty, bubbles.isEmpty,
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

    // MARK: Output

    var hintCenter: V2 { (levels.first?.center ?? lastCenter) + V2(0, tuning.hintOffset) }

    func blobs() -> [Blob] {
        guard phase != .closed else { return [] }
        let t = tuning
        var out: [Blob] = []
        out.reserveCapacity(48)

        for level in allLevels {
            let hw = max(level.hubHalfW.value, 0)
            let hh = max(level.hubHalfH.value, 0)
            if hw > 0.3, hh > 0.3 {
                out.append(Blob(
                    center: level.hubPos.value, half: V2(hw, hh), corner: min(hw, hh),
                    tint: clamp01(level.hubTint.value), alpha: clamp01(level.alpha.value)
                ))
            }
        }
        let budGrowth = folderDwellProgress
        for b in bubbles where b.active {
            let r = b.radius.value
            guard r > 0.3 else { continue }
            let level = b.level
            let tint = clamp01(b.tint.value)
            // The open folder's dot stays bright in the shrunken ring to mark the path taken.
            let marksPath = level.openSlot == b.slot && parentStyle == .shrink
            let alpha = marksPath ? max(clamp01(level.alpha.value), 0.95) : clamp01(level.alpha.value)
            out.append(Blob(center: b.pos.value, half: V2(r, r), corner: r, tint: tint, alpha: alpha))
            // The tail only has size while it trails, so a bubble at rest is a clean circle.
            // A shrunken ring has no tails: they would bridge its dots.
            let trailing = level.role == .active || b.leaving
            let tr = trailing ? r * 0.72 * clamp01(simd_distance(b.tail.value, b.pos.value) / 9) : 0
            if tr > 0.5 {
                out.append(Blob(center: b.tail.value, half: V2(tr, tr), corner: tr, tint: tint, alpha: alpha))
            }
            // Folders carry a small bud on their outer edge. It swells just before the folder opens.
            if b.action.isFolder, !b.leaving, level.role == .active, level.scale.value > 0.85, r > 12 {
                let outward = b.pos.value - level.hubPos.value
                let length = simd_length(outward)
                if length > 20 {
                    let hoveredFolder = level === levels.last && hovered == b.slot
                    let br = 4.6 * min(r / t.bubbleRadius, 1.1) * (hoveredFolder ? 1 + 0.9 * budGrowth : 1)
                    out.append(Blob(center: b.pos.value + outward / length * (r + 1.2), half: V2(br, br), corner: br, tint: tint, alpha: alpha))
                }
            }
        }
        let dr = dropRadius.value
        if dr > 0.3 {
            out.append(Blob(center: dropPos.value, half: V2(dr, dr), corner: dr, tint: clamp01(dropTint.value)))
        }
        let hp = hintPresence.value
        if hp > 0.02 {
            let s = max(hp, 0)
            let half = V2(hintHalfWidth * s, t.hintHalfHeight * s)
            out.append(Blob(center: hintCenter, half: half, corner: min(half.x, half.y), tint: 0))
        }
        return out
    }
}
