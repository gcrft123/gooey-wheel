import Foundation

// Built-in actions for the wheel. Ids are stable: saved items look them up by id. Ids that
// were retired are mapped to their replacements in ActionCatalog+Migration.swift.
extension ActionCatalog {
    static let builtIn: [ActionCategory] = [
        ActionCategory(id: "media", title: "Media & Sound", symbol: "play.circle", actions: [
            ActionDefinition(id: "media.playPause", title: "Play/Pause", symbol: "playpause.fill", keywords: ["music", "pause", "resume"]),
            ActionDefinition(id: "media.next", title: "Next", symbol: "forward.fill", keywords: ["skip", "track"]),
            ActionDefinition(id: "media.previous", title: "Previous", symbol: "backward.fill", keywords: ["back", "track"]),
            ActionDefinition(
                id: "media.controls",
                title: "Media Controls",
                symbol: "music.note",
                control: .picker,
                keywords: ["now playing", "music", "player", "transport"]
            ),
            ActionDefinition(
                id: "media.volume",
                title: "Volume",
                symbol: "speaker.wave.2.fill",
                control: .slider,
                keywords: ["sound", "louder", "quieter", "up", "down"]
            ),
            ActionDefinition(id: "media.mute", title: "Mute", symbol: "speaker.slash.fill", control: .toggle, keywords: ["silence", "sound"]),
            ActionDefinition(
                id: "media.output",
                title: "Sound Output",
                symbol: "hifispeaker.fill",
                control: .picker,
                keywords: ["speakers", "headphones", "airpods", "audio device"]
            ),
            ActionDefinition(
                id: "media.input",
                title: "Microphone Input",
                symbol: "mic.fill",
                control: .picker,
                keywords: ["mic", "audio device", "input device"]
            ),
            ActionDefinition(
                id: "system.micMute",
                title: "Mute Microphone",
                symbol: "mic.slash.fill",
                control: .toggle,
                keywords: ["mic", "call", "meeting"]
            ),
        ]),
        ActionCategory(id: "desktop", title: "Windows & Desktop", symbol: "macwindow", actions: [
            ActionDefinition(
                id: "window.move",
                title: "Move Window",
                symbol: "inset.filled.lefthalf.rectangle",
                parameter: .choice(WindowLayout.choices),
                keywords: ["tile", "snap", "half", "third", "quarter", "maximize", "center", "resize", "layout"]
            ),
            ActionDefinition(id: "desktop.minimize", title: "Minimize", symbol: "minus.rectangle", keywords: ["window"]),
            ActionDefinition(
                id: "desktop.fullScreen",
                title: "Full Screen",
                symbol: "arrow.up.left.and.arrow.down.right.rectangle",
                keywords: ["fullscreen", "window"]
            ),
            ActionDefinition(
                id: "desktop.nextDisplay",
                title: "Next Display",
                symbol: "display.2",
                keywords: ["monitor", "move window", "screen"]
            ),
            ActionDefinition(id: "desktop.closeWindow", title: "Close Window", symbol: "xmark.rectangle"),
            ActionDefinition(id: "desktop.missionControl", title: "Mission Control", symbol: "rectangle.3.group", keywords: ["spaces", "windows"]),
            ActionDefinition(
                id: "desktop.appExpose",
                title: "App Exposé",
                symbol: "square.stack.3d.up",
                keywords: ["expose", "app windows"]
            ),
            ActionDefinition(
                id: "desktop.showDesktop",
                title: "Show Desktop",
                symbol: "menubar.dock.rectangle",
                keywords: ["hide windows"]
            ),
            ActionDefinition(
                id: "desktop.launchpad",
                title: "Apps",
                symbol: "square.grid.3x3.fill",
                keywords: ["launchpad", "applications"]
            ),
            ActionDefinition(id: "desktop.spaceLeft", title: "Space Left", symbol: "chevron.left.2", keywords: ["previous desktop"]),
            ActionDefinition(id: "desktop.spaceRight", title: "Space Right", symbol: "chevron.right.2", keywords: ["next desktop"]),
            ActionDefinition(
                id: "desktop.stageManager",
                title: "Stage Manager",
                symbol: "square.3.layers.3d.down.right",
                control: .toggle,
                keywords: ["stage"]
            ),
            ActionDefinition(
                id: "desktop.switchApps",
                title: "Previous App",
                symbol: "arrow.left.arrow.right.square",
                keywords: ["switch", "command tab", "last app"]
            ),
            ActionDefinition(id: "desktop.hideApp", title: "Hide App", symbol: "eye.slash"),
            ActionDefinition(id: "desktop.hideOthers", title: "Hide Others", symbol: "rectangle.on.rectangle", keywords: ["focus", "declutter"]),
            ActionDefinition(
                id: "desktop.quitFront",
                title: "Quit App",
                symbol: "xmark.app",
                keywords: ["quit", "cmd q", "close app"]
            ),
        ]),
        ActionCategory(id: "system", title: "System", symbol: "gearshape", actions: [
            ActionDefinition(
                id: "system.screenshot",
                title: "Screenshot",
                symbol: "camera.viewfinder",
                parameter: .choice(Screenshot.choices),
                keywords: ["capture", "grab", "screen recording", "selection", "clipboard"]
            ),
            ActionDefinition(
                id: "system.brightness",
                title: "Brightness",
                symbol: "sun.max.fill",
                control: .slider,
                keywords: ["display", "screen", "dim"]
            ),
            ActionDefinition(
                id: "system.keyboardBrightness",
                title: "Keyboard Brightness",
                symbol: "light.max",
                control: .slider,
                keywords: ["backlight", "keyboard light"]
            ),
            ActionDefinition(
                id: "system.doNotDisturb",
                title: "Do Not Disturb",
                symbol: "moon.fill",
                control: .toggle,
                keywords: ["focus", "dnd", "silent", "notifications"]
            ),
            ActionDefinition(
                id: "system.appearance",
                title: "Dark Mode",
                symbol: "circle.lefthalf.filled",
                control: .toggle,
                keywords: ["appearance", "light mode", "theme"]
            ),
            ActionDefinition(
                id: "system.keepAwake",
                title: "Keep Awake",
                symbol: "cup.and.saucer.fill",
                control: .toggle,
                keywords: ["caffeinate", "amphetamine", "no sleep", "prevent sleep"]
            ),
            ActionDefinition(
                id: "system.wifi",
                title: "Wi-Fi",
                symbol: "wifi",
                control: .toggle,
                keywords: ["wireless", "network", "airport"]
            ),
            ActionDefinition(
                id: "system.colorPicker",
                title: "Pick Color",
                symbol: "eyedropper",
                keywords: ["color picker", "eyedropper", "hex"]
            ),
            ActionDefinition(id: "system.spotlight", title: "Spotlight", symbol: "magnifyingglass", keywords: ["search"]),
            ActionDefinition(
                id: "system.notificationCenter",
                title: "Notification Center",
                symbol: "list.bullet.rectangle",
                keywords: ["notifications", "widgets"]
            ),
            ActionDefinition(id: "system.controlCenter", title: "Control Center", symbol: "switch.2"),
            ActionDefinition(id: "system.dictation", title: "Dictation", symbol: "waveform", keywords: ["speech", "voice"]),
            ActionDefinition(
                id: "system.emoji",
                title: "Emoji & Symbols",
                symbol: "face.smiling",
                keywords: ["emoji", "character viewer"]
            ),
            ActionDefinition(id: "system.siri", title: "Siri", symbol: "waveform.circle", keywords: ["assistant"]),
            ActionDefinition(
                id: "system.toggleDock",
                title: "Dock Hiding",
                symbol: "dock.rectangle",
                control: .toggle,
                keywords: ["autohide", "show dock", "hide dock"]
            ),
            ActionDefinition(id: "system.lockScreen", title: "Lock Screen", symbol: "lock.fill", keywords: ["secure", "away"]),
            ActionDefinition(id: "system.sleep", title: "Sleep", symbol: "moon.zzz.fill", keywords: ["suspend"]),
            ActionDefinition(
                id: "system.displaySleep",
                title: "Display Off",
                symbol: "display",
                keywords: ["display sleep", "screen off"]
            ),
            ActionDefinition(id: "system.screenSaver", title: "Screen Saver", symbol: "sparkles.tv", keywords: ["screensaver"]),
            ActionDefinition(id: "system.switchUser", title: "Switch User", symbol: "person.2.fill", keywords: ["account", "login window"]),
            ActionDefinition(
                id: "system.logOut",
                title: "Log Out",
                symbol: "rectangle.portrait.and.arrow.right",
                keywords: ["logout", "sign out"]
            ),
            ActionDefinition(id: "system.restart", title: "Restart", symbol: "arrow.clockwise", keywords: ["reboot"]),
            ActionDefinition(id: "system.shutDown", title: "Shut Down", symbol: "power", keywords: ["shutdown", "power off"]),
            ActionDefinition(id: "system.forceQuit", title: "Force Quit", symbol: "xmark.octagon.fill", keywords: ["kill", "frozen"]),
            ActionDefinition(id: "system.emptyTrash", title: "Empty Trash", symbol: "trash.fill", keywords: ["bin", "delete"]),
            ActionDefinition(
                id: WheelActions.customize,
                title: "Customize",
                symbol: "slider.horizontal.3",
                keywords: ["edit", "configure", "rearrange", "settings", "gooey", "customize wheel"]
            ),
        ]),
        ActionCategory(id: "edit", title: "Editing", symbol: "doc.on.doc", actions: [
            ActionDefinition(id: "edit.copy", title: "Copy", symbol: "doc.on.doc"),
            ActionDefinition(id: "edit.cut", title: "Cut", symbol: "scissors"),
            ActionDefinition(id: "edit.paste", title: "Paste", symbol: "doc.on.clipboard"),
            ActionDefinition(
                id: "edit.pasteMatchStyle",
                title: "Paste as Plain Text",
                symbol: "paintbrush.pointed",
                keywords: ["paste and match style", "unformatted"]
            ),
            ActionDefinition(
                id: "edit.undo",
                title: "Undo",
                symbol: "arrow.uturn.backward",
                control: .stepper,
                keywords: ["history", "redo"]
            ),
            ActionDefinition(id: "edit.redo", title: "Redo", symbol: "arrow.uturn.forward"),
            ActionDefinition(id: "edit.selectAll", title: "Select All", symbol: "selection.pin.in.out"),
            ActionDefinition(id: "edit.find", title: "Find", symbol: "magnifyingglass", keywords: ["search"]),
            ActionDefinition(id: "edit.save", title: "Save", symbol: "square.and.arrow.down"),
            ActionDefinition(id: "edit.new", title: "New", symbol: "document.badge.plus", keywords: ["create", "new document"]),
            ActionDefinition(id: "edit.open", title: "Open…", symbol: "folder", keywords: ["open document"]),
            ActionDefinition(id: "edit.print", title: "Print", symbol: "printer"),
            ActionDefinition(
                id: "edit.zoom",
                title: "Zoom",
                symbol: "plus.magnifyingglass",
                control: .stepper,
                keywords: ["zoom in", "zoom out", "actual size", "bigger", "smaller"]
            ),
        ]),
        ActionCategory(id: "navigation", title: "Browsing", symbol: "safari", actions: [
            ActionDefinition(id: "navigation.back", title: "Back", symbol: "chevron.backward", keywords: ["previous page"]),
            ActionDefinition(id: "navigation.forward", title: "Forward", symbol: "chevron.forward", keywords: ["next page"]),
            ActionDefinition(id: "edit.refresh", title: "Reload", symbol: "arrow.clockwise", keywords: ["refresh"]),
            ActionDefinition(id: "edit.newTab", title: "New Tab", symbol: "plus.square.on.square"),
            ActionDefinition(id: "edit.closeTab", title: "Close Tab", symbol: "xmark.square", keywords: ["close"]),
            ActionDefinition(
                id: "edit.reopenTab",
                title: "Reopen Tab",
                symbol: "arrow.uturn.backward.square",
                keywords: ["restore tab", "closed tab"]
            ),
            ActionDefinition(
                id: "navigation.tabs",
                title: "Switch Tab",
                symbol: "rectangle.stack",
                control: .stepper,
                keywords: ["next tab", "previous tab"]
            ),
            ActionDefinition(id: "navigation.home", title: "Top", symbol: "arrow.up.to.line", keywords: ["home", "start", "beginning"]),
            ActionDefinition(id: "navigation.end", title: "Bottom", symbol: "arrow.down.to.line", keywords: ["end"]),
        ]),
        ActionCategory(id: "apps", title: "Apps & Files", symbol: "square.grid.2x2", actions: [
            ActionDefinition(id: "apps.open", title: "Open App", symbol: "app", parameter: .application, keywords: ["launch"]),
            ActionDefinition(id: "apps.quit", title: "Quit an App", symbol: "xmark.app", parameter: .application, keywords: ["exit"]),
            ActionDefinition(id: "apps.openFile", title: "Open File", symbol: "document", parameter: .file),
            ActionDefinition(
                id: "apps.openFolder",
                title: "Open Folder",
                symbol: "folder",
                parameter: .folder,
                keywords: ["downloads", "documents", "desktop", "home", "applications", "trash", "finder"]
            ),
            ActionDefinition(
                id: "apps.openWebsite",
                title: "Open Link",
                symbol: "link",
                parameter: .url,
                keywords: ["url", "website", "browser", "web", "deep link"]
            ),
            ActionDefinition(id: "apps.airdrop", title: "AirDrop", symbol: "antenna.radiowaves.left.and.right", keywords: ["share"]),
            ActionDefinition(id: "apps.newFinderWindow", title: "New Finder Window", symbol: "macwindow.badge.plus", keywords: ["finder"]),
            ActionDefinition(id: "apps.recents", title: "Recents", symbol: "clock", keywords: ["recent files", "finder"]),
            ActionDefinition(id: "apps.quickLook", title: "Quick Look", symbol: "eye", keywords: ["preview", "finder"]),
            ActionDefinition(id: "apps.getInfo", title: "Get Info", symbol: "info.circle", keywords: ["inspector", "finder"]),
            ActionDefinition(id: "apps.moveToTrash", title: "Move to Trash", symbol: "document.on.trash", keywords: ["delete", "finder"]),
            ActionDefinition(id: "apps.ejectAll", title: "Eject All Disks", symbol: "eject.fill", keywords: ["unmount", "drives", "usb"]),
        ]),
        ActionCategory(id: "automation", title: "Automation", symbol: "gearshape.2", actions: [
            ActionDefinition(
                id: "automation.keystroke",
                title: "Keyboard Shortcut",
                symbol: "keyboard",
                parameter: .keystroke,
                keywords: ["hotkey", "keystroke", "keys"]
            ),
            ActionDefinition(
                id: "automation.typeText",
                title: "Type Text",
                symbol: "character.textbox",
                parameter: .text,
                keywords: ["insert", "snippet", "string"]
            ),
            ActionDefinition(
                id: "automation.copyText",
                title: "Copy Text",
                symbol: "clipboard.fill",
                parameter: .text,
                keywords: ["clipboard", "pasteboard", "snippet"]
            ),
            ActionDefinition(
                id: "automation.shortcut",
                title: "Run Shortcut",
                symbol: "square.stack.3d.up.fill",
                parameter: .shortcut,
                keywords: ["shortcuts", "workflow"]
            ),
        ] + scripts),
        ActionCategory(id: "mouse", title: "Mouse", symbol: "computermouse", actions: [
            ActionDefinition(
                id: "mouse.pointerSpeed",
                title: "Pointer Speed",
                symbol: "hare.fill",
                control: .slider,
                keywords: ["dpi", "sensitivity", "tracking", "resolution"]
            ),
            ActionDefinition(
                id: "mouse.precision",
                title: "Precision Mode",
                symbol: "scope",
                control: .toggle,
                keywords: ["slow", "dpi shift", "sniper"]
            ),
            ActionDefinition(
                id: "mouse.smartShift",
                title: "Free Spin",
                symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                control: .toggle,
                keywords: ["smartshift", "ratchet", "scroll wheel"]
            ),
            ActionDefinition(
                id: "mouse.haptics",
                title: "Mouse Haptics",
                symbol: "dot.radiowaves.left.and.right",
                control: .toggle,
                keywords: ["vibration", "feedback"]
            ),
            ActionDefinition(
                id: "mouse.scrollDirection",
                title: "Natural Scrolling",
                symbol: "arrow.up.and.down",
                control: .toggle,
                keywords: ["scroll direction", "invert", "reverse"]
            ),
            ActionDefinition(
                id: "device.easySwitch",
                title: "Easy-Switch",
                symbol: "arrow.left.arrow.right.square",
                control: .picker,
                keywords: ["channel", "host", "computer", "switch device"]
            ),
            ActionDefinition(
                id: "device.battery",
                title: "Mouse Battery",
                symbol: "battery.75percent",
                control: .readout,
                keywords: ["charge", "status"]
            ),
        ]),
    ]

