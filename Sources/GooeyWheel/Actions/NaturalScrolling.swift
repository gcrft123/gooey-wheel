import Foundation

/// macOS's scroll direction, the "Natural scrolling" switch in System Settings.
///
/// The setting is `com.apple.swipescrolldirection` in the global domain, but writing it alone
/// changes nothing until the next login: the window server keeps its own copy. System Settings
/// calls `setSwipeScrollDirection` in the PreferencePanesSupport framework, which tells the
/// window server, writes the preference, and posts `SwipeScrollDirectionDidChangeNotification`
/// for apps that read it. This calls the same function, and does those steps itself on a macOS
/// that lacks it.
enum NaturalScrolling {
    private static let key = "com.apple.swipescrolldirection" as CFString
    private static let notification = "SwipeScrollDirectionDidChangeNotification"

    private typealias Setter = @convention(c) (Int) -> Void
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias WindowServerSetter = @convention(c) (Int32, Bool) -> Int32

    /// System Settings' own function, if this macOS has it.
    private static let systemSetter: Setter? = {
        _ = dlopen("/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/PreferencePanesSupport", RTLD_LAZY)
        return symbol("setSwipeScrollDirection", as: Setter.self)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }

    /// Whether natural scrolling is on. It is when the setting has never been changed.
    static var isOn: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? Bool) ?? true
    }

    static func set(_ on: Bool) throws {
        if let systemSetter {
            systemSetter(on ? 1 : 0)
        } else {
            guard let connection = symbol("_CGSDefaultConnection", as: ConnectionFunction.self),
                  let tell = symbol("CGSSetSwipeScrollDirection", as: WindowServerSetter.self) else {
                throw ActionError.unavailable("Natural Scrolling")
            }
            _ = tell(connection(), on)
            CFPreferencesSetValue(key, on ? kCFBooleanTrue : kCFBooleanFalse,kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            DistributedNotificationCenter.default().postNotificationName(.init(notification), object: nil, userInfo: nil, deliverImmediately: true)
        }
        guard isOn == on else { throw ActionError.failed("Natural Scrolling didn't change") }
    }
}
