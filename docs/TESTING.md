# Testing

There's no XCTest target. The app checks itself through command-line modes of the same binary: a self-test for the actions, scripted demos for the wheel's motion, and off-screen captures for comparing frames.

The examples below use the release binary from the build folder:

```sh
swift build -c release --disable-keychain
bin="$(swift build -c release --disable-keychain --show-bin-path)/GooeyWheel"
```

A binary run from a terminal gets the terminal's privacy permissions, not the ones granted to `Gooey Wheel.app`. A check that passes there doesn't prove the app has Accessibility or Input Monitoring.

## Self-test

```sh
"$bin" --self-test
"$bin" --self-test 'audio|media'
```

`--self-test` checks the actions against the Mac it runs on and prints one line per check: PASS, FAIL, or SKIP with a reason. The optional argument is a regular expression matched against check names. It exits with a nonzero status if any check fails.

The self-test is written to leave the Mac as it found it, so it's safe to run while someone is using the computer. Key presses go to a hidden window the self-test opens, window actions move another hidden window, settings are written back with the value they already had, and the clipboard is restored. An action whose effect would be visible is checked up to the point where it would act.

The `catalog.*` checks run everywhere. They fail if a catalog action has no behavior, if two actions share an id, if an SF Symbol doesn't exist on this macOS version, or if a control is missing a hook it needs (a toggle without `isOn`, for example). Run them after any change to the catalog.

Each action file adds checks in a `tests` list, gathered in `SelfTest.cases` in `Actions/SelfTest.swift`.

`apps.ejectOneProbe` unmounts the volume mounted at `GOOEY_EJECT_PROBE`, and skips when it isn't set. Eject All Disks would eject the user's disks, so this checks the unmount on a disk image made for it:

```sh
hdiutil create -size 4m -fs APFS -volname GooeyProbe /tmp/probe.dmg
hdiutil attach -nobrowse -mountpoint /tmp/probe /tmp/probe.dmg
GOOEY_EJECT_PROBE=/tmp/probe "$bin" --self-test apps.ejectOneProbe
```

### The App Store edition

The App Store edition's self-test leaves out the checks for actions it doesn't have and adds checks of the default shortcuts it sends. To run it in the App Sandbox, copy the binary from `GOOEY_APPSTORE=1 swift build -c release --disable-keychain --build-path .build-mas` into an app bundle with its own bundle id, so the app the user runs and its permissions are untouched, and sign it with the App Store entitlements (`app-sandbox`, `device.usb`, `device.bluetooth`, `files.user-selected.read-only`, `files.bookmarks.app-scope`). Then run `<bundle>/Contents/MacOS/GooeyWheel --self-test` and look for sandbox denials with `/usr/bin/log show --last 10m --predicate 'eventMessage CONTAINS "deny" AND eventMessage CONTAINS "GooeyWheel"' --style compact`.

Run from a terminal, the sandboxed binary reports the terminal's Accessibility grant, but the sandbox still refuses it Accessibility on other apps (`deny mach-lookup com.apple.axserver`). Checks on its own windows pass; `window.previewIsQuick` notes "(no window)" for the app in front.

## Running one action

```sh
"$bin" --run-action media.volume
"$bin" --run-action apps.open com.apple.TextEdit
```

`--run-action <id> [argument]` runs one action as the wheel would, then waits a few seconds and quits. Action ids are in `ActionCatalog+BuiltIn.swift`. Unlike the self-test, this does act, so it changes settings, moves windows, and sends keys.

## Running a separate copy

`--store <path>` keeps the wheel in that file instead of `~/Library/Application Support/Gooey Wheel/wheel.json`, and `--no-mouse` leaves the mouse alone. Together they run a copy that doesn't touch your saved wheel or take the mouse button from an installed copy:

```sh
"$bin" --store /tmp/gooey-test/wheel.json --no-mouse
```

Defaults can be set for one run through the argument domain, such as `-TriggerDebug YES`.

## Demos

`--demo` plays a scripted cursor over the wheel on an opaque backdrop, for recordings and for watching motion in slow motion.

```sh
"$bin" --demo --stage color --timescale 0.25
```

