# Instructions for coding agents

Gooey Wheel is a macOS menu bar app, written in Swift with AppKit and Metal, that opens a radial actions menu from a mouse button. Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing code, and [USERS.md](USERS.md) for how the app is meant to respond to users.

| Doc | Contents |
| --- | --- |
| [USERS.md](USERS.md) | How users interact with the app: every input, menu item, panel, and permission. The source of truth for intended behavior |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Modules, data flow, mouse input internals |
| [ACTIONS.md](ACTIONS.md) | Every action, its category, options, and control |
| [TESTING.md](TESTING.md) | Self-test, demos, off-screen captures, the mouse input log |
| [RELEASING.md](RELEASING.md) | The release script, signing, and the update feed |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Build setup and pull request conventions |

## The machine you're running on

Assume a person is using this Mac while you work, with the mouse the app reads. Everything below follows from that.

- Don't post global input. No synthetic `CGEvent` mouse moves, clicks, or key presses, and never a synthetic Esc. It takes over the user's pointer and keyboard. The demos and self-test drive their own windows with in-process events; use those.
- Don't quit, replace, or rebuild over the user's running `build/Gooey Wheel.app` to test. Run a separate copy from the build folder with `--store <scratch path>/wheel.json --no-mouse`.
- Keep anything you show on screen small and out of the way. Prefer off-screen captures (`--demo-capture`), which show nothing and work with the screen locked. The on-screen demo stage sits in the bottom-right corner for this reason.

## Mouse hardware

- Never send HID output report `0x3D` (the standard Simple Haptic Controller report) to the MX Master 4. Haptics go through HID++ feature `0x19B0` only, in `Actions/MouseHaptics.swift`.
- Don't send any output or feature report, or any kind of HID++ request, that the app doesn't already send, without asking the user first.
- The app is independent of Logi Options+. Don't read or edit Options+ settings, and don't propose Options+ button assignments as a way to integrate. Read the mouse directly, as `LogiButton.swift` does.
- Quitting Options+ leaves its agent (`logioptionsplus_agent`, bundle `com.logi.cp-dev-mgr`) running under launchd. "Options+ is quit" doesn't mean the agent is gone, and the agent still pulls HID++ notifications to its Bluetooth channel.
- A physical button press can't be simulated. Logitech buttons, the Bolt receiver, and haptic taps can only be confirmed by the user pressing the button. Say so instead of claiming they work.

## Building and running

```sh
swift build -c release --disable-keychain
bin="$(swift build -c release --disable-keychain --show-bin-path)/GooeyWheel"
./scripts/build-app.sh   # builds and signs build/Gooey Wheel.app
```

- Always pass `--disable-keychain` to SwiftPM. Without it, SwiftPM reads GitHub credentials from the login keychain and waits forever on a permission prompt nobody can see. Downloading the Sparkle binary also needs network access outside the sandbox.
- Sparkle's `generate_appcast` and `sign_update` hang the same way when they read the EdDSA key. Export the key with `generate_keys --account dev.gooey.wheel -x <path>` to a new path in a `mktemp -d` folder (it refuses to overwrite, so `/dev/stdout` fails), then pass `--ed-key-file`. `scripts/release.sh` already does this.
- Wrap any tool that might touch the keychain in `perl -e 'alarm 60; exec @ARGV' <command>` so a hidden prompt can't block the shell.
- Don't run `scripts/release.sh` without `--dry-run` unless the user asks for a release.

## Permissions

- A binary run from your shell uses your host terminal's privacy grants, not the app's. Passing there says nothing about whether `Gooey Wheel.app` has Accessibility or Input Monitoring.
- Grants belong to the app's signature. `build-app.sh` signs with the Apple Development certificate so grants survive rebuilds; an ad-hoc build loses them.
- A denied device open appears as `TCC deny IOHIDDeviceOpen` in `/usr/bin/log show --predicate 'processImagePath CONTAINS "GooeyWheel"'`. Use the full path: `log` is a zsh builtin. The app's `NSLog` lines don't show up there; use the `TriggerDebug` log instead (see [TESTING.md](TESTING.md#the-mouse-input-log)).

## Verifying changes

- Run `"$bin" --self-test` after any change to actions or the catalog. It doesn't disturb the user. Report failures with their output.
- For visual changes, capture from the build after your final edit with `--demo-capture`, look at the images yourself, and fix or report what's wrong.
- For motion, check the changed stretch frame by frame with `--demo-capture-frames <from>,<to>,<rate>`: at least 4 fps for cursor paths, every frame for transitions under a second. A few sampled stills have missed a visible jump before. Say plainly which parts you only saw as stills.
- When tiling frames into a contact sheet with ffmpeg over a `color` source, give the color source the same rate as the frames (`r=4`). Otherwise each frame repeats and the sheet covers a fraction of the time.
- `--welcome-record <folder>` writes the welcome panel frame by frame off screen. After changing the tour script, rerun `scripts/render-welcome-video.sh` to rebuild `assets/welcome.mov`.

## Code rules

- Action ids are saved in users' wheels and never change. To merge or retire an action, map its old id in `ActionCatalog+Migration.swift`. The `catalog.*` self-test checks catch missing behaviors, duplicate ids, missing SF Symbols, and controls without their hooks.
- The wheel and its panels animate every value with the closed-form springs in `Spring.swift`, with constants in `Tuning.swift`. Use them for anything drawn by the sim. Only the welcome panel's page turn uses Core Animation.
- Derive shapes and masks from the renderer's distance field instead of hand-tuned constants. The welcome panel's content mask is computed from the shader's field for this reason, after a guessed corner radius didn't match.
- New visual elements default to the app's goo look: shapes drawn by `GooRenderer`, round bubbles in corner cutouts for back and confirm, soft blurred color with film grain, no hard outlines.
- Private macOS interfaces are loaded at run time and fail soft: a missing symbol disables its action, never crashes the app.
- Comments say why, or what the code can't show. Don't add comments that restate the code.

## Docs

- The README holds instructions for users. Everything else lives in `docs/`. Update docs in the same change as the behavior: how the app responds to users in USERS.md (descriptive, not instructions), actions in ACTIONS.md, internals in ARCHITECTURE.md, flags in TESTING.md.
- Write docs the way the existing ones read: plain present-tense statements of what the app does, specific names and numbers, no marketing language. Don't wrap Markdown lines.

## Pull requests

- Branch from `main`. One change per pull request.
- Titles use Conventional Commits: `type(scope): description`, lowercase, no trailing period, such as `feat: read the thumb button through a Logi Bolt receiver`. Types are `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, and `chore`. Earlier PRs in the history predate this and don't follow it.
- Include a screenshot for visible changes and a short recording for motion. Say which hardware checks the user still needs to do.
