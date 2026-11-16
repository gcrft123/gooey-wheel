import Foundation

/// One of a fixed set of values an action can be set to, such as a window layout. An item set
/// to a choice is named and drawn after it.
struct ActionChoice: Equatable {
    /// Saved with the item. Stable.
    let id: String
    let title: String
    /// SF Symbol for an item set to this choice. Nil keeps the action's own.
    var symbol: String? = nil
}

/// What an action needs set before it can run. The Change action panel shows one editor per case,
/// and the item stores the value as a single string.
enum ActionParameter: Equatable {
    /// An installed app, stored as its bundle identifier.
    case application
    /// A file path.
    case file
    /// A folder path.
    case folder
    case url
    case shellCommand
    case appleScript
    /// The name of a shortcut in the Shortcuts app.
    case shortcut
    /// A key combination, stored in menu notation such as "⌃⌥⌘T".
    case keystroke
    /// Text typed at the cursor.
    case text
    /// One of a fixed set of values, stored as the chosen value's id. Unset means the first.
    case choice([ActionChoice])
}

/// How an item shows and changes something that has a state, beyond running once.
enum ActionControl: Equatable {
    /// On or off. The bubble shows which, and choosing it flips it.
    case toggle
    /// A level. The bubble shows it, scrolling over it changes it, and choosing or dragging it
    /// turns the bubble into a bar.
    case slider
    /// Scrolling over the bubble steps something, such as zoom or the current tab. Choosing
    /// it does the action once.
    case stepper
    /// Opens like a folder into choices found when it opens, such as sound outputs.
    case picker
    /// Shows a reading, such as a battery level.
    case readout
}

struct ActionDefinition {
    /// Stable identifier saved with each wheel item, such as "media.playPause".
    let id: String
    let title: String
    /// SF Symbol name used when the item has no custom icon.
    let symbol: String
    var parameter: ActionParameter? = nil
    var control: ActionControl? = nil
    /// Extra words the action list's search matches besides the title.
    var keywords: [String] = []

    var choices: [ActionChoice] {
        if case .choice(let choices) = parameter { return choices }
        return []
    }

    /// The choice an argument picks: the one saved, or the first.
    func choice(_ argument: String?) -> ActionChoice? {
        choices.first { $0.id == argument } ?? choices.first
    }
}

struct ActionCategory {
    let id: String
    let title: String
    let symbol: String
    let actions: [ActionDefinition]
}

enum ActionCatalog {
    #if APPSTORE
    static let categories: [ActionCategory] = builtIn.map { category in
        ActionCategory(id: category.id, title: category.title, symbol: category.symbol,
                       actions: category.actions.filter { leftOut[$0.id] == nil })
    }

    /// Actions the App Store edition doesn't have, with their names for items that used them.
    /// Each needs a private interface, another app's preferences, or a program run outside the
    /// App Sandbox. Shortcuts stands in for shell commands and AppleScript.
    static let leftOut: [String: String] = [
        "desktop.stageManager": "Stage Manager",
        "system.brightness": "Brightness",
        "system.keyboardBrightness": "Keyboard Brightness",
        "system.doNotDisturb": "Do Not Disturb",
        "system.appearance": "Dark Mode",
        "system.wifi": "Wi-Fi",
        "system.notificationCenter": "Notification Center",
        "system.controlCenter": "Control Center",
        "system.dictation": "Dictation",
        "system.displaySleep": "Display Off",
        "system.switchUser": "Switch User",
        "system.restart": "Restart",
        "system.shutDown": "Shut Down",
        "mouse.scrollDirection": "Natural Scrolling",
        // A sandboxed app's request to quit another app is refused.
        "apps.quit": "Quit an App",
        "automation.shell": "Shell Command",
        "automation.appleScript": "AppleScript",
    ]
    #else
    static let categories: [ActionCategory] = builtIn
    #endif

    private static let byID: [String: ActionDefinition] = {
        var map: [String: ActionDefinition] = [:]
        for category in categories {
            for action in category.actions { map[action.id] = action }
        }
        return map
    }()

    static func action(_ id: String) -> ActionDefinition? { byID[id] }

    static func category(of actionID: String) -> ActionCategory? {
        categories.first { $0.actions.contains { $0.id == actionID } }
    }
}
