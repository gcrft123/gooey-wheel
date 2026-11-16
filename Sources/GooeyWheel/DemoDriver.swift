import AppKit
import simd

enum DemoScript: String {
    /// Opening, hovering, folders, and picking.
    case wheel
    /// Configuration: removing, adding, the editing panels, and dragging.
    case configure
    /// In-item controls: a slider's level and bar, a picker, and toggles.
    case controls
    /// A bit of everything, for the welcome panel's video.
    case tour
}

/// Where the demo's opaque backdrop goes: the bottom-right corner of the screen, no larger
/// than its script needs.
enum DemoStage {
    static let cornerRadius: CGFloat = 36
    private static let margin: CGFloat = 12

    static func size(for script: DemoScript) -> CGSize {
        switch script {
        case .wheel: return CGSize(width: 860, height: 660)
        case .tour: return CGSize(width: 760, height: 640)
        // The editing panels are wider than the wheel.
        case .configure, .controls: return CGSize(width: 1100, height: 840)
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
        CGPoint(x: frame.midX - (script == .wheel || script == .tour ? 50 : 0), y: frame.midY)
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
    /// The toggle the tour rests on in the Controls folder, one that is on.
    #if APPSTORE
    static let tourToggle = "Keep Awake"
    #else
    static let tourToggle = "Do Not Disturb"
    #endif

    enum Event {
        case open, click, press, release, secondaryClick, escape, undo, finish
        /// A turn of the scroll wheel, in notches away from the hand.
        case scroll(Double)
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
        self.script = Self.steps(of: script)
        resolved = Array(repeating: nil, count: self.script.path.count)
    }

    static func steps(of script: DemoScript) -> Script {
        switch script {
        case .wheel: return wheelScript()
        case .configure: return configureScript()
        case .controls: return controlsScript()
        case .tour: return tourScript()
        }
    }

    private static func wheelScript() -> Script {
        var b = Builder()
        b.wait(0.3)
        b.fire(.open)
        b.wait(0.6)
        b.move { $0.demoHome("Mission Control") }
        b.wait(0.35)
        b.mark("hover")
        // A sweep past Media Controls, which opens only when the cursor rests on it.
        b.move(0.7) { $0.demoHome("Volume") }
        b.wait(0.3)
        b.move { $0.demoHub() }
        b.wait(0.25)
        b.move { $0.demoHome("Controls") }
        b.wait(0.75)
        b.mark("folder-open")
        b.move { $0.demoHome("Mute Microphone") }
        b.wait(0.3)
        b.move { $0.demoHome("Mute") }
        b.wait(0.4)
        b.mark("folder-hover")
        // Resting on the parent ring returns to it.
        b.move(0.4) { $0.demoParent(V2(10, 0)) }
        b.wait(0.5)
        b.mark("returned")
        b.move { $0.demoHome("Controls") }
        b.wait(0.55)
        b.move { $0.demoHome("Mute") }
        b.wait(0.35)
        b.fire(.click)
        b.mark("picked", after: 0.2)
        b.wait(0.8)
        b.fire(.finish)
        return b.script
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
            case .scroll(let notches): controller.sim.scroll(up: notches, right: 0, precise: false)
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

/// States the scripted demo shows in place of this Mac's, so a recording neither reads nor
/// changes anything real.
final class DemoControls: ControlSource {
    private var levels: [String: Double] = ["media.volume": 0.45, "system.brightness": 0.7, "system.keyboardBrightness": 0.3, "mouse.pointerSpeed": 0.5]
    #if APPSTORE
    private var toggles: [String: Bool] = ["media.mute": false, "system.micMute": false, "system.keepAwake": true]
    #else
    private var toggles: [String: Bool] = ["system.doNotDisturb": true, "system.appearance": true, "media.mute": false, "system.micMute": false, "system.keepAwake": false]
    #endif
    private var playing = true
    private var output = "studio"

    private func id(_ item: WheelItem) -> String { item.actionID ?? "" }

    /// One item the demo pretends this Mac can't run, to show a refusal. Only the controls
    /// script shows one.
    var refuses = false
    func isAvailable(_ item: WheelItem) -> Bool { !refuses || id(item) != "desktop.switchApps" }
    func isOn(_ item: WheelItem) -> Bool? { toggles[id(item)] }

    func liveSymbol(_ item: WheelItem) -> String? {
        switch id(item) {
        case "media.volume":
            let v = levels["media.volume"] ?? 0
            return v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case "media.playPause": return playing ? "pause.fill" : "play.fill"
        default: return nil
        }
    }

    func detail(_ item: WheelItem) -> String? {
        if let level = level(item) { return format(item, level: level) }
        if let on = isOn(item) { return on ? "On" : "Off" }
        switch id(item) {
        case "media.controls", "media.playPause": return "Clair de Lune — Debussy"
        case "media.output": return "Studio Display Speakers"
        case WheelActions.customize: return "Or right-click"
        default: return nil
        }
    }

    func level(_ item: WheelItem) -> Double? { levels[id(item)] }
    func setLevel(_ item: WheelItem, _ value: Double) { levels[id(item)] = value }
    func detent(_ item: WheelItem) -> Double { 1.0 / 32 }
    func format(_ item: WheelItem, level: Double) -> String? { "\(Int((level * 100).rounded()))%" }
    func step(_ item: WheelItem, by notches: Int) {}

    func choices(_ item: WheelItem) -> [LiveChoice] {
        switch id(item) {
        case "media.controls":
            return [
                LiveChoice(id: "previous", title: "Previous", symbol: "backward.fill", keepsOpen: true),
                LiveChoice(id: "playPause", title: playing ? "Pause" : "Play", symbol: playing ? "pause.fill" : "play.fill", keepsOpen: true),
                LiveChoice(id: "next", title: "Next", symbol: "forward.fill", keepsOpen: true),
            ]
        case "media.output":
            return [
                LiveChoice(id: "studio", title: "Studio Display Speakers", symbol: "display", isCurrent: output == "studio"),
                LiveChoice(id: "airpods", title: "AirPods Pro", symbol: "airpods", isCurrent: output == "airpods"),
                LiveChoice(id: "speakers", title: "Desk Speakers", symbol: "hifispeaker.fill", isCurrent: output == "speakers"),
            ]
        default:
            return []
        }
    }

    func choose(_ choice: LiveChoice, of item: WheelItem) {
        if choice.id == "playPause" { playing.toggle() }
        if id(item) == "media.output" { output = choice.id }
    }
}
