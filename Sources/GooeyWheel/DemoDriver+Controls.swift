import Foundation
import simd

extension DemoDriver {
    /// The in-item controls: a slider's level read on its rim and changed by scrolling, the
    /// bar it turns into when pressed, a toggle's state, and a picker's choices.
    static func controlsScript() -> Script {
        var b = Builder()
        b.wait(0.3)
        b.fire(.open)
        b.wait(0.6)
        // A slider: its level is on its rim, and scrolling changes it.
        b.move { $0.demoHome("Volume") }
        b.wait(0.5)
        b.mark("volume-hover")
        for _ in 0..<4 {
            b.fire(.scroll(1))
            b.wait(0.08)
        }
        b.wait(0.4)
        b.mark("volume-scrolled")
        // Pressing turns it into a bar under the cursor. Dragging along it sets the level,
        // and letting go turns it back.
        b.fire(.press)
        b.wait(0.12)
        b.mark("bar-opening")
        b.wait(0.5)
        b.mark("bar-open")
        b.move(0.6) { sim in sim.demoBarPoint(0.85) }
        b.wait(0.3)
        b.mark("bar-drag-up")
        // Past the top the fill stays full and the bar is pulled after the cursor.
        b.move(0.45) { sim in sim.demoBarPoint(1.35) }
        b.wait(0.15)
        b.mark("bar-stretched")
        b.move(0.6) { sim in sim.demoBarPoint(0.2) }
        b.wait(0.3)
        b.mark("bar-drag-down")
        b.fire(.release)
        b.wait(0.12)
        b.mark("bar-closing")
        b.wait(0.7)
        b.mark("bar-closed")
        // Into the Controls folder
        b.move { $0.demoHome("Controls") }
        b.wait(0.9)
        b.mark("folder-open")
        // A toggle shows its state in the hub.
        b.move { $0.demoHome("Mute") }
        b.wait(0.5)
        b.mark("toggle-hover")
        // A long label takes two lines.
        b.move { $0.demoHome("Mute Microphone") }
        b.wait(0.5)
        b.mark("label-wrapped")
        // A picker opens like a folder, its choice in effect lit.
        b.move { $0.demoHome("Sound Output") }
        b.wait(0.9)
        b.mark("picker-open")
        b.move { $0.demoHome("AirPods Pro") }
        b.wait(0.5)
        b.mark("picker-hover")
        b.fire(.escape)
        b.wait(0.6)
        b.fire(.escape)
        b.wait(0.7)
        b.mark("back-root")
        // An item this Mac can't run shakes its head.
        b.move { $0.demoHome("Previous App") }
        b.wait(0.4)
        b.fire(.click)
        b.mark("refused")
        b.wait(0.8)
        b.fire(.finish)
        return b.script
    }
}

extension WheelSim {
    /// A point a fraction of the way along the open bar, from its low end.
    func demoBarPoint(_ fraction: Double) -> V2? {
        guard let bar = levels.last, bar.isControl else { return nil }
        return bar.center + bar.barAxis * ((fraction - 0.5) * Self.barTravel(bar))
    }
}
