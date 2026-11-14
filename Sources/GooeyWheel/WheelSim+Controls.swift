import Foundation
import simd

/// What items' actions show and change, read from the actions themselves. The scripted demo
/// supplies made-up values instead, so a recording never touches this Mac's settings.
protocol ControlSource: AnyObject {
    func isAvailable(_ item: WheelItem) -> Bool
    func isOn(_ item: WheelItem) -> Bool?
    func liveSymbol(_ item: WheelItem) -> String?
    func detail(_ item: WheelItem) -> String?
    func level(_ item: WheelItem) -> Double?
    func setLevel(_ item: WheelItem, _ value: Double)
    func detent(_ item: WheelItem) -> Double
    func format(_ item: WheelItem, level: Double) -> String?
    func step(_ item: WheelItem, by notches: Int)
    func choices(_ item: WheelItem) -> [LiveChoice]
    func choose(_ choice: LiveChoice, of item: WheelItem)
}

/// What the wheel last read about an item's state.
struct LiveState: Equatable {
    var available = true
    var on: Bool?
    var symbol: String?
    var detail: String?
    var level: Double?
}

/// A bar that a slider item has turned into, and how the cursor drives it.
struct BarDrive {
    /// The level and the cursor's place along the bar when they were last tied together.
    var anchorValue: Double
    var anchorAlong: Double
    /// The bar was opened by pressing on its bubble. Letting go closes it again.
    var springLoaded: Bool
    var pressOrigin: V2
    /// The pointer moved while the button was down, so letting go ends the adjustment.
    var dragged = false
    /// The cursor is near enough to the bar to drive it.
    var engaged = true
}

extension WheelSim {
    // MARK: Live state

    func live(_ item: WheelItem?) -> LiveState? {
        item.flatMap { liveStates[$0.id] }
    }

    /// Reads the state of every item the wheel is showing. Cheap: actions answer from what
    /// they already know.
    func refreshLive() {
        guard let controls else { return }
        var seen = Set<UUID>()
        for level in allLevels {
            for entry in level.entries {
                guard let item = entry.item, !item.isFolder, item.actionID != nil, seen.insert(item.id).inserted else { continue }
                store(readLive(item, from: controls), for: item.id)
            }
            if let id = level.itemID, let item = store.item(id), !item.isFolder, seen.insert(id).inserted {
                store(readLive(item, from: controls), for: id)
            }
        }
        for b in bubbles where b.active {
            guard let item = b.entry.item, let level = liveStates[item.id]?.level else { continue }
            if !b.levelKnown {
                b.levelShown.snap(level)
                b.levelKnown = true
            } else {
                b.levelShown.target = level
            }
        }
        refreshLabel()
    }

    /// Keeps a reading, except for a level being adjusted right now. A device can round what it
    /// was given, such as a speaker with volume steps, and reading it back would make the
    /// level jump back under the cursor.
    private func store(_ state: LiveState, for id: UUID) {
        var state = state
        if let at = adjustedAt[id], time - at < 1.5, let level = liveStates[id]?.level {
            state.level = level
            state.detail = liveStates[id]?.detail ?? state.detail
        }
        liveStates[id] = state
    }

    private func readLive(_ item: WheelItem, from controls: ControlSource) -> LiveState {
        LiveState(
            available: controls.isAvailable(item),
            on: controls.isOn(item),
            symbol: controls.liveSymbol(item),
            detail: controls.detail(item),
            level: item.actionID.flatMap(ActionCatalog.action)?.control == .slider ? controls.level(item) : nil
        )
    }

    /// The glyph a bubble shows: its item's, or one that follows the action's state.
    func symbol(for b: Bubble) -> String {
        if case .choice(_, let choice) = b.entry { return choice.symbol }
        guard let item = b.entry.item else { return b.entry.symbol }
        // A custom icon is the user's choice and stays whatever the state.
        if let custom = item.customSymbol, !custom.isEmpty { return custom }
        return live(item)?.symbol ?? item.symbol
    }

