import Foundation

/// Actions on the wheel itself.
enum WheelActions {
    /// Customize. Chosen on the wheel, it turns the open wheel into configuration in
    /// place, so its `run` is reached only from elsewhere, such as `--run-action`.
    static let customize = "wheel.customize"
    /// Opens configuration. Set by the app once the wheel exists.
    static var openConfiguration: (() -> Void)?

    static let behaviors: [String: ActionBehavior] = {
        var customizeBehavior = ActionBehavior { _ in
            guard let open = openConfiguration else { throw ActionError.unavailable("Customize") }
            open()
        }
        // Teaches the shortcut that makes the bubble unnecessary.
        customizeBehavior.liveDetail = { _ in "Or right-click" }
        return [customize: customizeBehavior]
    }()
}
