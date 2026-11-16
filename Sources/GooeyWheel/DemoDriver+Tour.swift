import Foundation
import simd

extension DemoDriver {
    /// A bit of everything on the wheel a new user gets, for the welcome panel's video: pointing,
    /// a slider and its bar, a picker, a folder, and rearranging and making a folder in
    /// configuration. It starts and ends with the wheel closed, so the video loops without a jump.
    static func tourScript() -> Script {
        var b = Builder()
        b.wait(0.4)
        b.fire(.open)
        b.wait(0.7)
        // Pointing: a bubble, then a sweep across the ring.
        b.move { $0.demoHome("Mission Control") }
        b.wait(0.45)
        b.move(0.6) { $0.demoHome("Screenshot") }
        b.wait(0.35)

        // A slider: scrolled, then pressed into a bar and dragged.
        b.move(0.4) { $0.demoHome("Volume") }
        b.wait(0.45)
        for _ in 0..<4 {
            b.fire(.scroll(1))
            b.wait(0.08)
        }
        b.wait(0.35)
        b.fire(.press)
        b.wait(0.55)
        b.mark("bar")
        b.move(0.5) { $0.demoBarPoint(0.2) }
        b.wait(0.25)
        b.move(0.55) { $0.demoBarPoint(0.85) }
        b.wait(0.2)
        b.fire(.release)
        b.wait(0.6)

        // A picker opens like a folder. Its choices here act and leave it open.
        b.move { $0.demoHome("Media Controls") }
        b.wait(0.8)
        b.mark("picker")
        b.move { $0.demoHome("Pause") }
        b.wait(0.4)
        b.fire(.click)
        b.wait(0.45)
        b.mark("picker-chosen")
        // Resting on the ring it came from goes back.
        b.move(0.4) { $0.demoParent() }
        b.wait(0.35)

        // A folder of toggles, each showing its state.
        b.move { $0.demoHome("Controls") }
        b.wait(0.8)
        b.mark("folder")
        b.move { $0.demoHome(DemoDriver.tourToggle) }
        b.wait(0.45)
        b.move(0.4) { $0.demoParent() }
        b.wait(0.35)

        // Customize starts configuration. The bubbles jiggle, and one is dragged along
        // the ring.
        b.move { $0.demoHome("Customize") }
        b.wait(0.4)
        b.fire(.click)
        b.wait(0.8)
        b.mark("configure")
        b.move { $0.demoHome("Screenshot") }
        b.wait(0.25)
        b.fire(.press)
        b.move(0.35) { $0.demoBetween("Screenshot", "Customize", 0.5) }
        b.move(0.35) { $0.demoBetween("Customize", "Previous App", 0.35) }
        b.wait(0.4)
        b.fire(.release)
        b.wait(0.65)

        // One bubble dropped onto another makes a folder of the two, and its edit ring opens.
        b.move { $0.demoHome("Volume") }
        b.wait(0.25)
        b.fire(.press)
        b.move(0.45) { $0.demoBetween("Volume", "Media Controls", 0.8) }
        b.wait(0.35)
        b.mark("folder-made")
        b.fire(.release)
        b.wait(1.35)
        b.mark("folder-edit")
        b.fire(.escape)
        b.wait(0.7)
        // A right-click on the center, where the cursor points at nothing, ends configuration.
        b.move(0.4) { $0.demoHub() }
        b.wait(0.15)
        b.fire(.secondaryClick)
        b.wait(0.5)

        // Picking an item closes the wheel.
        b.move { $0.demoHome("Mission Control") }
        b.wait(0.4)
        b.fire(.click)
        b.wait(0.9)
        // Back to where the cursor started, so the loop has no jump.
        b.move(V2(0, 0), 0.6)
        b.wait(0.3)
        b.mark("end")
        b.fire(.finish)
        return b.script
    }
}
