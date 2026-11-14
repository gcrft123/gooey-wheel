import Foundation
import simd

/// What the cursor is on while the wheel is being rearranged. Outside configuration the wheel
/// picks by direction instead.
enum Hit: Equatable {
    /// Inside the wheel, on nothing.
    case none
    case outside
    case bubble(BubbleKey)
    /// The remove or edit button on a bubble's outer edge.
    case badge(BubbleKey)
    case hub
    /// The shrunken parent ring.
    case back
}

enum EditFeedback {
    case entered, exited, changed, refused, lifted, dropped
}

/// A request to open one of the editing panels for an item.
struct EditorRequest {
    let option: EditOption
    let itemID: UUID
}

struct Press {
    var hit: Hit
    var origin: V2
}

struct ConfigState {
    var active = false
    /// 0 in normal use, 1 while configuring. Scales the jiggle.
    var presence = Spring(0, SpringConfig(k: 240, c: 26))
    var startedAt = 0.0
    var hit = Hit.none
    var press: Press?
    var drag: Drag?
    /// Sideways kick the hub gets when it can't add another item.
    var hubShake = Spring(0, SpringConfig(k: 1100, c: 20))
    /// A new item's edit ring opens once the item has landed.
    var pendingEdit: (key: BubbleKey, at: Double)?
    /// The cursor is crossing a gap between bubbles. The hub keeps the last name it showed,
    /// so it doesn't fold back into a circle and out again on the way to the next bubble.
    var holdsLabel = false
    var tag = Tag()
    /// The editing panel that is open over the wheel.
    var editor: EditorState?
}

/// The name that grows out of the hovered edit option.
struct Tag {
    var key: BubbleKey?
    var title = ""
    var presence = Spring(0, SpringConfig(k: 520, c: 30))
}

/// The per-frame wobble of a bubble while configuring. The bubble drifts and its icon
/// tilts; its outline stays a circle.
struct Jiggle {
    var offset = V2(0, 0)
    /// Radians the icon tilts by.
    var rotation = 0.0
}

extension WheelSim {
    // MARK: Entering and leaving

    /// A right click. On the wheel it starts or ends configuration. Off the wheel it closes
    /// the wheel in normal use, and ends configuration otherwise.
    func secondaryClick() {
        guard phase == .open else { return }
        if config.editor != nil {
            // Inside a panel a right click belongs to the panel. Outside it acts like a click.
            editorPointerDown()
            editorPointerUp()
        } else if config.active {
            exitConfiguration()
        } else if hitTest(cursor) == .outside {
            dismiss()
        } else {
            enterConfiguration()
        }
    }

    func enterConfiguration() {
        guard phase == .open, !config.active else { return }
        // A picker's choices and a slider's bar aren't part of the wheel's arrangement.
        while let last = levels.last, levels.count > 1, last.container == nil, !last.isEdit { back() }
        config = ConfigState()
        config.active = true
        config.presence.config = tuning.jiggle > 0 ? SpringConfig(k: 240, c: 26) : .critical(k: 600)
        config.startedAt = time
        mode = .sticky
        showHint = false
        store.beginSession()
        setHover(nil, back: false)
        onEdit?(.entered)
    }

    /// Back to the normal wheel, which stays open.
    func exitConfiguration() {
        guard config.active else { return }
        endConfiguration()
        if levels.last?.isEdit == true { back() }
        // The cursor is wherever the last click was. Don't pick by its direction until it moves.
        armed = false
        armOrigin = cursor
        onEdit?(.exited)
    }

    func endConfiguration() {
        guard config.active else { return }
        cancelDrag()
        if let editor = config.editor {
            // The wheel is closing with a panel open. An item added for it and never saved goes too.
            if editor.provisional, !editor.saved { store.discardInsert(editor.itemID) }
            config.editor?.dismissed = true
            onEditorClose?()
        }
        config.active = false
        config.press = nil
        config.pendingEdit = nil
        config.hit = .none
        setHover(nil, back: false)
    }

    /// Esc steps back one layer: a drag, then an edit ring or folder, then configuration itself.
    func escapeConfiguration() {
        if config.editor != nil {
            closeEditor()
        } else if config.drag != nil {
            cancelDrag()
        } else if levels.count > 1 {
            back()
        } else {
            exitConfiguration()
        }
    }

    // MARK: Pointer

    func pointerDown() {
        guard phase == .open else { return }
        guard config.active else {
            click()
            return
        }
        if config.editor != nil {
            editorPointerDown()
            return
        }
        refreshHover()
        config.press = Press(hit: config.hit, origin: cursor)
    }