    /// Commands and AppleScripts, run as programs. The App Store edition can't run them, so it
    /// leaves them out of the binary as well as the catalog.
    #if APPSTORE
    private static let scripts: [ActionDefinition] = []
    #else
    private static let scripts: [ActionDefinition] = [
        ActionDefinition(
            id: "automation.shell",
            title: "Shell Command",
            symbol: "terminal",
            parameter: .shellCommand,
            keywords: ["bash", "zsh", "script"]
        ),
        ActionDefinition(
            id: "automation.appleScript",
            title: "AppleScript",
            symbol: "scroll.fill",
            parameter: .appleScript,
            keywords: ["osascript", "script"]
        ),
    ]
    #endif
}

/// The places Move Window puts the front window, as fractions of the screen's visible area.
enum WindowLayout {
    #if APPSTORE
    /// Those the system's tiling has a shortcut for.
    static let choices = all.filter { choice in WindowTiling.keys.contains { $0.layout == choice.id } }
    #else
    static let choices = all
    #endif

    static let all: [ActionChoice] = [
        ActionChoice(id: "leftHalf", title: "Left Half", symbol: "inset.filled.lefthalf.rectangle"),
        ActionChoice(id: "rightHalf", title: "Right Half", symbol: "inset.filled.righthalf.rectangle"),
        ActionChoice(id: "topHalf", title: "Top Half", symbol: "inset.filled.tophalf.rectangle"),
        ActionChoice(id: "bottomHalf", title: "Bottom Half", symbol: "inset.filled.bottomhalf.rectangle"),
        ActionChoice(id: "topLeft", title: "Top Left", symbol: "inset.filled.topleft.rectangle"),
        ActionChoice(id: "topRight", title: "Top Right", symbol: "inset.filled.topright.rectangle"),
        ActionChoice(id: "bottomLeft", title: "Bottom Left", symbol: "inset.filled.bottomleft.rectangle"),
        ActionChoice(id: "bottomRight", title: "Bottom Right", symbol: "inset.filled.bottomright.rectangle"),
        ActionChoice(id: "leftThird", title: "Left Third", symbol: "inset.filled.leftthird.rectangle"),
        ActionChoice(id: "centerThird", title: "Center Third", symbol: "rectangle.split.3x1"),
        ActionChoice(id: "rightThird", title: "Right Third", symbol: "inset.filled.rightthird.rectangle"),
        ActionChoice(id: "leftTwoThirds", title: "Left Two Thirds", symbol: "rectangle.leadinghalf.inset.filled"),
        ActionChoice(id: "rightTwoThirds", title: "Right Two Thirds", symbol: "rectangle.trailinghalf.inset.filled"),
        ActionChoice(id: "maximize", title: "Maximize", symbol: "inset.filled.rectangle"),
        ActionChoice(id: "almostMaximize", title: "Almost Maximize", symbol: "rectangle.inset.filled"),
        ActionChoice(id: "maximizeHeight", title: "Maximize Height", symbol: "arrow.up.and.down.square"),
        ActionChoice(id: "center", title: "Center", symbol: "inset.filled.center.rectangle"),
        ActionChoice(id: "restore", title: "Restore", symbol: "arrow.down.right.and.arrow.up.left"),
    ]
}

enum Screenshot {
    static let choices: [ActionChoice] = [
        ActionChoice(id: "selection", title: "Screenshot", symbol: "camera.viewfinder"),
        ActionChoice(id: "window", title: "Capture Window", symbol: "macwindow"),
        ActionChoice(id: "screen", title: "Capture Screen", symbol: "display"),
        ActionChoice(id: "selectionClipboard", title: "Copy Selection", symbol: "doc.on.clipboard"),
        ActionChoice(id: "toolbar", title: "Screenshot & Record", symbol: "record.circle"),
    ]
}
