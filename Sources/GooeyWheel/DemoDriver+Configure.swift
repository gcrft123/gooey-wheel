import Foundation
import simd

extension DemoDriver {
    /// Builds a script from steps that each take some time, so a step can be added without
    /// renumbering the ones after it.
    struct Builder {
        var script = Script(path: [(0, .at(V2(0, 0)))], events: [], marks: [])
        var time = 0.0

        mutating func wait(_ seconds: Double) {
            time += seconds
            // Holding still is a move to wherever the cursor already is.
            script.path.append((time, .find { _ in nil }))
        }

        mutating func move(_ p: V2, _ seconds: Double = 0.35) {
            time += seconds
            script.path.append((time, .at(p)))
        }

        mutating func move(_ seconds: Double = 0.35, to find: @escaping (WheelSim) -> V2?) {
            time += seconds
            script.path.append((time, .find(find)))
        }

        mutating func fire(_ event: Event) {
            script.events.append((time, event))
        }

        mutating func click(hold: Double = 0.3, _ find: @escaping (WheelSim) -> V2?) {
            move(to: find)
            wait(hold)
            fire(.click)
        }

        /// Names this moment, for capturing a still of it with `--demo-stop-at`.
        mutating func mark(_ name: String, after delay: Double = 0) {
            script.marks.append((name, time + delay))
        }

        /// Does one thing inside the open panel and waits for it to show.
        mutating func editor(_ step: Int, mark name: String? = nil, wait seconds: Double = 0.55) {
            fire(.editor(step))
            wait(seconds)
            if let name { mark(name) }
        }

        /// Moves to a named place in the open panel and clicks it through the window, the
        /// way a real click arrives.
        mutating func panelClick(_ name: String, hold: Double = 0.25) {
            move { $0.panelPoint?(name) }
            wait(hold)
            fire(.windowClick)
        }

        mutating func panelMove(_ name: String, _ seconds: Double = 0.3) {
            move(seconds) { $0.panelPoint?(name) }
        }

        /// Types into whatever has the keyboard in the panel.
        mutating func type(_ text: String, mark name: String? = nil, wait seconds: Double = 0.5) {
            fire(.type(text))
            wait(seconds)
            if let name { mark(name) }
        }

        /// Clicks the open panel's save button and waits for the panel to close.
        mutating func save(mark name: String) {
            move { $0.demoPanelButton(save: true) }
            wait(0.3)
            mark(name + "-save")
            fire(.windowClick)
            mark(name + "-closing", after: 0.16)
            wait(1.1)
            mark(name + "-saved")
        }

        /// Clicks an edit option and waits for its panel to open.
        mutating func open(_ option: EditOption, mark name: String) {
            click { $0.demoHome(option.title) }
            mark(name + "-opening", after: 0.14)
            wait(1.2)
            mark(name + "-open")
        }
    }

    /// The moments of the configuration script worth a still, with their script times.
    static var configureMarks: [(String, Double)] { configureScript().marks }

