import AppKit
import simd

enum DemoScript: String {
    /// Opening, hovering, folders, and picking.
    case wheel
    /// Configuration: removing, adding, the editing panels, and dragging.
    case configure
}

/// Where the demo's opaque backdrop goes: the bottom-right corner of the screen, no larger
/// than its script needs.
enum DemoStage {
    static let cornerRadius: CGFloat = 36
    private static let margin: CGFloat = 12

    static func size(for script: DemoScript) -> CGSize {
        switch script {
        case .wheel: return CGSize(width: 860, height: 660)
        // The editing panels are wider than the wheel.
        case .configure: return CGSize(width: 1100, height: 840)
        }
    }

    /// The stage's frame in screen coordinates.
    static func frame(for script: DemoScript, on screen: NSScreen) -> CGRect {
        let size = size(for: script)
        let visible = screen.visibleFrame
        return CGRect(x: visible.maxX - size.width - margin, y: visible.minY + margin, width: size.width, height: size.height)
    }

    /// The wheel opens at the stage's center. The small stage puts it a little left of
    /// center, which leaves room for a folder opening to the right.
    static func wheelCenter(in frame: CGRect, script: DemoScript) -> CGPoint {
        CGPoint(x: frame.midX - (script == .wheel ? 50 : 0), y: frame.midY)
    }

    /// The part of the stage inside its rounded corners, as `x,y,width,height` measured from
    /// the top-left of the main display, which is what `screencapture -R` takes.
    static func captureRect(for script: DemoScript, on screen: NSScreen) -> String {
        let frame = frame(for: script, on: screen).insetBy(dx: 12, dy: 12)
        let top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - frame.maxY
        return [frame.minX, top, frame.width, frame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
    }
}

/// Moves a drawn cursor through a script and clicks, so the motion can be recorded without
/// touching the real pointer.
final class DemoDriver {
    enum Event {
        case open, click, press, release, secondaryClick, escape, undo, finish
        /// One scripted interaction inside the open editing panel.
        case editor(Int)
        /// Input sent through the demo's own window, as the system would deliver it, to
        /// exercise the views themselves: a click or a press at the cursor, and keys.
        case windowClick, windowPress, windowRelease
        case type(String)
        case key(String, code: UInt16, modifiers: NSEvent.ModifierFlags)
    }

    /// Where the cursor goes next: a point relative to where the wheel opened, or a place
    /// looked up in the wheel when the move starts.
    enum Target {
        case at(V2)
        case find((WheelSim) -> V2?)
    }

    struct Script {
        var path: [(Double, Target)]
        var events: [(Double, Event)]
        /// Named moments, for stills.
        var marks: [(String, Double)]
    }

    var origin = V2(0, 0)
    var anchor = CGPoint.zero
    private(set) var cursor = V2(0, 0)
    private var time = 0.0
    private var fired = 0
    private let script: Script
    /// The path's points in wheel coordinates, filled in as the cursor reaches them.
    private var resolved: [V2?]
    /// The path segment the cursor was on last frame.
    private var entered = 0
    private let exitWhenDone: Bool
    /// The script holds just before the events at this time.
    var stopAt: Double?
    var marks: [(String, Double)] { script.marks }
    /// The script has played to its end.
    private(set) var finished = false

    init(script: DemoScript, exitWhenDone: Bool, stopAt: Double?) {
        self.exitWhenDone = exitWhenDone
        self.stopAt = stopAt
        switch script {
        case .wheel: self.script = Self.wheelScript()
        case .configure: self.script = Self.configureScript()
        }
        resolved = Array(repeating: nil, count: self.script.path.count)
    }

    private static func wheelScript() -> Script {
        let s = 76.4 // ring radius on the diagonal
        let path: [(Double, V2)] = [
            (0.0, V2(0, 0)),
            (0.9, V2(0, 0)),
            (1.25, V2(s, -s)),          // Mission Control
            (1.6, V2(s, -s)),
            (2.3, V2(s, s)),            // sweep past Media to Emoji
            (2.6, V2(s, s)),
            (2.95, V2(0, 0)),           // back to the hub
            (3.2, V2(0, 0)),
            (3.55, V2(108, 0)),         // rest on Media, which opens
            (4.3, V2(108, 0)),
            (4.65, V2(206, -45)),       // Next
            (4.95, V2(206, -45)),
            (5.3, V2(139, -103)),       // Play/Pause
            (5.7, V2(139, -103)),
            (6.1, V2(10, 0)),           // rest on the parent ring, which returns
            (6.6, V2(10, 0)),
            (6.95, V2(108, 0)),         // Media again
            (7.5, V2(108, 0)),
            (7.85, V2(139, -103)),      // Play/Pause
            (9.2, V2(139, -103)),
        ]
        return Script(path: path.map { ($0.0, .at($0.1)) }, events: [(0.3, .open), (8.2, .click), (9.0, .finish)], marks: [])
    }

    /// A run that writes snapshots ends itself once the script has finished.
    var holdsAtEnd = false

    /// The script reached `stopAt`. Everything holds still from here, for a capture.
    var stopped: Bool { stopAt.map { time >= $0 } ?? false }

