import Foundation
import simd

extension DemoDriver {
    /// A bit of everything, for the welcome panel's video: pointing, a folder, a slider and its
    /// bar, a picker, rearranging and making a folder in configuration, and picking an item. It starts
    /// and ends with the wheel closed, so the video loops without a jump.
    static func tourScript() -> Script {
        var b = Builder()
        b.wait(0.4)
        b.fire(.open)
        b.wait(0.7)
        // Pointing: a bubble, then a sweep across the bottom of the ring.
        b.move { $0.demoHome("Mission Control") }
        b.wait(0.45)
        b.move(0.6) { $0.demoHome("Paste") }
        b.wait(0.35)
        b.move { $0.demoHub() }
        b.wait(0.25)

        // A folder, and a slider inside it: scrolled, then pressed into a bar and dragged.
        b.move { $0.demoHome("Media") }
        b.wait(0.9)
        b.mark("folder")
        b.move { $0.demoHome("Volume") }
        b.wait(0.45)
        for _ in 0..<4 {
            b.fire(.scroll(1))
            b.wait(0.08)
        }
        b.wait(0.35)
        b.fire(.press)
        b.wait(0.55)
        b.mark("bar")
        b.move(0.5) { $0.demoBarPoint(0.9) }
        b.wait(0.25)
        b.move(0.55) { $0.demoBarPoint(0.25) }
        b.wait(0.2)
        b.fire(.release)
        b.wait(0.6)

        // A picker opens like a folder.
        b.move { $0.demoHome("Sound Output") }
        b.wait(0.9)
        b.mark("picker")
        b.move { $0.demoHome("AirPods Pro") }
        b.wait(0.45)
        b.fire(.escape)
        b.wait(0.55)
        b.fire(.escape)
        b.wait(0.5)

        // Configuration starts with a right-click on the center, where the cursor points at
        // nothing. The bubbles jiggle, and one is dragged along the ring.
        b.move(0.45) { $0.demoHub() }
        b.wait(0.2)
        b.fire(.secondaryClick)
        b.wait(0.8)
        b.mark("configure")
        b.move { $0.demoHome("Lock Screen") }
        b.wait(0.25)
        b.fire(.press)
        b.move(0.35) { $0.demoBetween("Lock Screen", "Paste", 0.5) }
        b.move(0.35) { $0.demoBetween("Paste", "Apps", 0.35) }
        b.wait(0.4)
        b.fire(.release)
        b.wait(0.8)

        // One bubble dropped onto another makes a folder of the two, and its edit ring opens.
        b.move { $0.demoHome("Paste") }
        b.wait(0.25)
        b.fire(.press)
        b.move(0.45) { $0.demoBetween("Paste", "Emoji & Symbols", 0.8) }
        b.wait(0.35)
        b.mark("folder-made")
        b.fire(.release)
        b.wait(1.5)
        b.mark("folder-edit")
        b.fire(.escape)
        b.wait(0.8)
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
