import Foundation
import IOKit.hidsystem

/// macOS's tracking speed for mice, the Tracking Speed slider in System Settings → Mouse. It
/// applies to every mouse, so Pointer Speed and Precision Mode use it for a mouse that has no
/// sensor resolution of its own to set.
///
/// The speed runs from 0 to 3. The HID event system holds it as `HIDMouseAcceleration`, in
/// 16.16 fixed point, and applies a change at once; `com.apple.mouse.scaling` in the global
/// domain keeps it for the next login. -1 turns acceleration off, which this reads as 0.
enum TrackingSpeed {
    static let range = 0.0...3.0
    /// The slider's tick marks in System Settings, which choosing Pointer Speed steps through.
    static let ticks = [0, 0.125, 0.5, 0.6875, 0.875, 1, 1.5, 2, 2.5, 3]

    private static let property = "HIDMouseAcceleration" as CFString
    private static let preference = "com.apple.mouse.scaling" as CFString
    private static let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    static var current: Double {
        if let fixed = IOHIDEventSystemClientCopyProperty(client, property) as? NSNumber {
            return clamp(fixed.doubleValue / 65536)
        }
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let saved = CFPreferencesCopyValue(preference, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return clamp((saved as? NSNumber)?.doubleValue ?? 1)
    }

    static func set(_ speed: Double) throws {
        let speed = clamp(speed)
        guard IOHIDEventSystemClientSetProperty(client, property, NSNumber(value: Int((speed * 65536).rounded()))) else {
            throw ActionError.failed("Couldn't change the tracking speed")
        }
        CFPreferencesSetValue(preference, NSNumber(value: speed), kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        NotificationCenter.default.post(name: ActionBehaviors.stateDidChange, object: nil)
    }

    static func level(of speed: Double) -> Double { clamp(speed) / range.upperBound }
    static func speed(forLevel level: Double) -> Double { clamp01(level) * range.upperBound }

    /// The tick after `speed`, wrapping around to the slowest.
    static func nextTick(after speed: Double) -> Double {
        ticks.first { $0 > speed + 0.001 } ?? ticks[0]
    }

    /// The slow speed for precision mode: a third of the usual speed, at most 0.5.
    static func precision(from speed: Double) -> Double {
        min(0.5, clamp(speed) / 3)
    }

    private static func clamp(_ speed: Double) -> Double {
        min(max(speed, range.lowerBound), range.upperBound)
    }
}