    private func point(_ index: Int, sim: WheelSim) -> V2 {
        if let p = resolved[index] { return p }
        let p: V2
        switch script.path[index].1 {
        case .at(let offset): p = origin + offset
        case .find(let find): p = find(sim) ?? (index > 0 ? point(index - 1, sim: sim) : origin)
        }
        resolved[index] = p
        return p
    }

    func advance(_ dt: Double, controller: WheelController) {
        time = min(time + dt, stopAt ?? .infinity)
        let path = script.path
        var next = path.count - 1
        for i in 1..<path.count where time < path[i].0 {
            next = i
            break
        }
        let from = point(max(next - 1, 0), sim: controller.sim)
        if next != entered {
            // A move's target is looked up only after the events at its start have fired:
            // a click there may be what opens the ring the target is in.
            entered = next
            cursor = from
        } else {
            let to = point(next, sim: controller.sim)
            let (t0, t1) = (path[max(next - 1, 0)].0, path[next].0)
            cursor = from + (to - from) * (t1 > t0 ? smooth01((time - t0) / (t1 - t0)) : 1)
        }
        controller.sim.cursor = cursor

        // A run that stops for a still holds just before an event at that moment.
        let events = script.events
        while fired < events.count, events[fired].0 <= time, events[fired].0 < stopAt ?? .infinity {
            let event = events[fired].1
            fired += 1
            switch event {
            case .open: controller.open(at: anchor, mode: .sticky, cursor: cursor)
            case .click:
                controller.pointerDown()
                controller.pointerUp()
            case .press: controller.pointerDown()
            case .release: controller.pointerUp()
            case .secondaryClick: controller.secondaryClick()
            case .escape: controller.sim.escape()
            case .undo: controller.sim.undo()
            case .editor(let step): controller.editorDemo(step)
            case .windowClick:
                controller.demoMouse(.leftMouseDown)
                controller.demoMouse(.leftMouseUp)
            case .windowPress: controller.demoMouse(.leftMouseDown)
            case .windowRelease: controller.demoMouse(.leftMouseUp)
            case .type(let text):
                for character in text { controller.demoKey(String(character)) }
            case .key(let characters, let code, let modifiers):
                controller.demoKey(characters, code: code, modifiers: modifiers)
            case .finish:
                finished = true
                if holdsAtEnd { return }
                if exitWhenDone {
                    NSApp.terminate(nil)
                } else {
                    time = 0
                    fired = 0
                    entered = 0
                    resolved = Array(repeating: nil, count: path.count)
                }
            }
        }
    }
}

/// Places in the wheel the demo's cursor aims for.
extension WheelSim {
    private func demoSlot(_ title: String) -> (level: Level, slot: Int)? {
        guard let level = levels.last, let slot = level.entries.firstIndex(where: { $0.title == title }) else { return nil }
        return (level, slot)
    }

    private func demoPoint(_ level: Level, _ angle: Double, _ radius: Double) -> V2 {
        level.center + radius * V2(cos(angle), sin(angle))
    }

    /// The resting place of the bubble with this name in the front ring.
    func demoHome(_ title: String) -> V2? {
        demoSlot(title).map { demoPoint($0.level, $0.level.angle($0.slot), tuning.ringRadius) }
    }

    func demoBadge(_ title: String) -> V2? {
        guard let (level, slot) = demoSlot(title) else { return nil }
        let offset = level.entries[slot].isFolder ? tuning.folderBadgeOffset : -tuning.badgeInset
        return demoPoint(level, level.angle(slot), tuning.ringRadius + tuning.bubbleRadius + offset)
    }

    /// A point on the ring part of the way from one bubble to another.
    func demoBetween(_ from: String, _ to: String, _ fraction: Double) -> V2? {
        guard let (level, a) = demoSlot(from), let (_, b) = demoSlot(to) else { return nil }
        let start = level.angle(a)
        return demoPoint(level, start + wrapAngle(level.angle(b) - start) * fraction, tuning.ringRadius)
    }

    func demoRing(_ degrees: Double, radius: Double? = nil) -> V2? {
        levels.last.map { demoPoint($0, degrees * .pi / 180, radius ?? tuning.ringRadius) }
    }

    /// A point near the front ring's hub, offset from it.
    func demoHub(_ offset: V2 = V2(0, 0)) -> V2? {
        levels.last.map { $0.center + offset }
    }

    /// A spot in the front ring that is on nothing: between its hub and its bubbles, on the
    /// side away from the parent ring.
    func demoClear() -> V2? {
        levels.last.map { demoPoint($0, $0.arcMid ?? .pi / 3, 54) }
    }

    func demoParent(_ offset: V2 = V2(0, 0)) -> V2? {
        levels.count >= 2 ? levels[levels.count - 2].center + offset : nil
    }

    /// The open panel's back or save button where it rests.
    func demoPanelButton(save: Bool) -> V2? {
        guard let e = config.editor else { return nil }
        let r = tuning.bubbleRadius
        let side: Double = save ? 1 : -1
        if e.shape.notched { return e.center + V2(side * (e.shape.half.x - r), e.shape.half.y - r) }
        return e.center + V2(side * (e.shape.half.x + Self.panelButtonGap + r), 0)
    }

    func demoPanel(_ offset: V2 = V2(0, 0)) -> V2? {
        config.editor.map { $0.center + offset }
    }
}
