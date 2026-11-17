// The App Store edition gets its updates from the App Store.
#if !APPSTORE
import AppKit
import Sparkle

/// Checks the appcast published with each GitHub release, through Sparkle, and installs the
/// updates it lists. Sparkle asks on the second launch whether to check automatically.
final class Updater: NSObject, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController!
    /// The menu item that checks for updates. It reads "Update Available…" while a scheduled
    /// check has found an update the user hasn't looked at yet.
    let menuItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")

    /// Nil when the app isn't running from a bundle with a feed, such as from `swift run`.
    static func make() -> Updater? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return Updater()
    }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        menuItem.target = self
        menuItem.action = #selector(checkForUpdates)
    }

    @objc private func checkForUpdates() {
        // A menu bar app isn't active, so Sparkle's window would open behind the frontmost app.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Sparkle can't start a check while it is fetching the feed or downloading an update.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        controller.updater.canCheckForUpdates
    }

    // MARK: SPUStandardUserDriverDelegate

    /// An update found by a scheduled check shows in the menu instead of opening a window over
    /// whatever the user is doing.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle offers immediate focus for the first seconds after launch, when the wheel opens.
    /// Declining it keeps every scheduled update in the menu. Checks the user starts aren't asked.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        menuItem.title = "Update Available…"
        if #available(macOS 14.4, *) { menuItem.subtitle = "Version \(update.displayVersionString)" }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        resetMenuItem()
    }

    func standardUserDriverWillFinishUpdateSession() {
        resetMenuItem()
    }

    private func resetMenuItem() {
        menuItem.title = "Check for Updates…"
        if #available(macOS 14.4, *) { menuItem.subtitle = nil }
    }
}
#endif