    /// Whether a bubble's glyph shows the accent color: a toggle that is on, or the choice in effect.
    func isLit(_ b: Bubble) -> Bool {
        if let choice = b.entry.choice { return choice.isCurrent }
        guard let item = b.entry.item, item.color == nil else { return false }
        return live(item)?.on == true
    }

    /// Whether choosing the bubble can do anything on this Mac.
    func isAvailable(_ b: Bubble) -> Bool {
        live(b.entry.item)?.available ?? true
    }

    /// The level a slider's bubble shows around its rim, or nil for any other bubble.
    func shownLevel(_ b: Bubble) -> Double? {
        guard b.levelKnown, b.entry.control == .slider, isAvailable(b) else { return nil }
        return clamp01(b.levelShown.value)
    }

    /// The name the hub shows for a bubble, with the state it reads.
    func labelText(for b: Bubble) -> String {
        let title = b.entry.title
        guard let item = b.entry.item else { return title }
        let state = live(item)
        if state?.available == false { return title + " · Unavailable" }
        guard let detail = state?.detail, !detail.isEmpty else { return title }
        return title + " · " + detail
    }

    /// The widest a line of the hub's label gets. A longer label takes a second line: the
    /// reading under the name, or the words that don't fit.
    static let labelLineWidth = 104.0

    func wrapLabel(_ text: String) -> String {
        let limit = Self.labelLineWidth
        guard !text.contains("\n"), labelWidth(text) > limit else { return text }
        var lines: [String]
        if let split = text.range(of: " · ") {
            lines = [String(text[..<split.lowerBound]), String(text[split.upperBound...])]
        } else {
            var first = ""
            var words = text.split(separator: " ").map(String.init)
            while let word = words.first, first.isEmpty || labelWidth(first + " " + word) <= limit {
                first = first.isEmpty ? word : first + " " + word
                words.removeFirst()
            }
            lines = [first, words.joined(separator: " ")].filter { !$0.isEmpty }
        }
        return lines.map { fit($0, limit) }.joined(separator: "\n")
    }

