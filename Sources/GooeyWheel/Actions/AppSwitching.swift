import AppKit

/// The apps that came to the front, most recent first, as NSWorkspace reported them. This is
/// the order ⌘Tab shows. It starts with the app in front when it's first used, and learns the
/// rest as apps are activated.
final class AppHistory {
    static let shared = AppHistory()

    private(set) var recent: [pid_t] = []
    private static let limit = 32

    private init() {
        if let front = NSWorkspace.shared.frontmostApplication { activated(front.processIdentifier) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activated(app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recent.removeAll { $0 == app.processIdentifier }
        }
    }

    private func activated(_ pid: pid_t) {
        recent.removeAll { $0 == pid }
        recent.insert(pid, at: 0)
        if recent.count > Self.limit { recent.removeLast() }
    }
}

/// Which apps Previous App, Hide Others and Quit App act on. The decisions are kept apart from
/// the acting so they can be checked without touching anyone's apps.
enum AppSwitching {
    /// What the decisions need to know about a running app.
    struct App: Equatable {
        let pid: pid_t
        /// Has a Dock icon and windows, as opposed to a menu bar extra or a background agent.
        let isRegular: Bool
        let isHidden: Bool

        init(pid: pid_t, isRegular: Bool = true, isHidden: Bool = false) {
            self.pid = pid
            self.isRegular = isRegular
            self.isHidden = isHidden
        }

        init(_ app: NSRunningApplication) {
            self.init(pid: app.processIdentifier, isRegular: app.activationPolicy == .regular, isHidden: app.isHidden)
        }
    }

    /// The app to bring forward: the most recently active one in `recent` that isn't in front,
    /// or, when the history doesn't go back that far, the owner of the frontmost window in
    /// `windowOwners` (front to back) that isn't. Only `running` regular apps other than
    /// `exclude` count.
    static func previousApp(recent: [pid_t], windowOwners: [pid_t], frontmost: pid_t?, running: [App], exclude: pid_t) -> pid_t? {
        let candidates = Set(running.filter(\.isRegular).map(\.pid)).subtracting([exclude])
        func eligible(_ pid: pid_t) -> Bool { pid != frontmost && candidates.contains(pid) }
        return recent.first(where: eligible) ?? windowOwners.first(where: eligible)
    }

    /// The apps Hide Others hides: every regular app that's showing, except the one in front
    /// and `exclude`.
    static func appsToHide(running: [App], frontmost: pid_t?, exclude: pid_t) -> [pid_t] {
        running.filter { $0.isRegular && !$0.isHidden && $0.pid != frontmost && $0.pid != exclude }.map(\.pid)
    }

    /// The app Quit App asks to quit: the one in front, unless it's `exclude`, the wheel itself,
    /// which is only in front while its settings are open.
    static func appToQuit(frontmost: pid_t?, exclude: pid_t) -> pid_t? {
        frontmost == exclude ? nil : frontmost
    }

    /// The apps owning windows on screen in the normal layer, front to back. Only window
    /// numbers, owners, layers and bounds are read, which needs no Screen Recording permission.
    static func windowOwnersFrontToBack() -> [pid_t] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var owners: [pid_t] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  // Apps keep tiny or invisible helper windows in the normal layer.
                  bounds.width >= 40, bounds.height >= 40,
                  !owners.contains(pid)
            else { continue }
            owners.append(pid)
        }
        return owners
    }

    static var runningApps: [App] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(App.init)
    }

    // MARK: Acting

    /// Brings `app` to the front with all its windows, as ⌘Tab does. An app that isn't active
    /// may be refused activation under macOS 14's cooperative activation, so with Accessibility
    /// the app is also made frontmost through its accessibility element, which isn't refused.
    static func activate(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateAllWindows])
        #if !APPSTORE
        if AXIsProcessTrusted() {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        #endif
    }
}
