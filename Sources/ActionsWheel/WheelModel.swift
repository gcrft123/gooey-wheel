import Foundation

struct WheelAction {
    let title: String
    let symbol: String
    var children: [WheelAction] = []

    var isFolder: Bool { !children.isEmpty }
}

enum WheelContent {
    /// At the root, slot 0 sits at 12 o'clock and the rest follow clockwise. A folder's items
    /// fan out from the top of its arc.
    static let root: [WheelAction] = [
        WheelAction(title: "Screenshot", symbol: "camera.viewfinder"),
        WheelAction(title: "Mission Control", symbol: "rectangle.3.group"),
        WheelAction(title: "Media", symbol: "music.note", children: [
            WheelAction(title: "Previous", symbol: "backward.fill"),
            WheelAction(title: "Play/Pause", symbol: "playpause.fill"),
            WheelAction(title: "Next", symbol: "forward.fill"),
            WheelAction(title: "Volume Up", symbol: "speaker.wave.3.fill"),
            WheelAction(title: "Volume Down", symbol: "speaker.wave.1.fill"),
            WheelAction(title: "Mute", symbol: "speaker.slash.fill"),
        ]),
        WheelAction(title: "Emoji", symbol: "face.smiling"),
        WheelAction(title: "Lock Screen", symbol: "lock"),
        WheelAction(title: "Paste", symbol: "doc.on.clipboard"),
        WheelAction(title: "Apps", symbol: "square.grid.2x2", children: [
            WheelAction(title: "Safari", symbol: "safari"),
            WheelAction(title: "Mail", symbol: "envelope"),
            WheelAction(title: "Notes", symbol: "note.text"),
            WheelAction(title: "Calendar", symbol: "calendar"),
            WheelAction(title: "Terminal", symbol: "terminal"),
            WheelAction(title: "Finder", symbol: "folder"),
        ]),
        WheelAction(title: "Copy", symbol: "doc.on.doc"),
    ]
}