    /// The text cut short with an ellipsis to fit `width`.
    private func fit(_ text: String, _ width: Double) -> String {
        guard labelWidth(text) > width else { return text }
        var cut = text
        while !cut.isEmpty, labelWidth(cut + "…") > width { cut.removeLast() }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The width of a label's widest line, and how many lines it has.
    func labelSize(_ text: String) -> (width: Double, lines: Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return (lines.map { labelWidth(String($0)) }.max() ?? 0, max(lines.count, 1))
    }

    static func shortened(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }

    /// Puts the label in line with the state, without fading between two texts when only the
    /// reading changed.
    func refreshLabel() {
        guard phase == .open, !config.active else { return }
        if let b = hoveredBubble {
            setLabel(labelText(for: b), instant: true)
        } else if let level = levels.last, case .picker(let id) = level.kind, !hoverBack,
                  let detail = live(store.item(id))?.detail, !detail.isEmpty {
            setLabel(detail, instant: true)
        }
    }

    // MARK: Scrolling

    /// A turn of a scroll wheel, including a side wheel, or a swipe on a trackpad, while the wheel is
    /// open. `up` and `right` are in notches for a wheel and in points for a trackpad, positive
    /// for a wheel turned away from the hand or to the right, whatever the scrolling direction
    /// setting. Over a slider it changes the level; over a stepper it steps.
    func scroll(up: Double, right: Double, precise: Bool) {
        guard phase == .open, !config.active, let controls else { return }
        let item: WheelItem?
        if let level = levels.last, case .control(let id) = level.kind {
            item = store.item(id)
        } else {
            item = hoveredBubble?.entry.item
        }
        guard let item, let control = item.actionID.flatMap(ActionCatalog.action)?.control else { return }
        switch control {
        case .slider:
            guard live(item)?.available != false, let current = live(item)?.level ?? controls.level(item) else { return }
            let detent = controls.detent(item)
            // A trackpad's points move it smoothly; a flick can't throw it end to end.
            let change = precise ? min(max((up + right) / 300, -0.06), 0.06) : (up + right) * detent
            setLevel(of: item, to: current + change)
            // Scrolling an open bar past its end gives it a nudge that springs back.
            if let bar = levels.last, bar.isControl, current + change > 1 || current + change < 0 {
                bar.barStretch.velocity += (current + change > 1 ? 1 : -1) * 260
            }
            // The bar's cursor mapping starts again from here, so the cursor doesn't undo it.
            if var drive = barDrive {
                drive.anchorValue = clamp01(current + change)
                drive.anchorAlong = barAlong(cursor)
                barDrive = drive
            }
        case .stepper:
            // Down and right step forward, as through a list.
            scrollCarry += precise ? (right - up) / 36 : right - up
            let notches = Int(scrollCarry.rounded(.towardZero))
            guard notches != 0 else { return }
            scrollCarry -= Double(notches)
            controls.step(item, by: notches)
            onDetent?()
            if let b = hoveredBubble { b.radius.velocity += 90 * Double(notches.signum()) }
        default:
            break
        }
    }

    /// Writes a slider's level and shows it at once, ticking for each detent crossed.
    func setLevel(of item: WheelItem, to value: Double) {
        guard let controls else { return }
        let next = clamp01(value)
        let before = live(item)?.level ?? next
        guard abs(next - before) > 0.0005 else { return }
        controls.setLevel(item, next)
        adjustedAt[item.id] = time
        var state = liveStates[item.id] ?? LiveState()
        state.level = next
        state.detail = controls.format(item, level: next) ?? state.detail
        state.symbol = controls.liveSymbol(item) ?? state.symbol
        liveStates[item.id] = state
        let detent = max(controls.detent(item), 0.001)
        if next == 0 || next == 1 {
            onLimit?()
        } else if Int((before / detent).rounded(.down)) != Int((next / detent).rounded(.down)) {
            onDetent?()
        }
        for b in bubbles where b.entry.item?.id == item.id {
            b.levelShown.target = next
        }
        refreshLabel()
    }

    // MARK: Bars

    static let barLength = 232.0
    static let barThickness = 56.0

    /// Turns a slider's bubble into a bar laid along the ring, its knob under the bubble so the
    /// level doesn't jump. `springLoaded` closes it again when the button comes up after a drag.
    func openBar(_ b: Bubble, springLoaded: Bool) {
        guard let parent = levels.last, let item = b.entry.item, let controls else { return }
        guard live(item)?.available != false, let value = live(item)?.level ?? controls.level(item) else {
            refuse(b)
            return
        }
        let t = tuning
        let phi = parent.angle(b.slot)
        let home = parent.center + t.ringRadius * V2(cos(phi), sin(phi))
        // Beside the wheel the bar stands upright, raising the level upward. Above or below
        // it lies flat, raising it to the right. Either way it keeps clear of the parent ring.
        let upright = abs(cos(phi)) > 0.75
        let axis = upright ? V2(0, -1) : V2(1, 0)
        let length = Self.barLength
        // The fill's edge starts under the cursor.
        let travel = length - 2 * Self.barRim
        var center = home - axis * ((value - 0.5) * travel)
        let clearance = t.ringRadius * t.parentScale + 32 + Self.barThickness / 2
        if upright {
            let side = center.x - parent.center.x
            if abs(side) < clearance { center.x = parent.center.x + (side < 0 ? -clearance : clearance) }
        } else {
            let side = center.y - parent.center.y
            if abs(side) < clearance { center.y = parent.center.y + (side < 0 ? -clearance : clearance) }
        }
        let half = upright ? V2(Self.barThickness / 2, length / 2) : V2(length / 2, Self.barThickness / 2)
        center = clampPanel(center, half)

        enter(b, as: .control(item.id), center: center)
        guard let bar = levels.last, bar.isControl else { return }
        bar.barAxis = axis
        bar.barLength = length
        bar.barHome = home
        bar.barShown.snap(value)
        let morph = t.stagger > 0 ? SpringConfig(k: 480, c: 32) : t.panelSize
        bar.hubHalfW.config = morph
        bar.hubHalfH.config = morph
        barDrive = BarDrive(anchorValue: value, anchorAlong: barAlong(cursor), springLoaded: springLoaded, pressOrigin: cursor)
        var state = liveStates[item.id] ?? LiveState()
        state.level = value
        liveStates[item.id] = state
    }

    /// The cursor's place along the open bar's axis, in points from its center.
    func barAlong(_ p: V2) -> Double {
        guard let bar = levels.last, bar.isControl else { return 0 }
        return simd_dot(p - bar.center, bar.barAxis)
    }

    /// The open bar's level follows the cursor along it, from wherever the two were last tied
    /// together. Past an end the level stays at the end, and coming back moves it at once.
    func stepBar() {
        guard phase == .open, let bar = levels.last, case .control(let id) = bar.kind,
              var drive = barDrive, let item = store.item(id) else { return }
        let travel = Self.barTravel(bar)
        let along = barAlong(cursor)
        let across = abs(simd_dot(cursor - bar.center, V2(-bar.barAxis.y, bar.barAxis.x)))
        // Far off to the side the bar lets go of the cursor, so moving away doesn't change it.
        let near = across < Self.barThickness / 2 + 70 && abs(along) < bar.barLength / 2 + 90
        if !near {
            drive.engaged = false
            barDrive = drive
            bar.barStretch.target = 0
            bar.barGrow.target = 0
            return
        }
        if !drive.engaged {
            drive.engaged = true
            drive.anchorValue = live(item)?.level ?? drive.anchorValue
            drive.anchorAlong = along
        }
        if drive.springLoaded, simd_distance(cursor, drive.pressOrigin) > tuning.dragSlop { drive.dragged = true }
        barDrive = drive
        // The fill follows the cursor point for point. Past an end it stays full or empty, and
        // the bar itself is pulled after the cursor, less the further it goes, as on iOS.
        let raw = drive.anchorValue + (along - drive.anchorAlong) / travel
        let value = clamp01(raw)
        let over = (raw - value) * travel
        bar.barStretch.target = over == 0 ? 0 : (over > 0 ? 1 : -1) * Self.rubber(abs(over), limit: 42)
        // Held, or with the cursor on it, it swells a little under the hand.
        let onBar = across < Self.barThickness / 2 + 8 && abs(along) < bar.barLength / 2 + 8
        bar.barGrow.target = drive.springLoaded || onBar ? 1 : 0
        setLevel(of: item, to: value)
    }

    /// How far the cursor moves along a bar to take it from empty to full: the length of its fill.
    static func barTravel(_ bar: Level) -> Double {
        max(bar.barLength - 2 * barRim, 1)
    }

    /// The space between a bar's outline and its fill.
    static let barRim = 3.0

    /// Resistance that grows with distance: the first points follow almost one for one, and
    /// no pull gets past `limit`.
    static func rubber(_ distance: Double, limit: Double) -> Double {
        (1 - 1 / (distance * 0.55 / limit + 1)) * limit
    }

    /// Where the open bar's fill ends, its ends, and its thickness, for drawing. A bar pulled
    /// past an end is longer on that side and a little thinner, and a held bar is a little larger.
    func barGeometry(_ level: Level) -> (low: V2, high: V2, knob: V2, value: Double, thickness: Double)? {
        guard level.isControl else { return nil }
        let value = clamp01(level.barShown.value)
        let axis = level.barAxis
        let open = barOpenness(level)
        let grow = 1 + 0.045 * clamp01(level.barGrow.value) * open
        let stretch = level.barStretch.value * open
        let halfLength = max(abs(axis.x) > 0.5 ? level.hubHalfW.value : level.hubHalfH.value, 0) * grow
        var thickness = max(abs(axis.x) > 0.5 ? level.hubHalfH.value : level.hubHalfW.value, 0) * 2 * (1 + 0.07 * clamp01(level.barGrow.value) * open)
        thickness *= 1 - 0.12 * min(abs(stretch) / 42, 1)
        let p = hubDisplayPosition(level)
        var low = p - axis * halfLength
        var high = p + axis * halfLength
        if stretch > 0 { high += axis * stretch } else { low += axis * stretch }
        let span = simd_distance(low, high)
        let fill = low + axis * (Self.barRim + value * max(span - 2 * Self.barRim, 0))
        return (low, high, fill, value, thickness)
    }

    /// The corners of a bar: round like its bubble while it opens, then those of a slider in
    /// Control Center.
    func barCorner(_ level: Level, thickness: Double) -> Double {
        let open = barOpenness(level)
        return thickness / 2 * (1 - open) + min(thickness / 2, 19) * open
    }

    /// The bar as one rounded box, for the goo.
    func barBlob(_ level: Level) -> Blob? {
        guard let g = barGeometry(level), g.thickness > 0.6 else { return nil }
        let along = simd_distance(g.low, g.high) / 2
        let half = abs(level.barAxis.x) > 0.5 ? V2(along, g.thickness / 2) : V2(g.thickness / 2, along)
        return Blob(center: (g.low + g.high) / 2, half: half, corner: min(barCorner(level, thickness: g.thickness), half.x, half.y),
                    tint: clamp01(level.hubTint.value), alpha: clamp01(level.alpha.value), color: level.color?.rgb)
    }

    /// The reading an open bar shows at its high end, such as "45%".
    func barReading(_ level: Level) -> String? {
        guard let id = level.itemID, let item = store.item(id), let value = live(item)?.level else { return nil }
        return controls?.format(item, level: value) ?? "\(Int((value * 100).rounded()))%"
    }

    /// The glyph for a bar's level, such as a speaker with more waves.
    func levelSymbol(_ level: Level) -> String? {
        guard let id = level.itemID, let item = store.item(id) else { return nil }
        if let custom = item.customSymbol, !custom.isEmpty { return custom }
        return live(item)?.symbol ?? item.symbol
    }

    /// 0 while a bar is still its bubble, 1 once it has its full length.
    func barOpenness(_ level: Level) -> Double {
        guard level.isControl, level.barLength > 0 else { return 0 }
        let axis = level.barAxis
        let halfLength = abs(axis.x) > 0.5 ? level.hubHalfW.value : level.hubHalfH.value
        return clamp01((halfLength - tuning.bubbleRadius) / (level.barLength / 2 - tuning.bubbleRadius))
    }

    /// The bar's hub target size: its full length, or the bubble it closes back into.
    func barTarget(_ level: Level) -> V2 {
        if level.role == .dying { return V2(tuning.bubbleRadius, tuning.bubbleRadius) }
        let half = V2(level.barLength / 2, Self.barThickness / 2)
        return abs(level.barAxis.x) > 0.5 ? half : V2(half.y, half.x)
    }

    // MARK: Pickers

    /// Runs one of a picker's choices. One that leaves the picker open, such as Next, gives
    /// a pulse and the choices are read again; any other closes the wheel like a choice does.
    func choose(_ b: Bubble) {
        guard case .choice(let id, let choice) = b.entry, let item = store.item(id), let controls else { return }
        if choice.keepsOpen, mode == .sticky {
            controls.choose(choice, of: item)
            b.radius.velocity += 220
            onHover?()
            // The state behind the choices changes a moment later, such as play turning to pause.
            pendingRefresh = time + 0.25
            return
        }
        onChoose?(choice, item)
        b.radius.velocity += 240
        closeAfterChoosing(b)
    }

    /// Reads a picker's choices again and lets its ring follow them.
    func refreshChoices() {
        for level in levels {
            guard case .picker = level.kind else { continue }
            level.entries = entries(for: level.kind)
            reconcile(level)
        }
    }

    /// A choice that can't be made, or an item this Mac can't run: the bubble shakes its head.
    func refuse(_ b: Bubble) {
        b.shake.velocity += tuning.stagger > 0 ? 340 : 0
        onRefuse?()
    }

    /// A refused bubble shakes its head: back and forth across the ring, settling where it was.
    func shakeOffset(_ b: Bubble) -> V2 {
        let v = b.pos.value - b.level.center
        let length = simd_length(v)
        guard length > 1 else { return V2(0, 0) }
        return V2(-v.y, v.x) / length * b.shake.value
    }
}