    static func configureScript() -> Script {
        var b = Builder()
        let rest = V2(34, 46)
        b.wait(0.3)
        b.fire(.open)
        b.wait(0.7)
        // Normal use first: pointing from just outside the hub, then from the bubble itself.
        b.move(V2(23, -23))
        b.wait(0.5)
        b.mark("normal-near")
        b.move { $0.demoHome("Mission Control") }
        b.wait(0.5)
        b.mark("normal-hover")
        b.fire(.secondaryClick)                 // configuration starts
        b.move(rest)
        b.wait(0.9)
        b.mark("rest-full")

        // Remove, undo, remove again
        b.move { $0.demoHome("Mission Control") }
        b.wait(0.35)
        b.mark("hover-item")
        b.move { $0.demoBadge("Mission Control") }
        b.wait(0.4)
        b.mark("hover-remove")
        b.fire(.click)
        b.mark("removing", after: 0.1)
        b.wait(0.9)
        b.fire(.undo)
        b.mark("undo", after: 0.14)
        b.wait(0.9)
        b.fire(.click)
        b.move(rest)
        b.wait(0.8)
        b.mark("rest")

        // Add, then back out: the new item is dropped
        b.move { $0.demoHub() }
        b.wait(0.35)
        b.mark("hover-add")
        b.fire(.click)
        b.mark("adding", after: 0.16)
        b.mark("add-opening", after: 0.56)
        b.mark("back-emerging", after: 0.78)
        b.mark("back-emerged", after: 0.95)
        b.wait(1.7)
        b.mark("add-open")
        // The back button, clicked through the window like a real click.
        b.move { $0.demoPanelButton(save: false) }
        b.wait(0.4)
        b.mark("back-hover")
        b.fire(.windowPress)
        b.wait(0.12)
        b.mark("back-press")
        b.fire(.windowRelease)
        b.mark("add-discard", after: 0.2)
        b.wait(1.2)

        // Add again. In the panel, open a category, pick an action, search the app list, and
        // pick an app, all with clicks and keys sent through the window. Then save.
        b.click { $0.demoHub() }
        b.wait(1.7)
        b.panelMove("row:media")
        b.wait(0.3)
        b.mark("list-hover")
        b.panelMove("row:system", 0.36)
        b.mark("list-glide", after: -0.2)
        b.panelClick("row:apps")
        b.mark("accordion-opening", after: 0.09)
        b.wait(0.8)
        b.mark("accordion-open")
        b.panelClick("row:apps.open")
        b.mark("save-emerging", after: 0.1)
        b.mark("save-emerged", after: 0.24)
        b.wait(0.7)
        b.mark("action-chosen")
        b.panelClick("setting:search")
        b.type("saf", mark: "app-search")
        b.panelClick("setting:com.apple.Safari")
        b.wait(0.5)
        b.mark("add-app")
        b.save(mark: "add")

        // The new item's edit ring, and each of its panels
        b.click { $0.demoHome("Safari") }
        b.wait(1.0)
        b.mark("item-edit")
        // Between two options, the nearer one is chosen: nothing falls back to the middle.
        b.move { $0.demoBetween("Color", "Icon", 0.42) }
        b.wait(0.5)
        b.mark("edit-between")

        // Rename: type, undo the typing with ⌘Z, type again, save with Return.
        b.open(.rename, mark: "rename")
        b.type("Web", mark: "rename-typed")
        b.fire(.key("z", code: 6, modifiers: .command))
        b.wait(0.4)
        b.mark("rename-undone")
        b.type("Browser", mark: "rename-dirty")
        b.move { $0.demoPanelButton(save: true) }
        b.wait(0.3)
        b.mark("rename-save")
        b.fire(.key("\r", code: 36, modifiers: []))
        b.mark("rename-closing", after: 0.16)
        b.wait(1.1)
        b.mark("rename-saved")

        // Color: a swatch, a drag on the wheel, then a hex code typed over it.
        b.open(.color, mark: "color")
        b.panelMove("swatch:4")
        b.wait(0.3)
        b.mark("color-swatch-hover")
        b.fire(.windowClick)
        b.wait(0.5)
        b.mark("color-swatch")
        b.panelMove("wheel:150,0.55")
        b.wait(0.2)
        b.fire(.windowPress)
        b.panelMove("wheel:40,0.8", 0.5)
        b.wait(0.2)
        b.mark("color-drag")
        b.fire(.windowRelease)
        b.panelClick("hex")
        b.fire(.key("a", code: 0, modifiers: .command))
        b.type("#FF5C8A", mark: "color-dirty")
        b.save(mark: "color")

        // Icon: search, glide over a few symbols, pick one, step down a row with the arrow key.
        // Then switch to the apps and pick one's icon.
        b.open(.icon, mark: "icon")
        b.type("star", mark: "icon-search")
        b.panelMove("cell:2")
        b.wait(0.25)
        b.panelMove("cell:5", 0.3)
        b.mark("icon-glide", after: -0.14)
        b.wait(0.3)
        b.mark("icon-hover")
        b.panelClick("cell:1")
        b.wait(0.4)
        b.mark("icon-picked")
        b.fire(.key("\u{F701}", code: 125, modifiers: []))
        b.mark("icon-arrow-glide", after: 0.08)
        b.wait(0.5)
        b.mark("icon-dirty")
        b.panelMove("source")
        b.wait(0.3)
        b.mark("icon-source-hover")
        b.fire(.windowClick)
        b.mark("icon-source-switching", after: 0.08)
        b.wait(0.6)
        b.mark("icon-apps")
        b.fire(.key("a", code: 0, modifiers: .command))
        b.type("cal", mark: "icon-app-search")
        b.panelClick("com.apple.iCal")
        b.wait(0.5)
        b.mark("icon-app-picked")
        b.save(mark: "icon")

        // Action, on the same item: each kind of setting, worked through the window where
        // it takes input, then back without saving.
        b.open(.action, mark: "action")
        // The item opens an app, so Apps & Files is open. Opening System closes it.
        let system = ActionCatalog.categories.first { $0.id == "system" }?.actions.map(\.id) ?? []
        b.panelClick("row:system")
        b.mark("accordion-switching", after: 0.1)
        b.wait(0.8)
        b.mark("accordion-switched")
        b.panelClick("row:" + (system.dropFirst().first ?? ""))
        b.mark("select-appear", after: 0.08)
        b.wait(0.5)
        b.panelClick("row:" + (system.dropFirst(4).first ?? ""))
        b.mark("select-glide", after: 0.07)
        b.wait(0.6)
        b.mark("action-picked")
        b.editor(9, mark: "action-plain", wait: 0.6)        // Play/Pause: nothing to set

        b.editor(1, wait: 0.6)                              // Shell Command
        b.panelClick("setting:0.5,0.5")
        b.fire(.key("a", code: 0, modifiers: .command))
        b.type("open -a Terminal ~/Projects", mark: "action-shell")

        b.editor(2, wait: 0.6)                              // Keyboard Shortcut
        b.mark("action-keystroke-set")
        b.panelClick("setting:0.5,0.15")
        b.wait(0.3)
        b.mark("action-keystroke-recording")
        b.fire(.key("k", code: 40, modifiers: [.control, .shift, .command]))
        b.wait(0.4)
        b.mark("action-keystroke")

        b.editor(3, wait: 0.6)                              // Screenshot: a few kinds, as tiles
        b.panelMove("setting:window")
        b.wait(0.3)
        b.mark("action-choice-hover")
        b.fire(.windowClick)
        b.mark("action-choice-glide", after: 0.08)
        b.wait(0.5)
        b.mark("action-choice")

        b.editor(4, wait: 0.6)                              // Move Window: every layout
        b.mark("action-layouts")
        b.panelMove("setting:rightTwoThirds")
        b.wait(0.3)
        b.fire(.windowClick)
        b.wait(0.5)
        b.mark("action-layout")

        b.editor(5, wait: 0.6)                              // Open File
        b.mark("action-file")
        b.panelClick("setting:0.5,0.93")                    // its path field, which shows the whole path while edited
        b.wait(0.4)
        b.mark("action-file-editing")

        b.editor(6, wait: 0.6)                              // Open Website
        b.panelClick("setting:0.5,0.065")
        b.fire(.key("a", code: 0, modifiers: .command))
        b.type("https://example.com", mark: "action-website")

        b.editor(7, wait: 0.7)                              // Run Shortcut
        b.panelClick("setting:Start Timer")
        b.wait(0.5)
        b.mark("action-shortcut")

        b.editor(8, mark: "action-script", wait: 0.7)       // AppleScript

        // Search the actions and walk the results with the arrow keys.
        b.panelClick("search")
        b.type("vol", mark: "action-search")
        b.fire(.key("\u{F701}", code: 125, modifiers: []))
        b.wait(0.3)
        b.fire(.key("\u{F701}", code: 125, modifiers: []))
        b.mark("action-arrow-glide", after: 0.07)
        b.wait(0.5)
        b.mark("action-arrows")

        b.move { $0.demoPanelButton(save: false) }
        b.wait(0.3)
        b.fire(.windowClick)
        b.mark("action-back", after: 0.2)
        b.wait(1.2)
        b.fire(.escape)
        b.move(rest)
        b.wait(0.9)
        b.mark("recolor-rest")

        // The recolored item in normal use
        b.fire(.secondaryClick)
        b.wait(0.5)
        // Part of the way there, the droplet is out of the hub and carries the item's color.
        b.move { sim in sim.demoHome("Browser").flatMap { home in sim.demoHub().map { $0 + (home - $0) * 0.6 } } }
        b.wait(0.6)
        b.mark("recolor-droplet")
        b.move { $0.demoHome("Browser") }
        b.wait(0.6)
        b.mark("recolor-hover")
        b.move(V2(0, 0))
        b.wait(0.3)
        b.fire(.secondaryClick)
        b.move(rest)
        b.wait(0.8)

        // Reorder: Emoji past Lock Screen
        b.move { $0.demoHome("Emoji") }
        b.wait(0.25)
        b.fire(.press)
        b.move(0.3) { $0.demoBetween("Emoji", "Lock Screen", 0.5) }
        b.mark("drag-lift")
        b.move(0.25) { $0.demoBetween("Emoji", "Lock Screen", 0.85) }
        b.wait(0.3)
        b.mark("drag-over-item")
        b.move(0.3) { $0.demoBetween("Lock Screen", "Paste", 0.4) }
        b.wait(0.4)
        b.mark("drag-reorder")
        b.fire(.release)
        b.mark("drag-settle", after: 0.12)
        b.wait(0.9)

        // Make a folder: Lock Screen onto Emoji. Its edit ring opens.
        b.move { $0.demoHome("Lock Screen") }
        b.wait(0.25)
        b.fire(.press)
        b.move(0.45) { $0.demoBetween("Lock Screen", "Emoji", 0.8) }
        b.wait(0.35)
        b.mark("folder-create")
        b.fire(.release)
        b.mark("folder-merge", after: 0.12)
        b.wait(1.6)
        b.mark("folder-edit")
        b.move { $0.demoHome("Rename") }
        b.wait(0.5)
        b.mark("folder-edit-option")
        b.fire(.escape)
        b.wait(0.9)

        // Onto a folder: Paste into the new one
        b.move { $0.demoHome("Paste") }
        b.wait(0.25)
        b.fire(.press)
        b.move(0.4) { $0.demoBetween("Paste", "Folder", 0.78) }
        b.wait(0.35)
        b.mark("drag-onto-folder")
        b.fire(.release)
        b.mark("drag-absorb", after: 0.1)
        b.wait(1.0)

        // Open Media by clicking, then edit an item inside it
        b.click { $0.demoHome("Media") }
        b.move { $0.demoClear() }
        b.wait(0.9)
        b.mark("folder-open")
        b.click { $0.demoHome("Next") }
        b.wait(1.1)
        b.mark("edit-in-folder")
        b.move { $0.demoHome("Color") }
        b.wait(0.5)
        b.mark("edit-in-folder-option")
        b.fire(.escape)
        b.wait(0.9)

        // Drag Play/Pause out through the parent ring
        b.move { $0.demoHome("Play/Pause") }
        b.wait(0.25)
        b.fire(.press)
        b.move(0.4) { $0.demoParent(V2(40, -40)) }
        b.move(0.25) { $0.demoParent(V2(8, -6)) }
        b.wait(0.12)
        b.mark("drag-out")
        b.wait(0.8)
        b.mark("drag-out-opened")
        b.move(0.4) { $0.demoRing(-70) }
        b.wait(0.4)
        b.fire(.release)
        b.wait(0.9)
        b.mark("moved-out")

        b.fire(.secondaryClick)                 // back to the normal wheel
        b.wait(1.0)
        b.mark("exited")
        b.fire(.escape)
        b.wait(0.8)
        b.fire(.finish)
        return b.script
    }
}
