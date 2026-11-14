import Foundation

/// Short taps from the mouse's haptic motor, for the wheel to give feedback through the hand.
///
/// They are HID++ 0x19B0 waveforms. The mouse also describes a standard HID haptics output
/// report (0x3D), but over Bluetooth it never acknowledges a write to it: on 2026-11-13 one such
/// write held up every request to the mouse for the 30-second ATT timeout, after which macOS
/// dropped the connection. Don't use it.
///
/// Each tap is a HID++ request, so for a few seconds after one the mouse sends its wheel reports
/// to this app instead of Logi Options+ (see `MouseWheelEvents`).
enum MouseHaptics {
    enum Kind {
        /// The pointer moved onto a bubble.
        case hover
        /// A slider moved by one notch.
        case step
        /// A slider reached its end.
        case limit
        /// An item was chosen.
        case select

        /// The 0x19B0 waveform played for it.
        var waveform: UInt8 {
            switch self {
            case .hover: return 0x1B // whisper collision
            case .step: return 0x04 // subtle collision
            case .limit: return 0x02 // sharp collision
            case .select: return 0x00 // sharp state change
            }
        }
    }

    /// Taps closer together than this blur into a buzz, so the later one is dropped.
    static let minimumGap: TimeInterval = 0.04
    private static var lastPlayed: TimeInterval = -.infinity

    /// Plays a tap, if the mouse has haptics and they're turned on. A tap that would wait behind
    /// other requests to the mouse is dropped, since it would arrive late. Returns whether one
    /// was sent.
    @discardableResult
    static func play(_ kind: Kind) -> Bool {
        guard let mouse = MouseLink.shared.mouse, MouseState.shared.haptics?.enabled == true, !mouse.isBusy else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPlayed >= minimumGap else { return false }
        lastPlayed = now
        // Function 4 plays a waveform. Its reply isn't needed, so the queue doesn't wait for it.
        MouseLink.shared.post(HIDPPFeature.haptic, 4, [kind.waveform])
        return true
    }
}