    func pointerUp() {
        // A bar opened by pressing on its bubble closes when the button comes up after a drag.
        if phase == .open, !config.active, let drive = barDrive, drive.springLoaded {
            if drive.dragged { back() } else { barDrive?.springLoaded = false }
            return
        }
        if phase == .open, config.editor != nil {
            editorPointerUp()
            return
        }
        guard phase == .open, config.active, let press = config.press else { return }
        config.press = nil
        if config.drag != nil {
            drop()
            return
        }
        refreshHover()
        guard config.hit == press.hit else { return }
        activate(press.hit)
    }

    private func activate(_ hit: Hit) {
        guard let level = levels.last else { return }
        switch hit {
        case .badge(let key):
            guard let b = currentBubble(key), let item = b.entry.item else { return }
            if item.isFolder { enter(b, editing: true) } else { remove(item.id) }
        case .bubble(let key):
            guard let b = currentBubble(key) else { return }
            switch b.entry {
            case .item(let item):
                enter(b, editing: !item.isFolder)
            case .option(let option):
                choose(option, on: b)
            case .choice:
                break
            }
        case .hub:
            if level.isEdit { back() } else { addItem() }
        case .back:
            back()
        case .outside:
            // An edit ring closes like a popover. Past that, a click outside ends configuration.
            if level.isEdit { back() } else { exitConfiguration() }
        case .none:
            break
        }
    }

    func hitTest(_ p: V2) -> Hit {
        guard let level = levels.last else { return .outside }
        let t = tuning
        if level.isEdit, config.active { return editRingHit(p, level) }
        let front = bubbles.filter { $0.level === level && $0.active && !$0.leaving }
        if config.active {
            for b in front where b.badge.value > 0.5 {
                let d = simd_distance(p, badgeCenter(b))
                let offBubble = simd_distance(p, b.pos.value) > b.radius.value
                if d < (offBubble ? t.badgeHitRadiusOutside : t.badgeHitRadius) { return .badge(b.key) }
            }
        }
        // An edit option is a plain button, so it gets a more forgiving target than a bubble
        // that also has a badge next to it.
        let slack = level.isEdit ? 8.0 : 3.0
        // A bubble still on its way out of the hub isn't a target yet. The hub is.
        for b in front where simd_distance(b.pos.value, level.hubPos.value) > 50
            && simd_distance(p, b.pos.value) < b.radius.value + slack {
            return .bubble(b.key)
        }
        if simd_distance(p, level.hubPos.value) < level.hubRadius(t) + 5 { return .hub }
        if overParentRing(p) { return .back }
        let reach = t.ringRadius + t.bubbleRadius + t.outsideMargin + (level.isEdit ? 2 * t.tagHalfHeight : 0)
        return simd_distance(p, level.center) > reach ? .outside : .none
    }

    /// An edit ring picks by direction, like the wheel in normal use: anywhere among the
    /// options, the nearest one by angle is chosen, so there is no empty space between them
    /// for the selection to fall back into.
    private func editRingHit(_ p: V2, _ level: Level) -> Hit {
        let t = tuning
        let v = p - level.center
        let dist = simd_length(v)
        if dist < level.hubRadius(t) + 4 { return .hub }
        if overParentRing(p) { return .back }
        let reach = t.ringRadius + t.bubbleRadius + t.outsideMargin + 2 * t.tagHalfHeight
        guard dist <= reach, level.count > 0 else { return .outside }
        // A ring that opened around a resting cursor doesn't take its direction as a choice.
        // It waits for the cursor to move, as the wheel does in normal use.
        if !armed {
            guard simd_distance(p, armOrigin) > 12 else { return .none }
            armed = true
        }
        var current: Int?
        if case .bubble(let key) = config.hit { current = level.slot(of: key) }
        switch level.pick(angle: atan2(v.y, v.x), current: current, currentBack: config.hit == .back) {
        case .slot(let slot):
            guard let b = currentBubble(slot), b.active else { return .none }
            return .bubble(b.key)
        case .back:
            return dist >= t.backZoneEnter ? .back : .none
        }
    }

    func overParentRing(_ p: V2) -> Bool {
        guard levels.count >= 2, parentStyle == .shrink else { return false }
        let parent = levels[levels.count - 2]
        return simd_distance(p, parent.center) < tuning.ringRadius * tuning.parentScale + 22
    }

    func refreshConfigurationHover() {
        // A drag decides for itself what the cursor is over. So does an open panel.
        guard config.drag == nil else { return }
        if config.editor != nil {
            refreshEditorHover()
            config.hit = .none
            setHover(nil, back: false)
            return
        }
        let hit = phase == .open ? hitTest(cursor) : Hit.none
        let changed = hit != config.hit
        if let level = levels.last, !level.isEdit {
            switch hit {
            case .bubble: config.holdsLabel = true
            case .none:
                // Only among the bubbles. Nearer the hub, or outside the ring, the name goes.
                let offRing = abs(simd_distance(cursor, level.center) - tuning.ringRadius)
                config.holdsLabel = config.holdsLabel && offRing < tuning.bubbleRadius + 8
            default: config.holdsLabel = false
            }
        } else {
            config.holdsLabel = false
        }
        config.hit = hit
        var slot: Int?
        if case .bubble(let key) = hit { slot = levels.last?.slot(of: key) }
        setHover(slot, back: hit == .back)
        guard changed else { return }
        switch hit {
        case .badge: onHover?()
        case .hub where canUseHub: onHover?()
        default: break
        }
    }

