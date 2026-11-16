# How users interact with Gooey Wheel

This document describes what the app does in response to each thing a user can do: every input, menu item, panel, and permission. Instructions for users are in the README.

Gooey Wheel is a radial actions menu for macOS that opens from a mouse button. It's modeled on the Logitech Actions Ring and drawn in the liquid style of [Gooey](https://libraries.dev/gooey). Each bubble runs an action, such as a media key, a window layout, a system toggle, an app, a shortcut, or a script. Some bubbles are controls: a Volume bubble turns into a slider.

It needs macOS 14 or later. It works with any mouse, and reads Logitech mice directly for buttons macOS can't see. It lives in the menu bar and has no Dock icon.

## First launch

The first launch shows a welcome panel with two pages. The first plays a video of the [default wheel](#the-default-wheel) in use and says what the app does. The second asks which mouse button should open the wheel. While it's showing, pressing any button other than the left and right buttons assigns that button. If reading the button needs Accessibility or Input Monitoring, the page offers to open the right setting.

The round button in the bottom-left corner goes back, and the one in the bottom-right continues and then finishes. Return presses the right-hand button, and Esc closes the panel. When the panel closes, the wheel opens where it was.

Later launches open the wheel straight away. Launching with `--welcome`, or deleting the `welcomed` default, shows the panel again.

## The default wheel

A new wheel has the most-used actions in the four straight directions: Mission Control up, Volume right, Screenshot down, and Previous App left. Up and left match the trackpad's swipe up for Mission Control and the usual left for back. Each diagonal introduces one kind of bubble: Media Controls (a picker), a Controls folder of toggles and Sound Output, a Windows folder of Move Window layouts, and Customize. Customize's hub reads "Or right-click" to teach the shortcut.

In the [App Store edition](#app-store-edition) the Controls folder has Microphone Input and Pick Color in place of Do Not Disturb and Dark Mode.

## The menu bar item

| Item | What it does |
| --- | --- |
| Open Wheel | Opens the wheel |
| Assign Button | Shows the button that opens the wheel. Choosing it waits up to 15 seconds and assigns the next button pressed, other than the left and right buttons |
| Customize | Opens the wheel in configuration |
| Haptic Feedback | Turns the wheel's taps through the mouse on or off. Shown only while a mouse with a supported haptic motor is connected |
| Check for Updates… | Checks for a new version (see [Updates](#updates)) |
| Quit Gooey Wheel | Quits |

While a permission the assigned button needs is missing, the menu shows "Allow Accessibility…" or "Allow Input Monitoring…" in place of Assign Button.

## Opening and choosing

| Input | Result |
| --- | --- |
| Click the assigned mouse button | Opens the wheel and leaves it open |
| Hold the button, move toward a bubble, release | Picks that bubble. Releasing over nothing closes the wheel |
| Click a bubble | Picks it |
| Rest the cursor on a teardrop-shaped bubble | Opens that folder as a new ring around the bubble |
| Rest the cursor on the small parent ring, click the center, or press Esc | Goes back one level |
| Click outside the wheel, or press the button again | Closes the wheel |

A bubble is picked by the direction of the cursor from the center, so the cursor doesn't have to reach it. Folders are the exception. A folder opens only when the cursor is on the bubble itself, so passing its direction on the way to something else doesn't open it. While a folder is open, the ring it came from shrinks and dims, and the folder's items fan out away from it.

Until a button is assigned, the wheel opens from the menu bar item. On a Logitech mouse with a thumb button, such as the MX Master 4, the thumb button also opens it.

## Controls in bubbles

Some actions have a state. Their bubbles show it and change it in place.

| Kind | Actions | How it works |
| --- | --- | --- |
| Slider | Volume, Brightness, Keyboard Brightness, Pointer Speed | The level is drawn around the bubble's rim and shown in the hub. Scrolling over the bubble changes it one step at a time, with a scroll wheel, a side wheel, or a trackpad. Pressing the bubble turns it into a bar under the cursor, dragging along the bar sets the level, and letting go turns it back. A click or a release over the bubble leaves the bar open and following the cursor until the next click closes the wheel. The parent ring or Esc goes back |
| Toggle | Mute, Mute Microphone, Do Not Disturb, Dark Mode, Keep Awake, Wi-Fi, Dock Hiding, Stage Manager, Precision Mode, Free Spin, Mouse Haptics, Natural Scrolling | The glyph shows the state and turns the accent color when on. The hub says On or Off. Choosing it flips it |
| Stepper | Undo, Zoom, Switch Tab | Scrolling up undoes, zooms in, or moves to the previous tab. Scrolling down redoes, zooms out, or moves to the next tab. Choosing it does one Undo, Actual Size, or Next Tab |
| Picker | Media Controls, Sound Output, Microphone Input, Easy-Switch | Opens like a folder into the current choices: transport buttons with the playing track in the hub, the audio devices, or the mouse's paired computers. The choice in effect is lit. Media Controls stays open between presses |
| Readout | Mouse Battery | The hub shows the charge, and the glyph follows it |

Hovering a Move Window bubble outlines on screen where the front window would go. A Previous App bubble shows the icon of the app it would bring forward, and the hub names it; an icon chosen for the item replaces it.

An action that can't run on this Mac or mouse, such as Keyboard Brightness without a backlit Apple keyboard, is drawn faded, says why in the hub, and shakes when chosen.

A long name in the hub wraps to a second line, with the reading under the name.

When an action's result isn't visible, a short message grows out of where the hub was, such as "Copied #3FA7D6" after Pick Color or "Mouse switching to MacBook". An action that fails says why in the same place, such as "Allow Accessibility for Gooey Wheel".

[ACTIONS.md](ACTIONS.md) lists every action with its options and control.

### Mouse actions

Pointer Speed and Precision Mode change the sensor's resolution (DPI) on a Logitech mouse that allows it. On other mice they change macOS's tracking speed. In that case Pointer Speed's slider covers the range of the Tracking Speed slider in System Settings, and choosing it steps through that slider's tick marks. Precision Mode drops to a third of the current value: at most 400 DPI on a Logitech mouse, or at most 0.5 on macOS's tracking scale of 0 to 3.

Mouse Battery reads the charge over HID++ from a Logitech mouse, from macOS for Apple mice, and from the standard Bluetooth Battery service for other Bluetooth mice. The last asks for Bluetooth permission the first time. A wired mouse, or one on another brand's receiver, has no reading.

Free Spin, Mouse Haptics, and Easy-Switch work on Logitech mice with those features. Natural Scrolling is the macOS setting and works with any mouse.

## Customizing the wheel

Right-clicking a bubble or the center, or choosing Customize in the menu bar item, puts the wheel in configuration. The bubbles jiggle, the wheel stays open, and the cursor has to be on a bubble to act on it. Each change is saved as it's made.

| Input | Result |
| --- | --- |
| Click the X on a bubble | Removes it |
| Click the + in the center | Adds an item and opens its Action panel. Leaving the panel without saving removes the item. The + is dimmed when the ring is full: 8 items on the wheel, 6 in a folder |
| Drag a bubble along the ring | Moves it. A neighbor moves aside once the bubble passes its middle |
| Drag a bubble onto a folder | Puts it in the folder. Holding it there opens the folder, to place it |
| Drag a bubble onto another item | Makes a folder of the two and opens the folder's edit ring |
| In a folder, drag a bubble onto the small parent ring | Moves it out. Holding it there opens the parent ring, to place it |
| Click an item, or the pen on a folder | Opens its edit ring: Action, Color, Icon, Rename, and Remove. Folders have no Action. An edit ring picks by direction, like the wheel |
| Click a folder | Opens it |
| ⌘Z, ⇧⌘Z | Undoes and redoes changes made since configuration started |
| Esc | Steps back: out of a panel, a drag, an edit ring, or a folder, then out of configuration |
| Click outside the wheel | Closes an edit ring, or a panel with no changes. Otherwise ends configuration |
| Right-click | Ends configuration and leaves the wheel open |

A folder that loses its last item is removed. An item without a custom name is named after its action's setting: the app, file, website, shortcut, or window layout.

### Panels

Action, Color, Icon, and Rename each open a panel that grows out of the edit option. Each panel has a back button, and a save button appears once something changes.

| Panel | What it sets |
| --- | --- |
| Action | What the item does. Actions are listed by category with a search field. The right side holds the action's setting, if it has one: an app, a key combination, a file or folder (dropped from Finder or typed as a path), a web address, a command or script, text, one of a few options, or a level |
| Color | The item's color. The glyph takes it at rest, and the bubble fills with it when chosen. The color wheel sets hue and saturation, and the field takes any hex code. The first swatch is the default, and a second row offers colors used before |
| Icon | Any SF Symbol, with search. The item's default icon is first, with a ring around it. The first button beside the search field switches to installed apps, to use an app's icon. The second adds a picture from a file, and shows the picture while the item uses it. A picture without transparency is cropped to a rounded square. App icons and pictures keep their colors on the wheel |
| Rename | The item's name. An empty name goes back to the default, shown as the placeholder |

| Input | Result |
| --- | --- |
| Back button, or Esc | Drops the changes and returns to the edit ring |
| Save button | Saves the changes as one undo step and returns to the edit ring |
| Return | Saves if something changed, otherwise goes back. In a command, script, or text field it starts a new line |
| ↑ ↓ | Moves through a list or the icon grid |
| Tab | Moves between fields |
| Click outside | Closes the panel if nothing changed. Otherwise the save button jumps and the changes stay |
| ⌘Z in a field | Undoes typing |

While the key combination field has focus, it takes every key press before macOS and other apps see it, so a combination such as ⌘Space is recorded instead of run. Esc alone still goes back, and Delete alone clears the field. This needs Accessibility. Without it, combinations that macOS or another app has claimed run as usual.

## Choosing the mouse button

Any mouse button other than the left and right buttons can open the wheel. Once assigned, the button stops doing what it did before.

For most mice the app reads the button through an event tap, which needs Accessibility. The button starts working within a couple of seconds of Accessibility being allowed.

### Logitech mice

A Logitech mouse that uses Logitech's HID++ protocol is also read directly. This reaches buttons macOS never sees, such as the MX Master 4's thumb panel. It works over Bluetooth or a Logi Bolt receiver, and switching between the two with Easy-Switch keeps the button working. Logi Options+ isn't needed, and the app works whether or not it's running.

Opening a Logitech mouse needs Input Monitoring, granted under System Settings → Privacy & Security → Input Monitoring. While it's missing and a Logitech button is assigned, the menu bar item shows "Allow Input Monitoring…", which opens that setting.

While Assign Button waits for a press on a Logitech mouse, that mouse's other buttons do nothing. They go back to normal once a button is pressed.

If Options+ is running and assigns the thumb panel to the Options+ Actions Ring in an app profile, both menus open in that app. Setting the panel to "Do nothing" in that profile leaves only Gooey Wheel's.

## Haptic feedback

A mouse with a supported haptic motor taps when the pointer moves onto a bubble, when a folder, picker, or slider opens, when a ring closes back to its parent, when an item is chosen, and when something can't be done. Opening a ring and choosing an action give a light tap, and choosing in a picker gives a firmer one. Sliders and steppers don't tap. In configuration, picking up, dropping, adding, and removing bubbles tap.

Supported mice are Logitech mice with HID++ feature `0x19B0`. As of November 2026 that's the MX Master 4 and its Special and Developer Editions. The G Pro X2 Superstrike's haptic clicks use a different feature and can't play taps. A Force Touch trackpad taps for the same events, except rings opening and closing, whichever mouse is in use.

Taps are on by default. Haptic Feedback in the menu bar item turns them off. The mouse's own haptics setting, which the Mouse Haptics action flips, has to be on too. While Logi Options+'s background agent is running, taps need Bluetooth permission. The agent keeps running after Options+ is quit.

## Permissions

macOS asks for some permissions the first time something needs them.

| Permission | Needed for |
| --- | --- |
| Accessibility | Reading a mouse button through the event tap, key combinations, typing text, moving windows, the menu-driven system actions, and recording combinations in the key combination field. The menu bar item offers "Allow Accessibility for Actions…" while it's missing |
| Input Monitoring | Reading a Logitech mouse directly |
| Bluetooth | Logitech button presses and taps while Options+ is running, and the battery of non-Logitech Bluetooth mice |
| Automation (Finder) | New Finder Window |
| Full Disk Access | Showing Do Not Disturb's state. Without it the toggle works but shows no state |

## Updates

The app updates itself from GitHub releases through [Sparkle](https://sparkle-project.org). On the second launch it asks whether to check automatically, and if the user agrees it checks once a day. An automatic check that finds an update doesn't open a window. Instead, Check for Updates… in the menu bar item changes to "Update Available…", with the new version under it on macOS 14.4 and later. Choosing it shows the release notes and installs. Otherwise Check for Updates… checks immediately. It's dimmed while a check or download is already running. Releases are built for Apple silicon only.

## App Store edition

The App Store edition runs in the App Sandbox. It leaves out the actions that need private interfaces or other apps' menus, and does some others with Apple's default shortcuts; [ACTIONS.md](ACTIONS.md#app-store-edition) lists them. It has no Check for Updates… item, since the App Store installs updates, and doesn't ask for Full Disk Access or for Automation of Finder.

The window actions send the app in front its own shortcuts, so they act on that app's front window. Move Window needs macOS 15 and offers the layouts the system's tiling has shortcuts for; hovering a layout shows no preview. Empty Trash always asks in the app first.

The welcome page and the menu bar item ask for Accessibility as in the direct download. What the edition asks for is permission to post input, which System Settings lists under Accessibility and which the mouse event tap and every action that sends keys need. The key combination field takes presses before macOS only with Input Monitoring, which the welcome page offers for a Logitech mouse.

Open File and Open Folder take a file or folder chosen in the Open panel or dropped from Finder. Clicking the drop area or one of the preset folders opens the Open panel there; for a preset folder, Open chooses the folder itself. The path field shows the path and can't be typed in. Run Shortcut takes a shortcut's name typed into a field.

The wheel is saved inside the app's container, at `~/Library/Containers/<bundle id>/Data/Library/Application Support/Gooey Wheel/wheel.json`, so the App Store edition and the direct download each have their own wheel.

## Where things are saved

The wheel is saved to `~/Library/Application Support/Gooey Wheel/wheel.json`. Pictures added in the Icon panel are copied to `Icons` in the same folder, and a picture no item uses is deleted at the next launch.

Wheels saved by earlier versions are updated when they load. Merged actions move to the action that replaced them; for example, Volume Up and Volume Down become Volume. Retired actions with no replacement, such as Scroll Up, keep their name and wait for a new action.

Settings are in the `dev.gooey.wheel` defaults domain.

| Default | Holds |
| --- | --- |
| `mouseButton` | The assigned button's macOS button number |
| `button` | The assigned Logitech control's HID++ id |
| `welcomed` | Whether the welcome panel has been closed. Delete it to see the panel again |
| `TriggerDebug` | Turns on the mouse input log (see [TESTING.md](TESTING.md#the-mouse-input-log)) |
