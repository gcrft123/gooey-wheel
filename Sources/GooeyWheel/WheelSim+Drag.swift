import Foundation
import simd

/// Where a dragged bubble goes if it is let go now, other than its gap in the ring.
enum DropTarget: Equatable {
    /// Onto a folder, which takes it, or onto an item, which makes a folder of the two.
    case bubble(BubbleKey)
    /// Onto the shrunken parent ring, which moves it out of the folder.
    case parent
}

/// A bubble being dragged. Nothing is saved until it is dropped: rings show `order`, a
/// preview of where it would land.
struct Drag {
    let item: WheelItem
    var key: BubbleKey { .item(item.id) }
    /// The ring that currently makes room for the bubble, and that ring's order with the bubble in it.
    var home: Container
    var order: [UUID]
    /// The bubble's center minus the cursor. It eases to zero so the bubble ends up under the cursor.
    var offset: V2
    var target: DropTarget?
    /// What the bubble is over, and since when. It becomes the target after a moment, so
    /// bubbles don't flash as the drag passes across them.
    var candidate: DropTarget?
    var candidateSince = 0.0

    var index: Int { order.firstIndex(of: item.id) ?? 0 }
}

extension WheelSim {
    private var draggedBubble: Bubble? {
        guard let drag = config.drag else { return nil }
        return bubbles.first { $0.key == drag.key && !$0.leaving }
    }

    func isDragged(_ b: Bubble) -> Bool {
        config.drag?.key == b.key && !b.leaving
    }

    func isDragged(_ key: BubbleKey) -> Bool {
        config.drag?.key == key
    }

    func isDropTarget(_ b: Bubble) -> Bool {
        config.drag?.target == .bubble(b.key) && b.level === levels.last
    }

    /// A folder swells a little more the longer the drag rests on it, until it opens.
    var dropTargetRadius: Double {
        guard let drag = config.drag, case .bubble(let key) = drag.target,
              currentBubble(key)?.entry.isFolder == true else { return tuning.targetRadius }
        return tuning.targetRadius + 4 * smooth01((time - drag.candidateSince) / tuning.springLoad)
    }

    /// A ring's items as they should be shown: the saved ones, with a dragged item taken out
    /// of its ring and put where it would land.
    func displayItems(in container: Container) -> [WheelItem] {
        let saved = store.items(in: container) ?? []
        guard let drag = config.drag else { return saved }
        guard container == drag.home else { return saved.filter { $0.id != drag.item.id } }
        var byID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        byID[drag.item.id] = drag.item
        return drag.order.compactMap { byID[$0] }
    }

    // MARK: Lift

    func beginDrag(_ b: Bubble) {
        guard let item = b.entry.item, let container = b.level.container,
              let saved = store.items(in: container) else { return }
        config.drag = Drag(item: item, home: container, order: saved.map(\.id), offset: b.pos.value - cursor)
        config.hit = .none
        setHover(nil, back: false)
        b.radius.velocity += 90
        onEdit?(.lifted)
    }

    func stepDragged(_ b: Bubble) {
        guard let drag = config.drag else { return }
        let t = tuning
        b.pos.config = t.dragPos
        b.pos.target = cursor + drag.offset
        b.radius.config = t.radiusHover
        // It tucks in over something that will take it.
        b.radius.target = drag.target == nil ? t.dragRadius : t.bubbleRadius * 0.68
        // Over a bubble that will take it, it takes that bubble's fill, so the two read as one.
        let joining: Bool
        if case .bubble = drag.target { joining = true } else { joining = false }
        b.tint.target = joining ? 1 : 0
        b.lift.target = joining ? 0 : 1
        b.push.target = 0
    }

    /// A bubble dragged into a ring that is opening belongs to that ring from then on.
    func adoptDragged(into level: Level) {
        guard let b = draggedBubble else { return }
        b.level = level
        b.slot = level.slot(of: b.key) ?? 0
        b.angle.snap(level.angle(b.slot))
    }

    // MARK: Follow

    func updateDrag(_ dt: Double) {
        guard var drag = config.drag, let level = levels.last, let container = level.container,
              draggedBubble != nil, drag.home == container else {
            cancelDrag()
            return
        }
        let t = tuning
        drag.offset *= exp(-dt * 12)
        let p = cursor + drag.offset
        let v = p - level.center
        let dist = simd_length(v)

        var over: DropTarget?
        if overParentRing(p) {
            if canMoveOut(drag) { over = .parent }
        } else if dist > t.ringRadius - 46, dist < t.ringRadius + 64, level.count > 1 {
            if reorder(&drag, level: level, angle: atan2(v.y, v.x)) {
                config.drag = drag
                syncLevels()
            }
            over = bubbleUnder(p, drag: drag, level: level)
        }

        if over != drag.candidate {
            drag.candidate = over
            drag.candidateSince = time
        }
        // Leaving a target is immediate. Arriving on one takes a moment.
        let armed = over == nil || time - drag.candidateSince >= 0.07
        if armed, drag.target != over {
            drag.target = over
            if over != nil { onHover?() }
        }
        config.drag = drag
        setHover(nil, back: drag.target == .parent)

        // Resting on a folder or on the parent ring opens it, to place the bubble exactly.
        guard let target = drag.target, target == over, time - drag.candidateSince >= t.springLoad else { return }
        switch target {
        case .bubble(let key):
            if let folder = currentBubble(key), folder.entry.isFolder { dragInto(folder) }
        case .parent:
            dragOut()
        }
    }

