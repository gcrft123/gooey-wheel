# App Store listing

The text Gooey Wheel's App Store Connect record uses. Edit it here first, then copy it to App Store Connect (or set it with `scripts/asc.rb`), so the repository keeps the current listing. How the build is made and uploaded is in [RELEASING.md](RELEASING.md#the-mac-app-store-edition).

## App information

| Field | Value |
| --- | --- |
| Name | Gooey Wheel |
| Subtitle | Radial actions for any mouse |
| Bundle ID | `dev.gooey.wheel` |
| SKU | `gooey-wheel` |
| Primary category | Utilities |
| Secondary category | Productivity |
| Price | Free |
| Age rating | 4+ (no objectionable content) |
| Privacy policy URL | https://github.com/gcrft123/gooey-wheel/blob/main/docs/PRIVACY.md |
| Support URL | https://github.com/gcrft123/gooey-wheel/issues |
| Marketing URL | https://github.com/gcrft123/gooey-wheel |
| Copyright | 2026 gcrft123 |
| App Privacy | Data Not Collected |
| Encryption | None (`ITSAppUsesNonExemptEncryption` is false) |

## Screenshots

`scripts/render-app-store-screenshots.sh` renders five 2880 × 1800 screenshots from the App Store edition's demos into `build/App Store/screenshots`, each with a caption from the script. Rerun it after changing the default wheel or anything the demos show.

## Promotional text

Press a mouse button and a ring of actions opens under the cursor. Move toward one and let go. Control media, volume, windows, apps, and shortcuts without reaching for the keyboard.

## Description

Gooey Wheel opens a ring of up to eight actions from a mouse button, wherever the cursor is. Click the button to open it, or hold the button, move toward an action, and release to run it. The ring draws in a liquid style: bubbles stretch, bridge, and pinch apart as they move.

Each bubble runs an action, chosen from about 80:

• Media: play and pause, skip, volume, mute, sound output and microphone input
• Windows: tile the front window to a half, fill or center it (macOS 15 or later), minimize, full screen, Mission Control and Spaces
• Apps: open an app, file, folder, or website, switch to the previous app, hide apps
• Editing: copy, paste, undo, find, new tab, and more, sent to the app in front
• Automation: any keyboard shortcut, typed text, and Shortcuts
• System: screenshots, Spotlight, the color picker, Keep Awake, Lock Screen

Some bubbles are controls. Volume turns into a slider you drag or scroll, Mute shows whether sound is on, and Sound Output opens into your audio devices.

Folders hold more actions. Rest the cursor on a folder and its items fan out around it. Right-click the open wheel to customize it: add and remove bubbles, drag them into folders, and pick each one's action, icon, color, and name. Icons can be SF Symbols, app icons, or your own pictures.

Gooey Wheel works with any mouse that has a middle or side button. It reads many Logitech mice directly, including buttons macOS doesn't report, such as the gesture button, and plays taps on mice with a haptic motor.

Gooey Wheel is free and open source. It needs Accessibility to take over the mouse button and send keyboard shortcuts, and Input Monitoring to read Logitech mice. It collects no data and makes no network connections.

## Keywords

radial,menu,mouse,button,ring,pie,launcher,shortcuts,window,manager,media,volume,haptic,actions

## What's New

The first App Store release of Gooey Wheel.

## Notes for App Review

Gooey Wheel is a menu bar app with no Dock icon. It needs no account or sign-in.

To try it:

1. Launch the app. A welcome panel plays a short video and then asks which mouse button should open the wheel.
2. Press a middle or side mouse button to assign it, or skip that and use Open Wheel in the app's menu bar item.
3. The wheel opens around the cursor. Click a bubble to run its action. Right-click the open wheel, or choose Customize in the menu bar item, to edit it.

Why it asks for each permission:

• Accessibility (posting events). Gooey Wheel turns a mouse button into a launcher for keyboard shortcuts, so it's an input utility: sending keystrokes is how nearly every action works. Choosing Copy sends ⌘C to the frontmost app, Space Left sends ⌃←, and Move Window sends the system's own Window → Move & Resize shortcuts. The app requests this with CGRequestPostEventAccess and sends events with CGEventPost. It also installs an event tap on mouse events that removes the assigned button's clicks from the event stream, so the button opens the wheel instead of acting in the app under the cursor. It doesn't use the AXUIElement API on other apps. Without the permission, the wheel still opens from the menu bar item, and actions that don't send keys (volume, sound output, opening apps, files, and websites) work.
• Input Monitoring. The app opens Logitech mice as HID devices to read buttons that macOS doesn't report as mouse buttons, such as the MX Master's thumb button. The field that records a keyboard shortcut also uses it while focused.
• USB and Bluetooth entitlements. Logitech mice connect through a USB receiver or Bluetooth. Over Bluetooth the app also reads the mouse's battery level.
• User-selected files. Open File and Open Folder actions open a file or folder the user picks in an Open panel, kept as an app-scoped bookmark. Custom icons are pictures the user picks.

The app uses only public APIs and makes no network connections.

Contact: through the App Review contact details on this account.
