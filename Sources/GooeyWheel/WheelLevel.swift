import Foundation
import simd

/// The choices around an item that is being edited.
enum EditOption: String, CaseIterable {
    case action, color, icon, rename, remove

    var title: String {
        switch self {
        case .action: return "Action"
        case .color: return "Color"
        case .icon: return "Icon"
        case .rename: return "Rename"
        case .remove: return "Remove"
        }
    }

    var symbol: String {
        switch self {
        case .action: return "bolt.fill"
        case .color: return "paintpalette.fill"
        case .icon: return "square.on.circle.fill"
        case .rename: return "character.cursor.ibeam"
        case .remove: return "trash.fill"
        }
    }

    var isDestructive: Bool { self == .remove }

    /// A folder has no action of its own to change.
    static func options(for item: WheelItem) -> [EditOption] {
        item.isFolder ? [.color, .icon, .rename, .remove] : allCases
    }
}

/// Identifies a bubble across re-layouts, so a ring that changes re-spaces instead of rebuilding.
enum BubbleKey: Hashable {
    case item(UUID)
    case option(EditOption)
    case choice(UUID, String)
}

/// What one bubble stands for.
enum Entry {
    case item(WheelItem)
    case option(EditOption)
    /// One of the choices a picker item opens into, such as a sound output.
    case choice(UUID, LiveChoice)

    var key: BubbleKey {
        switch self {
        case .item(let item): return .item(item.id)
        case .option(let option): return .option(option)
        case .choice(let id, let choice): return .choice(id, choice.id)
        }
    }

    var choice: LiveChoice? {
        if case .choice(_, let choice) = self { return choice }
        return nil
    }

    /// What the item's action shows or changes beyond running once.
    var control: ActionControl? {
        item?.actionID.flatMap(ActionCatalog.action)?.control
    }

    /// Opens into a ring of its own in normal use: a folder, or a picker's choices.
    var opens: Bool { isFolder || control == .picker }

    var item: WheelItem? {
        if case .item(let item) = self { return item }
        return nil
    }

    var option: EditOption? {
        if case .option(let option) = self { return option }
        return nil
    }

    var title: String { item?.title ?? option?.title ?? choice?.title ?? "" }
    var symbol: String { item?.symbol ?? option?.symbol ?? choice?.symbol ?? "questionmark" }
    var isFolder: Bool { item?.isFolder ?? false }
}

/// One ring of the wheel with its hub. The root is a level, and so is every open folder and
/// every item that is open for editing.
final class Level {
    enum Kind: Equatable {
        /// The items of the wheel or of a folder.
        case ring(Container)
        /// The edit options around one item. The hub is the item.
        case edit(UUID)
        /// A picker item's choices, found when it opens. The hub is the item.
        case picker(UUID)
        /// A slider item turned into a bar. The hub is the bar, and the level has no bubbles.
        case control(UUID)
    }

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
    let kind: Kind
    var entries: [Entry]
    /// The folder's or edited item's symbol and color, shown in the hub. Nil at the root.
    var symbol: String?
    var color: ItemColor?
    var center: V2
    /// Direction this ring faces, away from its parent. Nil for a full ring.
    var arcMid: Double?
    /// The widest the arc gets. A ring with few items uses less of it.
    var arcLimit = 0.0
    /// Rings that open to the left run counterclockwise so their first item is still on top.
    var reversed = false
    var role = Role.active
    /// The bubble whose folder or edit ring is open from this ring.
    var openKey: BubbleKey?

    var hubPos: Spring2
    var hubHalfW: Spring
    var hubHalfH: Spring
    var hubTint: Spring
    var scale: Spring
    var alpha: Spring
    var retreating = false
    var hubCloseAt = 0.0
    var hubClosing = false

    init(id: Int, kind: Kind, entries: [Entry], symbol: String?, color: ItemColor?, center: V2, tuning t: Tuning) {
        self.id = id
        self.kind = kind
        self.entries = entries
        self.symbol = symbol
        self.color = color
        self.center = center
        hubPos = Spring2(center, t.hubPos)
        hubHalfW = Spring(0, t.hubSize)
        hubHalfH = Spring(0, t.hubSize)
        hubTint = Spring(0, t.tint)
        scale = Spring(1, t.levelScale)
        alpha = Spring(1, t.levelAlpha)
    }

    var count: Int { entries.count }
    var hubGone: Bool { hubHalfW.value < 0.5 || hubHalfH.value < 0.5 }

    var container: Container? {
        if case .ring(let container) = kind { return container }
        return nil
    }

    var isEdit: Bool {
        if case .edit = kind { return true }
        return false
    }

    var isControl: Bool {
        if case .control = kind { return true }
        return false
    }

    /// The item an edit ring, picker or bar was opened from.
    var itemID: UUID? {
        switch kind {
        case .edit(let id), .picker(let id), .control(let id): return id
        case .ring(.folder(let id)): return id
        case .ring(.root): return nil
        }
    }

    /// Which way a bar runs, as a unit vector from its low end to its high end.
    var barAxis = V2(1, 0)
    /// A bar's length when fully open.
    var barLength = 0.0
    /// The level a bar shows, gliding to each new reading.
    var barShown = Spring(0, SpringConfig.critical(k: 900))
    /// Where a bar goes back to when it closes: its bubble's place in the ring.
    var barHome = V2(0, 0)
    /// How far past an end a bar is pulled, in points: positive past its high end, negative
    /// past its low end. It springs back when let go.
    var barStretch = Spring(0, SpringConfig(k: 240, c: 19))
    /// 1 while the bar is held, when it swells a little under the hand.
    var barGrow = Spring(0, SpringConfig(k: 380, c: 24))

