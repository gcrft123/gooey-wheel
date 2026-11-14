<img src="assets/icon.png" width="64" height="64" alt="">

# Gooey Wheel

A native macOS prototype of a radial actions menu, a redesign of the Logitech Actions Ring with the liquid look of [Gooey](https://libraries.dev/gooey). The actions are placeholders. Selecting one plays the animation and closes the wheel.

## Run

```sh
./scripts/build-app.sh
open "build/Gooey Wheel.app"
```

Requires macOS 14 or later and the Swift toolchain from Xcode. The app has a menu bar item and no Dock icon.

## Use

| Input | Result |
| --- | --- |
| Click the MX Master 4 thumb button, or tap ⌃⌥Space | Opens the wheel and leaves it open |
| Hold the thumb button or ⌃⌥Space, move toward a bubble, release | Picks that bubble. Releasing over nothing closes the wheel |
| Click a bubble | Picks it |
| Rest the cursor on a teardrop-shaped bubble | Opens that folder as a new ring around the bubble |
| Rest the cursor on the small parent ring, click the center, or press Esc | Goes back one level |
| Click outside the wheel, or press the thumb button or ⌃⌥Space again | Closes |

## Configure

Right-click a bubble or the center to rearrange the wheel. The bubbles jiggle, the wheel stays open, and the cursor has to be on a bubble to act on it. Changes are saved as they are made, to `~/Library/Application Support/Gooey Wheel/wheel.json`.

| Input | Result |
| --- | --- |
| Click the X on a bubble | Removes it |
| Click the + in the center | Adds an item and opens its Action panel. Leaving the panel without saving drops the item again. The panel opens over the middle of the wheel. The + is dimmed when the ring is full: 8 items on the wheel, 6 in a folder |
| Drag a bubble along the ring | Moves it. A neighbor gives way once the bubble has passed its middle |
| Drag a bubble onto a folder | Puts it in the folder. Resting it there opens the folder, to place it |
| Drag a bubble onto another item | Makes a folder of the two and opens the folder's edit ring |
| In a folder, drag a bubble onto the small parent ring | Moves it out. Resting it there opens the parent ring, to place it |
| Click an item, or the pen on a folder | Opens its edit ring: Action, Color, Icon, Rename, and Remove. A folder has no Action. Remove takes the item off the wheel; the others open a panel. An edit ring picks by direction, like the wheel in normal use |
| Click a folder | Opens it |
| ⌘Z, ⇧⌘Z | Undoes and redoes changes made since configuration started |
| Esc | Steps back: out of a panel, a drag, an edit ring, or a folder, then out of configuration |
| Click outside the wheel | Closes an edit ring, or a panel with nothing changed. Otherwise ends configuration |
| Right-click | Ends configuration. The wheel stays open |

A folder that loses its last item is removed.

### Panels

An edit option turns into its panel, and the panel turns back into the option when it closes. Each panel has a back button. A save button appears once something has changed. Both are bubbles like the wheel's: they come out of the panel, fill under the cursor, and give when pressed.

| Panel | What it sets |
| --- | --- |
| Action | What the item does. Actions are listed by category on the left, with a search field. The right side holds what the chosen action needs: an app, a shortcut, a file or folder (drop one from Finder or type its path), a web address, a command or script, text, a key combination, one of a few options, or a level |
| Color | The item's color. Its glyph takes the color at rest, and its bubble fills with it when chosen. The wheel picks hue and saturation; the field takes any hex code. The first swatch is the default, and colors saved before are offered on a second row |
| Icon | Any SF Symbol, with search. The item's default icon is first, with a ring around it |
| Rename | The item's name. An empty name goes back to the default, which is shown as the placeholder |

| Input | Result |
| --- | --- |
| Back button, or Esc | Drops the changes and returns to the edit ring |
| Save button | Saves the changes as one undo step and returns to the edit ring |
| Return | Saves if something changed, otherwise goes back. In a command, script, or text it starts a new line |
| ↑ ↓ | Move through a list or the icon grid |
| Tab | Moves between a panel's fields |
| Click outside | Closes the panel if nothing changed. Otherwise the save button jumps and the changes stay |
| ⌘Z in a field | Undoes typing |

An item with no name of its own is named after what its action is set to: the app, file, website, or shortcut. Actions still don't run.

A bubble is chosen by the direction of the cursor from the center, so the cursor doesn't have to reach it. A folder is the exception: it opens only once the cursor is on the bubble itself, so passing its direction on the way to something else doesn't open it.

While a folder is open, the ring it came from shrinks and dims in place, and the folder's items fan out away from it. The menu bar item has a setting to hide the parent ring instead; in that mode the folder's items form a full ring and the way back is the center or Esc.

## Thumb button

The app reads the MX Master 4's thumb panel from the mouse itself, over Logitech's HID++ protocol. It doesn't use Logi Options+ and works whether or not Options+ is running. The mouse has to be connected by Bluetooth; one behind a Bolt receiver isn't supported yet.

macOS requires Input Monitoring permission to open the mouse. Allow Gooey Wheel under System Settings → Privacy & Security → Input Monitoring, or choose the menu bar item's "Allow Input Monitoring for the Thumb Button…". The button starts working within a couple of seconds of allowing it. The menu bar item shows the mouse's name once it is connected.

The mouse sends its button messages over two channels: HID reports, which the app opens, and a Bluetooth characteristic of Logitech's own, which Options+ uses. It sends them only to whichever channel last sent it a request. Options+ sends one every 4 seconds, so while it runs, the thumb panel's presses arrive on its channel for a second or two after each. The app listens on that channel too, which needs Bluetooth permission; macOS asks for it the first time the app opens. It only listens there and never writes to it.

After a pause of a second or more, the mouse sometimes never reports the release of the press before it. A press reported while the button still reads as down, after the mouse has been quiet for a while, counts as that missing release followed by a new press.

If Options+ is running and has the thumb panel assigned to its own Actions Ring in an app profile, both will open in that app. Set the panel to "Do nothing" in that profile.

`defaults write dev.gooey.wheel TriggerDebug -bool YES` turns on a diagnostic log at `~/Library/Logs/Gooey Wheel/trigger.log`. It records every message from the mouse on both channels, each press and what it did to the wheel, clicks, app switches, and main-thread stalls. `defaults delete dev.gooey.wheel TriggerDebug` turns it off.

## How it's built

- `GooRenderer.swift` draws every shape in one Metal fragment shader as a signed distance field. Shapes are joined with an exponential smooth minimum, which makes them neck, bridge, and pinch off. Color uses the same weights, so the accent tint flows through a bridge. The shadow and rim light are computed from the same field.
- `WheelSim.swift` holds the motion. Each ring is a `Level` with its own hub, and open folders stack as levels. Every animated value is a closed-form damped spring (`Spring.swift`), so a new target keeps the current velocity and the motion is the same at 60 and 120 Hz. Spring constants are in `Tuning.swift`.
- `WheelItem.swift` and `WheelStore.swift` hold the wheel's contents: items with stable ids, saved as JSON, with undo. The sim keeps one bubble per item id, so a ring that gains, loses, or reorders items re-spaces along its circle.
- `WheelSim+Configure.swift` is configuration: what the cursor is on, presses, adding and removing, the jiggle, and the badges. `WheelSim+Drag.swift` is dragging. An edit ring is a `Level` whose hub is the item and whose bubbles are `EditOption`s.
- `WheelSim+Editor.swift` is a panel's shape and motion: the bubble that grows into it, the back and save buttons, and what the cursor is on. The renderer cuts the buttons' corners out of the panel's box with a smooth maximum, and a `firm` blob's field falls off faster outside it, which keeps a clean gap between the panel and its buttons where the rest of the goo would fuse.
- `EditorHost.swift` lays a panel's AppKit views over the goo panel, clipped to the same outline, and fades them in once it is most of the way open. `EditorContent.swift` is what the four panels share: each edits a copy of the item and writes it back on save. The panels are `ActionEditor.swift` (with `ParameterEditors.swift` for each kind of setting), `ColorEditor.swift`, `IconEditor.swift`, and `RenameEditor.swift`. `EditorList.swift` is the list they share and `EditorFields.swift` the fields. Lists, the icon grid, and the controls are stepped each frame on the same springs as the wheel, and their highlights glide from one row or cell to the next.
- `WheelLayers.swift` draws icons and labels as Core Animation layers above the goo. The Metal drawable is presented inside the same transaction that moves those layers, so they stay on the same frame.
- `WheelController.swift` owns the overlay panel and the display link. The panel doesn't activate the app, so the frontmost app keeps focus. Nothing renders while the wheel is closed, and a settled wheel skips identical frames.
- `LogiButton.swift` asks the mouse to divert the thumb panel (control `0x01A0`) and listens for its press and release notifications. `ButtonTracker` merges the two reports the mouse sends for each change and recovers releases it drops. `VendorChannel.swift` listens for the same notifications on Logitech's Bluetooth characteristic.
- `HotKey.swift` registers the keyboard shortcut through Carbon, which reports key-up and needs no Accessibility permission.

## Recording a demo

`--demo` runs a scripted cursor on an opaque backdrop, which is useful for screen recordings and for tuning in slow motion.

```sh
.build/out/Products/Release/GooeyWheel --demo --stage color --timescale 0.25
```

`--stage` takes `dark`, `light`, or `color`. `--appearance light|dark` overrides the system appearance. `--parent shrink|hide` picks what the parent ring does in a folder. `--demo-exit` quits after one pass. `--reduce-motion` shows the Reduce Motion version.

The stage is in the bottom-right corner of the main display, so a demo stays out of the way of whoever is using the Mac. `--demo-stage-rect` prints its rectangle in the form `screencapture -R` takes: `1700,780,836,636` for the default script and `1460,600,1076,816` for the configuration script on a 2560 × 1440 display. A demo doesn't take the Esc key.

`--demo-script configure` plays configuration instead: removing, adding, each panel, and dragging, on a larger stage. The demo uses the default wheel and saves nothing. Its app list shows only the apps that come with macOS, and its shortcut list is made up. Inside the panels the script works the views themselves: its clicks, drags, and key presses are sent through the demo's own window, the way the system delivers real ones, and never touch the real pointer or keyboard. `--demo-marks` lists the script's named moments with their times, and `--demo-stop-at <time>` freezes the demo at one of them. `--demo-root-count <n>` starts with only the first n items on the wheel.

`--demo-capture <folder>` writes an image of every named moment into a folder and quits, without showing anything: the demo's window is the stage alone, placed behind the desktop picture, and each image is a capture of that one window. `--demo-capture-filter <pattern>` limits it to the moments whose names match. `--demo-capture-frames <from>,<to>,<rate>` writes that stretch of the script frame by frame instead, for making a video.