    // MARK: Changes

    /// Whether the hub's button does anything: adding at a ring that has room, or closing an edit ring.
    var canUseHub: Bool {
        guard let level = levels.last else { return false }
        guard let container = level.container else { return true }
        return store.hasRoom(in: container)
    }

    func hasRoom(_ level: Level) -> Bool {
        level.container.map(store.hasRoom) ?? false
    }

    private func addItem() {
        guard let level = levels.last, let container = level.container else { return }
        guard store.hasRoom(in: container) else {
            config.hubShake.velocity = 210
            onEdit?(.refused)
            return
        }
        let item = WheelItem()
        store.insert(item, in: container, at: level.count)
        syncLevels()
        // Leave time for the new bubble to drip out and land before its ring opens around it.
        config.pendingEdit = (.item(item.id), time + 0.4)
        onEdit?(.changed)
    }

    func remove(_ id: UUID) {
        store.remove(id)
        syncLevels()
        onEdit?(.changed)
    }

    private func choose(_ option: EditOption, on b: Bubble) {
        guard case .edit(let id) = b.level.kind else { return }
        b.radius.velocity += 170
        if option == .remove {
            remove(id)
        } else {
            openEditor(option, from: b)
        }
    }

    func undo() {
        guard phase == .open, config.active, config.drag == nil, config.editor == nil else { return }
        config.pendingEdit = nil
        if store.undo() {
            syncLevels()
            onEdit?(.changed)
        } else {
            onEdit?(.refused)
        }
    }

    func redo() {
        guard phase == .open, config.active, config.drag == nil, config.editor == nil else { return }
        config.pendingEdit = nil
        if store.redo() {
            syncLevels()
            onEdit?(.changed)
        } else {
            onEdit?(.refused)
        }
    }

    // MARK: Step

    func stepConfiguration(_ dt: Double) {
        let t = tuning
        config.presence.target = config.active ? 1 : 0
        config.presence.step(dt)
        config.hubShake.step(dt)

        if config.active, config.drag == nil, let press = config.press, case .bubble(let key) = press.hit,
           simd_distance(cursor, press.origin) > t.dragSlop,
           let b = currentBubble(key), b.entry.item != nil {
            beginDrag(b)
        }
        if config.drag != nil { updateDrag(dt) }

        if let pending = config.pendingEdit, time >= pending.at {
            config.pendingEdit = nil
            if config.active, config.drag == nil, let b = currentBubble(pending.key), let item = b.entry.item {
                // A new item goes straight to choosing its action. A new folder opens its edit ring.
                if item.isFolder { enter(b, editing: true) } else { openEditor(.action, from: b, provisional: true) }
            }
        }

        if levels.last?.isEdit == true, let b = hoveredBubble, let option = b.entry.option {
            if config.tag.key != b.key {
                config.tag.key = b.key
                config.tag.title = option.title
                config.tag.presence.snap(min(config.tag.presence.value, 0.3))
            }
            config.tag.presence.target = 1
        } else {
            config.tag.presence.target = 0
        }
        config.tag.presence.step(dt)
    }

    func stepBadge(_ b: Bubble, _ dt: Double) {
        let level = b.level
        let front = config.active && level.role == .active && !b.leaving
        // Badges bud out one after another around the ring, and only from a bubble that has
        // reached its place: one still on its way out of the hub has nothing to remove yet.
        let arrived = simd_distance(b.pos.value, level.hubPos.value) > tuning.ringRadius * 0.75
        let out = front && arrived && config.drag == nil && level.container != nil
            && time >= config.startedAt + Double(b.slot) * 0.022
        b.badge.target = out ? 1 : 0
        b.badge.step(dt)
        b.badgeTint.target = out && config.hit == .badge(b.key) ? 1 : 0
        b.badgeTint.step(dt)
        b.wobble.target = front && level.container != nil && !holdsStill(b) ? 1 : 0
        b.wobble.step(dt)
    }

    /// A bubble under the cursor stops jiggling, so its badge is easy to hit.
    private func holdsStill(_ b: Bubble) -> Bool {
        if isDragged(b) || isDropTarget(b) { return true }
        switch config.hit {
        case .bubble(let key), .badge(let key): return key == b.key
        default: return false
        }
    }

    // MARK: Appearance

