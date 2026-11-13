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

A bubble is chosen by the direction of the cursor from the center, so the cursor doesn't have to reach it. A folder is the exception: it opens only once the cursor is on the bubble itself, so passing its direction on the way to something else doesn't open it.

While a folder is open, the ring it came from shrinks and dims in place, and the folder's items fan out away from it. The menu bar item has a setting to hide the parent ring instead; in that mode the folder's items form a full ring and the way back is the center or Esc.

## Thumb button

The app reads the MX Master 4's thumb panel from the mouse itself, over Logitech's HID++ protocol. It doesn't use Logi Options+ and works whether or not Options+ is running. The mouse has to be connected by Bluetooth; one behind a Bolt receiver isn't supported yet.

macOS requires Input Monitoring permission to open the mouse. Allow Gooey Wheel under System Settings → Privacy & Security → Input Monitoring, or choose the menu bar item's "Allow Input Monitoring for the Thumb Button…". The button starts working within a couple of seconds of allowing it. The menu bar item shows the mouse's name once it is connected.

If Options+ is running and has the thumb panel assigned to its own Actions Ring in an app profile, both will open in that app. Set the panel to "Do nothing" in that profile.

## How it's built

- `GooRenderer.swift` draws every shape in one Metal fragment shader as a signed distance field. Shapes are joined with an exponential smooth minimum, which makes them neck, bridge, and pinch off. Color uses the same weights, so the accent tint flows through a bridge. The shadow and rim light are computed from the same field.
- `WheelSim.swift` holds the motion. Each ring is a `Level` with its own hub, and open folders stack as levels. Every animated value is a closed-form damped spring (`Spring.swift`), so a new target keeps the current velocity and the motion is the same at 60 and 120 Hz. Spring constants are in `Tuning`.
- `WheelLayers.swift` draws icons and labels as Core Animation layers above the goo. The Metal drawable is presented inside the same transaction that moves those layers, so they stay on the same frame.
- `WheelController.swift` owns the overlay panel and the display link. The panel doesn't activate the app, so the frontmost app keeps focus. Nothing renders while the wheel is closed, and a settled wheel skips identical frames.
- `LogiButton.swift` asks the mouse to divert the thumb panel (control `0x01A0`) and listens for its press and release notifications.
- `HotKey.swift` registers the keyboard shortcut through Carbon, which reports key-up and needs no Accessibility permission.

## Recording a demo

`--demo` runs a scripted cursor on an opaque backdrop, which is useful for screen recordings and for tuning in slow motion.

```sh
.build/out/Products/Release/GooeyWheel --demo --stage color --timescale 0.25
```

`--stage` takes `dark`, `light`, or `color`. `--appearance light|dark` overrides the system appearance. `--parent shrink|hide` picks what the parent ring does in a folder. `--demo-exit` quits after one pass.
