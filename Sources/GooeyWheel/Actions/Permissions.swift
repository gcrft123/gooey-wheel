import AppKit

/// The privileges that posting input and the event taps need. The direct download asks for
/// Accessibility, which covers both and also reaching other apps' windows. The App Sandbox
/// doesn't allow Accessibility on other apps, so the App Store edition asks for the privileges
/// it uses: posting events, which System Settings lists under Accessibility, and listening to
/// the keyboard, listed under Input Monitoring.
enum Permissions {
    /// Posting key presses, and the event tap that takes the mouse button.
    static var canPostEvents: Bool {
        #if APPSTORE
        CGPreflightPostEventAccess()
        #else
        AXIsProcessTrusted()
        #endif
    }

    /// Shows the system's prompt and lists the app in System Settings → Accessibility.
    /// Returns whether it is already allowed.
    @discardableResult
    static func requestPostEvents() -> Bool {
        #if APPSTORE
        CGRequestPostEventAccess()
        #else
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
        #endif
    }

    /// The event tap the key combination field uses to take presses before the system does.
    static var canTapKeys: Bool {
        #if APPSTORE
        CGPreflightListenEventAccess()
        #else
        AXIsProcessTrusted()
        #endif
    }
}