| Option | Effect |
| --- | --- |
| `--demo-script wheel` | The default script: opening, hovering, folders, and picking |
| `--demo-script configure` | Configuration: removing, adding, each panel, and dragging, on a larger stage |
| `--demo-script controls` | A slider's rim, scrolling it, its bar, a toggle, and a picker |
| `--demo-script tour` | A bit of everything in 24 seconds, starting and ending with the wheel closed: pointing, the Volume slider and its bar, the Media Controls picker, the Controls folder, and configuration, where it reorders two bubbles and makes a folder. This is the welcome panel's video |
| `--stage dark\|light\|color\|clear` | The backdrop. `clear` has none |
| `--appearance light\|dark` | Overrides the system appearance |
| `--accent <hex>` | Replaces the system accent color |
| `--timescale <n>` | Plays slower or faster. `0.25` is quarter speed |
| `--reduce-motion` | Plays the Reduce Motion version |
| `--demo-exit` | Quits after one pass |
| `--demo-root-count <n>` | Starts with only the first n items on the wheel |
| `--demo-marks` | Prints the named moments of the script chosen with `--demo-script` and their times, then quits |
| `--demo-stop-at <time>` | Freezes the script at that time |
| `--demo-stage-rect` | Prints the stage's rectangle in the form `screencapture -R` takes, then quits |

Every script plays on the [default wheel](USERS.md#the-default-wheel) and saves nothing. The scripts find their bubbles by name, so a change to `WheelItem.defaults` that renames, removes, or moves a bubble needs the scripts checked again. The demo's app list shows only apps that come with macOS, its shortcut list is made up, and the states its controls show are made up, so it never reads or changes this Mac's settings. The controls script also pretends Previous App can't run, to show a refusal. Inside the panels, the configure script sends its clicks, drags, and key presses through the demo's own window, so it never moves the real pointer or types on the real keyboard. The demo doesn't take the Esc key.

The stage sits in the bottom-right corner of the main display. On a 2560 × 1440 display its rectangle is `1700,780,836,636` for the default script and `1460,600,1076,816` for the configure script. Pass the same `--demo-script` to `--demo-stage-rect` to get the right one. While a demo is playing, this records 11 seconds of it:

```sh
screencapture -v -V 11 -R "$("$bin" --demo-stage-rect)" demo.mov
```

### Off-screen captures

`--demo-capture <folder>` writes an image of every named moment of the script into the folder and quits. Nothing appears on screen: the demo's window is placed behind the desktop picture, and each image is a capture of that window alone. It works with the screen locked. The direct download captures with `screencapture`, the App Store edition with ScreenCaptureKit; both need Screen Recording for the app or terminal that runs them.

```sh
"$bin" --demo-script configure --demo-capture /tmp/frames
"$bin" --demo-capture /tmp/frames --demo-capture-filter folder
"$bin" --demo-capture /tmp/frames --demo-capture-frames 2.0,3.5,30
```

`--demo-capture-filter <pattern>` limits the capture to moments whose names match. `--demo-capture-frames <from>,<to>,<rate>` writes that stretch of the script frame by frame instead, for checking a transition or making a video.

When a change affects motion, look at the changed stretch frame by frame, not at a few stills. A handful of stills can miss a jump that's obvious when the animation plays.

### Other previews

| Command | Output |
| --- | --- |
| `--welcome-preview <folder>` | An image of each welcome panel page, without showing the panel |
| `--welcome-record <folder>` | The whole welcome panel frame by frame, from opening to closing, with a drawn pointer pressing its buttons |
| `--toast-preview <folder>` | Shows sample messages in the bottom-right corner of the screen and writes images of them |

The App Store edition doesn't have `--welcome-preview`, `--welcome-record` or `--toast-preview`, which run `screencapture`.
| `--render-icon <path>` | Renders the app icon with the goo shader. `scripts/build-app.sh` runs this for `assets/icon.png` |

### The welcome video

`scripts/render-welcome-video.sh` rebuilds `assets/welcome.mov`. It captures the tour script off screen on `--stage clear` with `--accent "#FFFFFF"`, so highlights show against the panel's yellow, and encodes it as HEVC with alpha. It needs ffmpeg and takes a few minutes. Run it after changing the tour script, the default wheel, or anything the tour shows. The script crops the capture to a square that holds everything the tour opens; if the tour reaches further, widen the crop.

## The mouse input log

```sh
defaults write dev.gooey.wheel TriggerDebug -bool YES
```

After a relaunch, the app logs to `~/Library/Logs/Gooey Wheel/trigger.log`: each press the event tap reads, every message from a Logitech mouse on both channels, what each press did to the wheel, clicks, app switches, and main-thread stalls. `defaults delete dev.gooey.wheel TriggerDebug` turns it off.

A physical button press can't be simulated. Anything that depends on the mouse itself, such as a Logitech button, the Bolt receiver, or haptic taps, has to be checked by pressing the button.
