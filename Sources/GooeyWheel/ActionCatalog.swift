import Foundation

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
    /// One of a fixed set of values, stored as the chosen value.
    case choice([String])
    /// A number in a range, such as a volume level. Stored as a decimal string.
    case level(ClosedRange<Double>, unit: String)
}

struct ActionDefinition {
    /// Stable identifier saved with each wheel item, such as "media.playPause".
    let id: String
    let title: String
    /// SF Symbol name used when the item has no custom icon.
    let symbol: String
    var parameter: ActionParameter? = nil
    /// Extra words the action list's search matches besides the title.
    var keywords: [String] = []
}

struct ActionCategory {
    let id: String
    let title: String
    let symbol: String
    let actions: [ActionDefinition]
}

enum ActionCatalog {
    static let categories: [ActionCategory] = builtIn

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