    var showsHubLabel: Bool {
        !config.active || (config.drag == nil && levels.last?.isEdit != true)
    }

    /// The droplet carries a choice from the hub. While configuring, only an edit option is one.
    var showsDroplet: Bool {
        !config.active || (levels.last?.isEdit == true && hovered != nil)
    }

    var hubSwell: Double {
        guard config.active, config.drag == nil, config.hit == .hub, canUseHub else { return 0 }
        return config.press?.hit == .hub ? -1.5 : 3
    }

    var hubFill: Double {
        guard config.active, config.drag == nil, config.hit == .hub, canUseHub, levels.last?.isEdit == false else { return 0 }
        return 1
    }

    /// In normal use, and for an edit option, the hovered bubble fills with color: clicking
    /// picks it. A bubble being arranged only brightens.
    func fillsOnHover(_ b: Bubble) -> Bool {
        // An action this Mac can't run only brightens: there is nothing to choose.
        (!config.active && isAvailable(b)) || b.level.isEdit
    }

    func hoverRadius(_ b: Bubble) -> Double {
        guard config.active else { return tuning.hoverRadius }
        return (b.level.isEdit ? tuning.hoverRadius : tuning.bubbleRadius + 3) * pressScale(b)
    }

    func pressScale(_ b: Bubble) -> Double {
        config.drag == nil && config.press?.hit == .bubble(b.key) ? 0.93 : 1
    }

    func bubbleColor(_ b: Bubble) -> SIMD3<Float>? {
        b.entry.option?.isDestructive == true ? Palette.danger : b.color?.rgb
    }

    func jiggle(_ b: Bubble) -> Jiggle {
        let amount = tuning.jiggle * config.presence.value * b.wobble.value
        guard amount > 0.001 else { return Jiggle() }
        let p = b.wobblePhase
        // Each bubble runs at its own rate, so the ring never falls into step.
        let w = 2 * Double.pi * (1 + 0.14 * sin(p * 1.7)) * time
        return Jiggle(
            offset: V2(cos(w * 1.9 + p), sin(w * 2.6 + p * 1.7)) * (1.3 * amount),
            rotation: sin(w * 3.1 + p * 2.3 + 0.7) * 0.07 * amount
        )
    }

    /// Where the bubble is drawn: its place plus the jiggle.
    func displayPosition(_ b: Bubble) -> V2 {
        b.pos.value + jiggle(b).offset + shakeOffset(b)
    }

    func hubDisplayPosition(_ level: Level) -> V2 {
        level === levels.last ? level.hubPos.value + V2(config.hubShake.value, 0) : level.hubPos.value
    }

    private func outward(_ b: Bubble) -> V2? {
        let v = b.pos.value - b.level.hubPos.value
        let length = simd_length(v)
        return length > 20 ? v / length : nil
    }

    /// The badge sits on the bubble's outer rim. A folder's is where its bud is, and the bud
    /// grows into it.
    func badgeCenter(_ b: Bubble) -> V2 {
        guard let out = outward(b) else { return b.pos.value }
        let t = tuning
        let rest = b.entry.isFolder ? t.folderBadgeOffset : -t.badgeInset
        let reach = 1.2 + (rest - 1.2) * clamp01(b.badge.value)
        return displayPosition(b) + out * (b.radius.value + reach)
    }

    /// Scale of the badge's button: it grows under the cursor and gives when pressed.
    func badgeScale(_ b: Bubble) -> Double {
        let pressed = config.press?.hit == .badge(b.key)
        return max(b.badge.value, 0) * (1 + 0.12 * clamp01(b.badgeTint.value)) * (pressed ? 0.88 : 1)
    }

    /// Radius of the swelling on a folder's outer edge: its bud, which grows into the socket
    /// its badge sits in. Only folders have one. Any other bubble is a plain circle, and its
    /// badge sits on top of it.
    func badgeRadius(_ b: Bubble) -> Double {
        let t = tuning
        let level = b.level
        let r = b.radius.value
        let budded = b.entry.isFolder || (!config.active && b.entry.opens)
        guard budded, outward(b) != nil, !b.leaving, level.role == .active, level.scale.value > 0.85, r > 12 else { return 0 }
        let swelling = level === levels.last && hovered == b.slot
        let bud = 4.6 * min(r / t.bubbleRadius, 1.1) * (swelling ? 1 + 0.9 * folderDwellProgress : 1)
        return bud + (t.folderBadgeSocket - bud) * max(b.badge.value, 0)
    }

    /// Whether a bubble is drawn without its trailing tail: one that is out on a ring that
    /// is being configured.
    func staysRound(_ b: Bubble) -> Bool {
        guard config.active, !b.leaving, b.level.container != nil else { return false }
        return simd_distance(b.pos.value, b.level.hubPos.value) > tuning.ringRadius * 0.75
    }
}