    /// Moves the gap one neighbor at a time toward where the bubble is held. A neighbor the
    /// bubble could be dropped onto gives way only once the bubble's center has passed its
    /// own, which leaves its near half as the place to drop. Any other neighbor gives way
    /// at the halfway point.
    private func reorder(_ drag: inout Drag, level: Level, angle: Double) -> Bool {
        let n = level.count
        let wraps = level.arcMid == nil
        var delta = level.slotPosition(angle: angle) - Double(drag.index)
        if wraps { delta -= Double(n) * (delta / Double(n)).rounded() }
        let direction = delta > 0 ? 1 : -1
        var remaining = abs(delta)
        var moved = false
        for _ in 0..<(n - 1) {
            let from = drag.index
            var to = from + direction
            if wraps { to = (to + n) % n } else if to < 0 || to >= n { break }
            guard let neighbor = displayItem(drag.order[to], drag: drag) else { break }
            let threshold = canDrop(drag, onto: neighbor) ? 1 + 12 / (tuning.ringRadius * level.slice) : 0.56
            guard remaining > threshold else { break }
            drag.order.swapAt(from, to)
            remaining -= 1
            moved = true
        }
        return moved
    }

    private func displayItem(_ id: UUID, drag: Drag) -> WheelItem? {
        id == drag.item.id ? drag.item : store.item(id)
    }

    private func bubbleUnder(_ p: V2, drag: Drag, level: Level) -> DropTarget? {
        let t = tuning
        for b in bubbles where b.level === level && b.active && !b.leaving && b.key != drag.key {
            guard let item = b.entry.item, canDrop(drag, onto: item) else { continue }
            let a = level.angle(b.slot)
            let home = level.center + t.ringRadius * V2(cos(a), sin(a))
            let reach = t.mergeRadius + (drag.candidate == .bubble(b.key) ? 6 : 0)
            if simd_distance(p, home) < reach { return .bubble(b.key) }
        }
        return nil
    }

    /// Folders don't nest: a folder can't be dropped onto anything, and inside a folder
    /// nothing can be dropped onto an item.
    private func canDrop(_ drag: Drag, onto item: WheelItem) -> Bool {
        guard !drag.item.isFolder, item.id != drag.item.id else { return false }
        if let children = item.children {
            return children.filter { $0.id != drag.item.id }.count < WheelLimits.folderItems
        }
        return drag.home == .root
    }

    private func canMoveOut(_ drag: Drag) -> Bool {
        guard levels.count >= 2, let parent = levels[levels.count - 2].container,
              let items = store.items(in: parent) else { return false }
        return items.filter { $0.id != drag.item.id }.count < WheelLimits.capacity(of: parent)
    }

    // MARK: Between rings

    /// The order a ring would have with the dragged item added after `anchor`, or at the end.
    private func order(of container: Container, adding id: UUID, after anchor: UUID? = nil) -> [UUID] {
        var ids = (store.items(in: container) ?? []).map(\.id).filter { $0 != id }
        if let anchor, let i = ids.firstIndex(of: anchor) {
            ids.insert(id, at: i + 1)
        } else {
            ids.append(id)
        }
        return ids
    }

    private func dragInto(_ folder: Bubble) {
        guard var drag = config.drag, let item = folder.entry.item, item.isFolder else { return }
        drag.home = .folder(item.id)
        drag.order = order(of: drag.home, adding: drag.item.id)
        drag.target = nil
        drag.candidate = nil
        config.drag = drag
        enter(folder)
        syncLevels()
    }

    private func dragOut() {
        guard var drag = config.drag, levels.count >= 2, let b = draggedBubble,
              case .folder(let folderID) = drag.home else { return }
        let parent = levels[levels.count - 2]
        guard let container = parent.container else { return }
        drag.home = container
        drag.order = order(of: container, adding: drag.item.id, after: folderID)
        drag.target = nil
        drag.candidate = nil
        config.drag = drag
        // Move the bubble to the parent ring first, so it isn't sent back with the folder's.
        b.level = parent
        back()
        syncLevels()
        b.angle.snap(parent.angle(b.slot))
    }

    // MARK: Drop

    func drop() {
        guard let drag = config.drag else { return }
        config.drag = nil
        guard let b = bubbles.first(where: { $0.key == drag.key && !$0.leaving }) else {
            syncLevels()
            return
        }
        let id = drag.item.id
        switch drag.target {
        case .bubble(let key):
            guard let onto = currentBubble(key), let item = onto.entry.item else { break }
            b.sink = onto
            b.leaving = true
            b.leaveAt = time
            onto.radius.velocity += 150
            if item.isFolder {
                store.place(id, in: .folder(item.id), order: order(of: .folder(item.id), adding: id))
            } else {
                // The bubble it landed on becomes the folder, in place.
                let folderID = UUID()
                store.makeFolder(folderID, from: item.id, adding: id)
                onto.key = .item(folderID)
                config.pendingEdit = (.item(folderID), time + 0.38)
            }
        case .parent:
            guard levels.count >= 2, let container = levels[levels.count - 2].container,
                  case .folder(let folderID) = drag.home else { break }
            // It joins the parent ring where that ring is, small behind this one.
            b.level = levels[levels.count - 2]
            store.place(id, in: container, order: order(of: container, adding: id, after: folderID))
        case nil:
            store.place(id, in: drag.home, order: drag.order)
        }
        syncLevels()
        for moved in bubbles where moved.key == drag.key && !moved.leaving {
            moved.angle.snap(moved.level.angle(moved.slot))
        }
        onEdit?(.dropped)
    }

    /// Puts everything back where it is saved.
    func cancelDrag() {
        guard config.drag != nil else { return }
        let key = config.drag?.key
        config.drag = nil
        syncLevels()
        for b in bubbles where b.key == key && !b.leaving {
            b.angle.snap(b.level.angle(b.slot))
        }
    }
}
