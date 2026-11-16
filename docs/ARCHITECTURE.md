# Architecture

Gooey Wheel is one Swift package with two targets. `GooeyWheel` is the app, an AppKit executable with no storyboards or SwiftUI. `NowPlayingHelper` is a small Objective-C library that reads the playing track (see [Now playing](#now-playing)). The only dependency is Sparkle, taken as a binary target in `Package.swift`.

All app source is in `Sources/GooeyWheel`. `main.swift` handles the command-line modes that render something and quit, then starts `AppDelegate`, which owns the menu bar item, the mouse inputs, and the `WheelController`.

## Drawing

`GooRenderer.swift` draws every shape in a single Metal fragment shader as a signed distance field. The shader's source is a string in that file, compiled when the app starts. Shapes are combined with an exponential smooth minimum, which is what makes bubbles neck, bridge, and pinch apart. Color is blended with the same weights, so the accent tint flows across a bridge. The shadow and rim light come from the same field.

Icons and labels are Core Animation layers above the goo, drawn by `WheelLayers.swift`. The Metal drawable is presented inside the same `CATransaction` that moves those layers, so the two stay on the same frame.

`WheelController.swift` owns the overlay panel and the display link. The panel never activates the app, so the app in front keeps focus while the wheel is open. Nothing renders while the wheel is closed, and a settled wheel skips frames identical to the last.

## Motion

`WheelSim.swift` holds the wheel's state and motion. Each ring is a `Level` (`WheelLevel.swift`) with a hub, and open folders stack as levels. Edit rings, slider bars, and pickers are also levels: an edit ring's hub is the item and its bubbles are `EditOption`s, a bar's hub is the bar, and a picker's bubbles are its choices.

Every animated value is a closed-form damped spring from `Spring.swift`. Setting a new target keeps the current velocity, and because the spring is solved in closed form rather than stepped, motion is identical at 60 and 120 Hz. Spring constants live in `Tuning.swift`.

The sim keeps one bubble per item id. When a ring gains, loses, or reorders items, the bubbles re-space along the circle instead of being rebuilt.

The rest of the sim is split by concern:

| File | Concern |
| --- | --- |
| `WheelSim+Blobs.swift` | Turning the sim's state into the shapes the renderer draws |
| `WheelSim+Configure.swift` | Configuration mode: hit testing, presses, adding and removing, the jiggle, and the badges |
| `WheelSim+Drag.swift` | Dragging bubbles within and between rings |
| `WheelSim+Controls.swift` | The wheel's side of controls: the last-read state of each item, scrolling, slider bars, and pickers |
| `WheelSim+Editor.swift` | A panel's shape and motion: the bubble that grows into it, its back and save buttons, and hit testing |

## Wheel contents

`WheelItem.swift` defines an item: a stable id, an action id and its argument, an optional name, color, and icon, and for a folder, its children. Folders don't nest. `WheelStore.swift` loads and saves the wheel as JSON and keeps the undo stack for configuration mode.

An item's icon is saved as a string: an SF Symbol name, `app:` followed by a bundle identifier, or `image:` followed by a path. `ItemIcon.swift` reads those and copies pictures added in the Icon panel into the `Icons` folder.

## Panels

`EditorHost.swift` places a panel's AppKit views over the goo panel, clips them to the panel's outline, and fades them in once the panel is mostly open. The renderer cuts the back and save buttons' corners out of the panel with a smooth maximum. A `firm` blob's field falls off faster outside its edge, which keeps a clean gap between the panel and its buttons where the goo would otherwise fuse.

`EditorContent.swift` is what the four panels share: each edits a copy of the item and writes it back on save. The panels are `ActionEditor.swift` (with `ParameterEditors.swift` for each kind of setting), `ColorEditor.swift`, `IconEditor.swift`, and `RenameEditor.swift`. `EditorList.swift` is the shared list view and `EditorFields.swift` the shared fields. Lists, the icon grid, and controls step on the same springs as the wheel each frame, so their highlights glide between rows.

`KeyCapture.swift` is the event tap the key combination field uses while focused. It removes key presses from the event stream before the window server matches them against system shortcuts and other apps' hot keys.

## Welcome panel

`WelcomePanel.swift` is the first-launch window: its two pages, the transition between them, and the background, a blurred mesh of color patches with film grain drawn once when the panel opens. `WelcomeGoo.swift` draws the panel's body and corner buttons with the wheel's renderer and springs. The page contents are clipped with a mask computed from the same distance field as the shader, so they follow the buttons' cutouts as they open.

The panel's video, `assets/welcome.mov`, is the tour demo rendered by `scripts/render-welcome-video.sh` (see [TESTING.md](TESTING.md#demos)). The tour plays on `WheelItem.defaults`, so the video shows the wheel a new user gets.

## Actions

An action has two halves. Its definition, in the catalog, says what it is; its behavior, in `Actions/`, says what it does.

`ActionCatalog.swift` defines `ActionDefinition`: a stable id such as `media.playPause`, a title, an SF Symbol, an optional `ActionParameter` (the setting it needs, such as an app or a key combination), an optional `ActionControl` (toggle, slider, stepper, picker, or readout), and search keywords. `ActionCatalog+BuiltIn.swift` lists every built-in action by category. Ids are saved in users' wheels, so they never change. When an action is merged or retired, `ActionCatalog+Migration.swift` maps its old id to the replacement, and saved wheels are migrated on load.

`Actions/ActionRuntime.swift` defines `ActionBehavior`: what choosing the action does (`run`), whether it's available on this Mac, and the hooks a control needs, such as `isOn` for a toggle, `level` for a slider, `step` for a stepper, `choices` and `choose` for a picker, and `liveDetail` for a readout. Each category's behaviors are a `behaviors` dictionary in one file per category, such as `AudioActions.swift` or `WindowActions.swift`, and `ActionBehaviors` merges them.

`ActionRunner.swift` runs a chosen item. For actions that capture or cover the screen, such as screenshots, it waits until the wheel has left the screen. It also answers the wheel's questions about a control's current state. `KeySender.swift` posts key combinations, media keys, and text, looking up keys by the character they type in the current keyboard layout.

Actions that can't run show a short message through `Toast.swift`, which draws it in goo from where the hub was.

### Private interfaces

A few actions use private macOS interfaces. Each is loaded at run time, so a missing symbol disables its action instead of crashing the app. None of them is in the [App Store edition](#the-app-store-edition).

| Action | Interface |
| --- | --- |
| Mission Control and Dock actions | `CoreDockSendNotification` |
| Dark Mode | SkyLight |
| Brightness | DisplayServices |
| Lock Screen, Switch User | The login framework |
| System shortcuts, such as screenshots | `SymbolicHotKey.swift` reads and writes the symbolic hot key table |

When the user has turned a system shortcut off, such as the screenshot keys, `SymbolicHotKey.swift` lends it a spare key combination, posts that combination, and restores the original. If the app crashes in between, the lent shortcut is restored at the next launch.

### Now playing

The playing track comes from MediaRemote, which macOS 15.4 and later only answers for Apple's own processes. `NowPlayingHelper` is a dynamic library that `NowPlaying.swift` loads into `/usr/bin/perl`, an Apple-signed process, to read it. The approach follows [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter). Without the helper, media keys still work and no track is shown.

## Mouse input

The wheel opens from two kinds of mouse input. Both report presses and releases to `AppDelegate.buttonChanged`, which opens, closes, or picks.

### Any mouse

`MouseButtonTap.swift` installs an active `CGEventTap` that watches the button numbers macOS assigns: 2 is the middle button, and side buttons follow, usually 3 for back and 4 for forward. It removes the assigned button's presses and releases from the event stream before any app sees them, and turns its drags into plain mouse moves. The tap needs Accessibility. The button is saved under the `mouseButton` default as its number.

### Logitech HID++

A Logitech mouse that uses HID++ is also read directly, which reaches controls macOS never sees, such as the MX Master 4's thumb panel (control `0x01A0`). Opening the device needs Input Monitoring. The app doesn't use or read Logi Options+.

`LogiButton.swift` uses the reprogrammable controls feature (`0x1B04`) to divert the assigned control, so the mouse reports its presses to the app instead of acting on them, and listens for the notifications. For Assign Button it lists the mouse's controls and diverts every one the mouse allows, except the left and right buttons, until one is pressed, then hands them back. A button the mouse won't divert is read through the event tap like any other mouse's. A Logitech button is saved under the `button` default as its control id.

`ButtonTracker`, in the same file, merges the two reports the mouse sends for each change: one listing the diverted controls that are down, and one with press and release events. Either report sometimes leaves a transition out. After a second or more without activity the mouse sometimes never reports the release of the last press, so a press that arrives while the button already reads as down, after a quiet stretch, counts as the missing release followed by a new press.

`HIDPPPort.swift` is an opened HID++ interface. A Bluetooth mouse has one to itself; devices behind a receiver share the receiver's.

`LogiReceiver.swift` handles the Logi Bolt receiver. It reaches the mouse by its slot on the receiver and watches the receiver's connection notifications, which arrive when the mouse wakes or switches to another computer. Each time the link comes back, the app diverts the button again.

On Bluetooth, the mouse carries HID++ over two channels: HID reports, which `HIDPPPort` opens, and a GATT characteristic of Logitech's own, which Options+ uses. The mouse sends notifications only to the channel that last sent it a request. Options+ sends one every 4 seconds, after which button notifications go to its channel for a second or two. `VendorChannel.swift` subscribes to that characteristic through CoreBluetooth so those presses aren't lost. It writes to the characteristic only for haptic taps while Options+ is running.

`HotKey.swift` registers Esc through Carbon while the wheel is open. Carbon hot keys need no Accessibility permission.

### Haptics

`Actions/MouseHaptics.swift` plays taps through HID++ feature `0x19B0`. Each mouse reports which waveforms it has, and each tap uses the closest available one. Because every tap is a HID++ request, and the mouse sends notifications (including scrolling) to whichever channel made the last request, taps go over Options+'s GATT channel while its agent runs, written without response as Options+ writes them. Otherwise Options+ would lose the scroll wheel.

`WheelController.swift` decides when to tap, and taps a Force Touch trackpad through `NSHapticFeedbackManager`.

## Updates

`Updater.swift` starts Sparkle's updater and owns the Check for Updates menu item, including the "Update Available…" state after a background check. The feed and signing are described in [RELEASING.md](RELEASING.md). The App Store edition has neither, since the App Store installs updates.

## The App Store edition

`GOOEY_APPSTORE=1` builds the Mac App Store edition: `Package.swift` drops Sparkle and defines the Swift condition `APPSTORE`. That edition runs in the App Sandbox and may use public interfaces only. App Review scans the binary for private symbol and framework names, so the code that uses them is compiled out with `#if !APPSTORE` rather than turned off at run time.

`ActionCatalog.leftOut` lists the actions the edition doesn't have, and `ActionCatalog.categories` filters them out, which hides them from the picker and from lookups by id. Their behaviors and checks are compiled out too. `ActionMigration` turns an item that uses one into an item with no action that keeps its name. [ACTIONS.md](ACTIONS.md#app-store-edition) lists what is left out and what works differently.

What the condition compiles out:

| Code | In its place |
| --- | --- |
| `SymbolicHotKey.swift`, `SystemShortcut` reading SkyLight's shortcut table | `SystemShortcut` and `Screenshots` post Apple's default key combinations |
| `CoreDockSendNotification` and Dock hiding's CoreDock calls | `Dock` opens Mission Control.app and Apps.app, or posts ⌃↓ and F11. Dock hiding posts ⌥⌘D, and `ActionCatalog.stateless` makes it a plain action instead of a toggle |
| `AXWindow.swift`, `WindowGeometry.swift`, Move Window's planning and previews, Next Display, and the `kAXFrontmost` step of `AppSwitching.activate`: every use of Accessibility on another process, which the sandbox refuses (`deny mach-lookup com.apple.axserver`) even with the user's grant | `WindowTiling` posts the system's Move & Resize shortcuts. Minimize, Full Screen, Close Window, Hide App and Hide Others post ⌘M, ⌃⌘F, ⌘W, ⌘H and ⌥⌘H, since the sandbox also refuses `hide()` on another app. Previous App uses `activate()` alone, which works sandboxed |
| `AXIsProcessTrusted` | `Permissions` checks and asks for the PostEvent privilege (`CGPreflightPostEventAccess`, `CGRequestPostEventAccess`), which System Settings lists under Accessibility and which posting keys and the mouse event tap need. The key combination field's event tap needs ListenEvent (Input Monitoring) |
| `MenuItems.swift` (Accessibility on other apps' menus and the Apple menu's private selectors) | Default shortcuts. `FinderCommand` sends Finder's own shortcuts to Finder's process alone. Empty Trash asks in the app first and sends ⌥⇧⌘⌫ |
| `DisplayActions.swift`, `NaturalScrolling.swift`, `Appearance`, `FocusState`, `WiFi`, the login framework, `IOPMCopySystemPowerSettings`, `privateFunction` | Nothing: their actions are left out |
| `NowPlaying.swift` and the perl helper | Media keys only |
| `ChildProcess.swift` and the actions that run programs | Run Shortcut opens a `shortcuts://` link; the Shortcut field is plain text instead of a list from `shortcuts list` |
| `terminate()` for Quit App and Quit an App, which the sandbox refuses | Quit App posts ⌘Q to the app's process; Quit an App is left out |
| The `--toast-preview`, `--welcome-preview` and `--welcome-record` modes, which run `screencapture` | `--demo-capture` captures through ScreenCaptureKit |

The tiling shortcuts are Globe-Control combinations held in the window server's shortcut table (ids 237 to 243), with the same key and flags as Mission Control's ⌃↑, App Exposé's ⌃↓ and the Spaces shortcuts ⌃← and ⌃→, because arrow keys carry the Globe flag on their own. In the App Store edition `KeySender` presses Globe as a key before a combination that includes it, as the keyboard does, so a tiling shortcut differs from a Spaces one.

Two things work the same way in both editions. `UserHome` expands `~` to the user's home folder from the account record, since `NSHomeDirectory()` names the app's container in the sandbox. Move Window, in the direct download, tells windows apart by their Accessibility elements, which compare equal through `CFEqual`.

Open File and Open Folder store an `ItemLocation`: the path, and in the App Store edition a second line holding a security-scoped bookmark in base64. The path editor makes the bookmark when a file is chosen in the Open panel or dropped from Finder, and the action resolves it and starts access before opening. An argument without the second line is read as a path, as before.

`SymbolCatalog.swift` reads the SF Symbols list from `/System/Library/CoreServices/CoreGlyphs.bundle` in both editions. The sandbox allows the read.

## Diagnostics

`TriggerDebug.swift` writes a log of mouse input when the `TriggerDebug` default is on (see [TESTING.md](TESTING.md#the-mouse-input-log)). `Actions/SelfTest.swift` is the self-test runner. `DemoDriver*.swift` are the scripted demos, which play on `WheelItem.defaults`.
