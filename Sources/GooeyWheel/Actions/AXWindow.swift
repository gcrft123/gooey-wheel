import AppKit

/// The window server's number for the window an element stands for. Private to HIServices, and
/// what Rectangle and other window managers use to tell windows apart.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A window of some app, read and changed through the Accessibility API as Rectangle does.
/// Frames are in AppKit screen coordinates; the conversion to the API's top-left origin
/// happens here.
struct AXWindow {
    let element: AXUIElement
    let app: AXUIElement
    let pid: pid_t

    /// The focused window of `app`, or its main window, or its first.
    /// `timeout` bounds each request, so an app that has stopped answering can't stall the wheel.
    static func focused(of app: NSRunningApplication?, timeout: Float = 0.5) throws -> AXWindow {
        guard AXIsProcessTrusted() else { throw ActionError.needsAccessibility }
        guard let app = app ?? NSWorkspace.shared.frontmostApplication else {
            throw ActionError.failed("No app is in front")
        }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        let window = element(appElement, kAXFocusedWindowAttribute)
            ?? element(appElement, kAXMainWindowAttribute)
            ?? (copy(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { throw ActionError.failed("\(app.localizedName ?? "The app") has no window") }
        AXUIElementSetMessagingTimeout(window, timeout)
        return AXWindow(element: window, app: appElement, pid: pid)
    }

    /// Identifies the window across reads: the same window read twice gives the same key.
    var key: Key? {
        var id = CGWindowID(0)
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return Key(pid: pid, window: id)
    }

    struct Key: Hashable {
        let pid: pid_t
        let window: CGWindowID
    }

    // MARK: Frame

    /// Read with one request for both position and size.
    var frame: CGRect? {
        var values: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
              let pair = values as? [AnyObject], pair.count == 2,
              let origin = Self.point(pair[0]), let size = Self.size(pair[1]),
              let primary = Self.primaryHeight
        else { return nil }
        return WindowGeometry.flipped(CGRect(origin: origin, size: size), primaryHeight: primary)
    }

    /// Moves and resizes the window, then pulls it back inside `visible` if the app kept it
    /// larger than asked, as apps do for windows with a minimum size.
    func setFrame(_ target: CGRect, within visible: CGRect) {
        guard let primary = Self.primaryHeight else { return }
        // VoiceOver and some utilities turn this on, and while it's on apps animate each change
        // and may ignore the next one. Rectangle turns it off for the move.
        let enhanced = bool(app, "AXEnhancedUserInterface") == true
        if enhanced { setBool(app, "AXEnhancedUserInterface", false) }
        defer { if enhanced { setBool(app, "AXEnhancedUserInterface", true) } }

        let flipped = WindowGeometry.flipped(target, primaryHeight: primary)
        // Size first so the window fits where it's going, then the position, then the size
        // again, since an app may have limited the first resize to the screen it was on.
        setSize(flipped.size)
        setPosition(flipped.origin)
        setSize(flipped.size)

        guard let actual = frame, !WindowGeometry.same(actual, target) else { return }
        let fitted = WindowGeometry.fitted(actual, in: visible)
        if fitted.origin != actual.origin {
            setPosition(WindowGeometry.flipped(fitted, primaryHeight: primary).origin)
        }
    }

    private func setSize(_ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private func setPosition(_ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    /// The visible frame of the screen holding most of the window.
    var screenVisibleFrame: CGRect? {
        guard let frame else { return nil }
        let screens = NSScreen.screens
        return WindowGeometry.screenIndex(for: frame, among: screens.map(\.frame)).map { screens[$0].visibleFrame }
    }

    /// The height of the screen with the menu bar, which the API's coordinates are measured from.
    static var primaryHeight: CGFloat? {
        NSScreen.screens.first?.frame.maxY
    }

    // MARK: State

    var isFullScreen: Bool? { bool(element, "AXFullScreen") }

    func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func set(_ attribute: String, _ value: Bool) -> Bool {
        setBool(element, attribute, value)
    }

    /// Presses one of the title bar's buttons, such as `kAXCloseButtonAttribute`. Returns false
    /// when the window has no such button or it didn't take the press.
    func pressButton(_ attribute: String) -> Bool {
        guard let button = Self.element(element, attribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    // MARK: Reading values

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        Self.copy(element, attribute) as? Bool
    }

    @discardableResult
    private func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }

    private static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
