import AppKit

/// What an item's action is run with.
struct ActionInvocation {
    let argument: String?
    /// The app that was in front when the wheel opened. The wheel never takes focus, so it is
    /// still in front when the action runs.
    let frontmost: NSRunningApplication?

    static var current: ActionInvocation {
        ActionInvocation(argument: nil, frontmost: NSWorkspace.shared.frontmostApplication)
    }

    func with(argument: String?) -> ActionInvocation {
        ActionInvocation(argument: argument, frontmost: frontmost)
    }
}

enum ActionError: Error, CustomStringConvertible {
    /// Posting input or moving another app's windows needs the Accessibility permission.
    case needsAccessibility
    /// This Mac has nothing for the action to work on, such as no keyboard backlight.
    case unavailable(String)
    case failed(String)

    var description: String {
        switch self {
        case .needsAccessibility: return "Accessibility permission is needed"
        case .unavailable(let what): return "Unavailable: \(what)"
        case .failed(let why): return why
        }
    }
}

/// A level from 0 to 1 that a slider item shows and changes.
struct LevelControl {
    /// Nil when the level can't be read right now, such as a device with no volume control.
    var read: () -> Double?
    var write: (Double) throws -> Void
    /// How far one notch of a scroll wheel moves the level.
    var detent: Double = 1.0 / 16
    /// The level as the hub's label shows it, such as "45%".
    var format: (Double) -> String = { "\(Int((clamp01($0) * 100).rounded()))%" }
    /// A glyph that follows the level, such as a speaker with more waves. Nil keeps the item's.
    var symbol: ((Double) -> String)? = nil
}

/// One of the choices a picker item opens into, found when it opens.
struct LiveChoice: Equatable {
    let id: String
    let title: String
    let symbol: String
    /// The one in effect, such as the sound output in use. Its bubble is filled.
    var isCurrent = false
    /// Choosing it leaves the picker open, for something done several times in a row.
    var keepsOpen = false
}

/// What choosing an item does, and the live state the item shows.
struct ActionBehavior {
    enum Timing {
        /// Runs the moment the item is chosen, while the wheel drains away.
        case now
        /// Runs once the wheel is off the screen: for actions that capture the screen, show
        /// something over it, or need the pointer.
        case afterClose
    }

    var timing = Timing.now
    /// What choosing the item does. Nil for a picker, which opens instead.
    var run: ((ActionInvocation) throws -> Void)?
    /// Whether a toggle is on, or nil when that can't be read.
    var isOn: ((ActionInvocation) -> Bool?)? = nil
    /// The glyph for a toggle's state, or for some other state the action can read, such as
    /// whether something is playing. Nil keeps the item's.
    var liveSymbol: ((ActionInvocation) -> String?)? = nil
    /// A line added to the hub's label while the item is hovered, such as the track playing.
    var liveDetail: ((ActionInvocation) -> String?)? = nil
    var level: LevelControl? = nil
    /// Steps by whole notches of a scroll wheel: positive is down or right, negative up or left.
    var step: ((Int, ActionInvocation) throws -> Void)? = nil
    /// A picker's choices, and what choosing one does.
    var choices: ((ActionInvocation) -> [LiveChoice])? = nil
    var choose: ((LiveChoice, ActionInvocation) throws -> Void)? = nil
    /// Whether this Mac has what the action needs, such as a backlit keyboard.
    var isAvailable: () -> Bool = { true }
    /// What the toast says when the action isn't available, in place of "… isn't available on
    /// this Mac", such as for a feature the mouse lacks.
    var unavailableMessage: String? = nil

    init(timing: Timing = .now, run: ((ActionInvocation) throws -> Void)? = nil) {
        self.timing = timing
        self.run = run
    }

    init(timing: Timing = .now, isAvailable: @escaping () -> Bool, run: ((ActionInvocation) throws -> Void)? = nil) {
        self.timing = timing
        self.isAvailable = isAvailable
        self.run = run
    }

    /// An action that is a key combination sent to the app in front.
    static func keys(_ combo: KeyCombo, timing: Timing = .now) -> ActionBehavior {
        ActionBehavior(timing: timing) { _ in try KeySender.post(combo) }
    }
}

/// Every action's behavior, gathered from the files that implement them.
enum ActionBehaviors {
    private static let all: [String: ActionBehavior] = {
        var map: [String: ActionBehavior] = [:]
        for table in [
            EditingActions.behaviors,
            MediaActions.behaviors,
            AudioActions.behaviors,
            DisplayActions.behaviors,
            WindowActions.behaviors,
            SystemActions.behaviors,
            AppActions.behaviors,
            AutomationActions.behaviors,
            MouseActions.behaviors,
        ] {
            map.merge(table) { first, _ in first }
        }
        return map
    }()

    static func behavior(for id: String) -> ActionBehavior? { all[id] }

    /// Ids in the catalog that nothing implements. Empty in a finished build.
    static var unimplemented: [String] {
        ActionCatalog.categories.flatMap(\.actions).map(\.id).filter { all[$0] == nil }
    }
}
