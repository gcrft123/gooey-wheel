import Foundation
import simd

/// A color the user gave an item, saved as "#RRGGBB".
struct ItemColor: Codable, Equatable {
    var rgb: SIMD3<Float>

    init(_ r: Float, _ g: Float, _ b: Float) {
        rgb = SIMD3(r, g, b)
    }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        rgb = SIMD3(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
    }

    var hex: String {
        let c = simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 255
        return String(format: "#%02X%02X%02X", Int(c.x.rounded()), Int(c.y.rounded()), Int(c.z.rounded()))
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = ItemColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected #RRGGBB"))
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// One bubble on the wheel: an action or a folder of actions.
struct WheelItem: Codable, Equatable, Identifiable {
    var id = UUID()
    /// An `ActionCatalog` id. Nil for folders, and for an item that has no action yet.
    var actionID: String?
    /// The action's parameter, such as a bundle identifier or a shell command.
    var argument: String?
    var customTitle: String?
    var customSymbol: String?
    var color: ItemColor?
    /// Non-nil makes this a folder. Folders don't nest.
    var children: [WheelItem]?

    var isFolder: Bool { children != nil }

    /// The custom name, or the action's.
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if isFolder { return "Folder" }
        guard let action = actionID.flatMap(ActionCatalog.action) else { return "New Action" }
        if let argument, !argument.isEmpty, let name = Self.describe?(action, argument) { return name }
        return action.title
    }

    /// Names an item after what its action is set to, such as the app it opens. Set at launch,
    /// because finding that name needs more than this file knows about.
    static var describe: ((ActionDefinition, String) -> String?)?

    /// The custom icon, or the action's.
    var symbol: String {
        if let customSymbol, !customSymbol.isEmpty { return customSymbol }
        if isFolder { return "folder" }
        return actionID.flatMap(ActionCatalog.action)?.symbol ?? "app.dashed"
    }

    static func action(_ id: String, argument: String? = nil, title: String? = nil, symbol: String? = nil) -> WheelItem {
        WheelItem(actionID: id, argument: argument, customTitle: title, customSymbol: symbol)
    }

    static func folder(_ title: String, symbol: String, _ children: [WheelItem]) -> WheelItem {
        WheelItem(customTitle: title, customSymbol: symbol, children: children)
    }
}

/// Where a ring's items are kept: the top of the wheel or inside one folder.
enum Container: Equatable {
    case root
    case folder(UUID)
}

enum WheelLimits {
    static let rootItems = 8
    static let folderItems = 6

    static func capacity(of container: Container) -> Int {
        container == .root ? rootItems : folderItems
    }
}

extension WheelItem {
    /// At the root, slot 0 sits at 12 o'clock and the rest follow clockwise. A folder's items
    /// fan out from the top of its arc.
    static let defaults: [WheelItem] = [
        .action("system.screenshot"),
        .action("desktop.missionControl"),
        .folder("Media", symbol: "music.note", [
            .action("media.previous"),
            .action("media.playPause"),
            .action("media.next"),
            .action("media.volumeUp"),
            .action("media.volumeDown"),
            .action("media.mute"),
        ]),
        .action("system.emoji"),
        .action("system.lockScreen"),
        .action("edit.paste"),
        .folder("Apps", symbol: "square.grid.2x2", [
            .action("apps.open", argument: "com.apple.Safari", title: "Safari", symbol: "safari"),
            .action("apps.open", argument: "com.apple.mail", title: "Mail", symbol: "envelope"),
            .action("apps.open", argument: "com.apple.Notes", title: "Notes", symbol: "note.text"),
            .action("apps.open", argument: "com.apple.iCal", title: "Calendar", symbol: "calendar"),
            .action("apps.open", argument: "com.apple.Terminal", title: "Terminal", symbol: "terminal"),
            .action("apps.open", argument: "com.apple.finder", title: "Finder", symbol: "folder"),
        ]),
        .action("edit.copy"),
    ]
}