    /// The hub's resting radius. An item being edited keeps its size as the hub.
    func hubRadius(_ t: Tuning) -> Double {
        isEdit ? t.bubbleRadius : t.hubRadius
    }

    /// Scale for this ring's bubbles: equal to `scale` at full size, smaller once shrunk.
    func bubbleScale(_ t: Tuning) -> Double {
        let s = scale.value
        let full = smooth01((s - t.parentScale) / (1 - t.parentScale))
        return s * (t.parentDotScale + (1 - t.parentDotScale) * full)
    }

    func slot(of key: BubbleKey) -> Int? {
        entries.firstIndex { $0.key == key }
    }

    /// Items on an arc are never further apart than six of them would be on the full arc.
    private var maxStep: Double { arcLimit / 5 }
    private var arcStep: Double { count > 1 ? min(arcLimit / Double(count - 1), maxStep) : 0 }
    private var arcSpan: Double { arcStep * Double(max(count - 1, 0)) }

    /// Angle between neighbors.
    var slice: Double {
        if arcMid == nil { return 2 * .pi / Double(max(count, 1)) }
        return count > 1 ? arcStep : maxStep
    }

    /// Where a full ring's first item sits: 12 o'clock, with the rest following clockwise.
    /// Two items sit side by side instead, the first on the left.
    private var fullRingStart: Double { count == 2 ? .pi : -.pi / 2 }

    func angle(_ slot: Int) -> Double {
        let n = count
        guard let mid = arcMid else {
            return fullRingStart + Double(slot) * 2 * .pi / Double(max(n, 1))
        }
        let index = reversed ? n - 1 - slot : slot
        return mid - arcSpan / 2 + Double(index) * arcStep
    }

    /// The slot the cursor's direction points at, or `.back` when it points at the parent.
    func pick(angle a: Double, current: Int?, currentBack: Bool) -> Pick {
        let n = count
        // Stay on the current choice until the cursor is clearly past its edge.
        if let h = current, h < n, abs(wrapAngle(a - angle(h))) < slice / 2 + 0.07 {
            return .slot(h)
        }
        guard let mid = arcMid else {
            let raw = Int((wrapAngle(a - fullRingStart) / slice).rounded())
            return .slot(((raw % n) + n) % n)
        }
        let rel = wrapAngle(a - mid)
        let edge = arcLimit / 2 + maxStep / 2
        if abs(rel) > edge - (currentBack ? 0.07 : 0) { return .back }
        let index = min(max(Int(((rel + arcSpan / 2) / slice).rounded()), 0), n - 1)
        return .slot(reversed ? n - 1 - index : index)
    }

    /// Position along the ring in slots, as a fraction, for a direction from the center.
    func slotPosition(angle a: Double) -> Double {
        guard let mid = arcMid else {
            let raw = wrapAngle(a - fullRingStart) / slice
            return raw < 0 ? raw + Double(count) : raw
        }
        let index = (wrapAngle(a - mid) + arcSpan / 2) / slice
        return reversed ? Double(count - 1) - index : index
    }
}

final class Bubble {
    let id: Int
    var key: BubbleKey
    var entry: Entry
    var slot: Int
    unowned var level: Level
    var pos: Spring2
    var tail: Spring2
    var radius: Spring
    var tint: Spring
    /// 1 while the cursor is on the bubble during configuration, where a bubble brightens
    /// instead of filling with the accent color.
    var lift: Spring
    /// Where on the ring the bubble sits. It follows its slot's angle, so a ring that gains,
    /// loses, or reorders items slides along its circle.
    var angle: Spring
    /// Angular displacement away from the hovered neighbor, in radians.
    var push: Spring
    var activateAt: Double
    var active = false
    var leaving = false
    var leaveAt = 0.0
    var selected = false
    /// A bubble that is leaving drains into this one instead of its hub.
    weak var sink: Bubble?
    /// The largest a bubble removed from its ring gets on the way out.
    var leaveRadius: Double?
    /// A slider's level as its rim shows it, gliding to each new reading.
    var levelShown = Spring(0, SpringConfig.critical(k: 380))
    var levelKnown = false
    /// Sideways shake, in points, when a bubble refuses to be chosen.
    var shake = Spring(0, SpringConfig(k: 1500, c: 18))

    // Configuration
    /// 1 while the remove or edit badge is out.
    var badge: Spring
    var badgeTint: Spring
    /// 1 while the bubble jiggles, 0 while it holds still under the cursor.
    var wobble: Spring
    let wobblePhase: Double

    init(id: Int, entry: Entry, slot: Int, level: Level, at p: V2, activateAt: Double, tuning t: Tuning) {
        self.id = id
        self.key = entry.key
        self.entry = entry
        self.slot = slot
        self.level = level
        self.activateAt = activateAt
        pos = Spring2(p, t.enterPos)
        tail = Spring2(p, t.tailPos)
        radius = Spring(0, t.radiusRest)
        tint = Spring(0, t.tint)
        lift = Spring(0, t.tint)
        angle = Spring(level.angle(slot), t.respace)
        push = Spring(0, t.push)
        badge = Spring(0, t.badge)
        badgeTint = Spring(0, t.tint)
        wobble = Spring(0, t.wobble)
        // The golden ratio spreads the phases so neighbors never move together.
        wobblePhase = Double(id) * 0.618_033_988_75 * 2 * .pi
    }

    var count: Int { level.count }
    var color: ItemColor? { entry.item?.color }
}
