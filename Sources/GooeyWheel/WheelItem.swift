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
        if let choice = action.choice(argument) { return choice.title }
        if let argument, !argument.isEmpty, let name = Self.describe?(action, argument) { return name }
        return action.title
    }

    /// Names an item after what its action is set to, such as the app it opens. Set at launch,
    /// because finding that name needs more than this file knows about.
    static var describe: ((ActionDefinition, String) -> String?)?

    /// The custom icon, or the action's: the one for what it is set to, if that has its own.
    var symbol: String {
        if let customSymbol, !customSymbol.isEmpty { return customSymbol }
        return defaultSymbol
    }

    /// The icon the item has without a custom one. The icon panel offers it first.
    var defaultSymbol: String {
        if isFolder { return "folder" }
        guard let action = actionID.flatMap(ActionCatalog.action) else { return "app.dashed" }
        if let symbol = action.choice(argument)?.symbol { return symbol }
        if action.parameter == .folder, let argument, let symbol = Self.folderSymbols[Self.standardized(argument)] { return symbol }
        return action.symbol
    }

    private static func standardized(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// Folders that Finder shows with an icon of their own.
    private static let folderSymbols: [String: String] = {
        let home = NSHomeDirectory() as NSString
        return [
            home.appendingPathComponent("Downloads"): "arrow.down.circle.fill",
            home.appendingPathComponent("Desktop"): "menubar.dock.rectangle",
            home.appendingPathComponent("Documents"): "doc.fill",
            home as String: "house.fill",
            home.appendingPathComponent(".Trash"): "trash",
            "/Applications": "square.grid.3x3.fill",
        ]
    }()

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
    // At the root, slot 0 sits at 12 o'clock and the rest follow clockwise. A folder's items
    // fan out from the top of its arc.

    /// The wheel on first launch. The four straight directions hold the actions used most,
    /// two of them where a trackpad gesture already points: up for Mission Control, left for
    /// back to the previous app. Each other bubble is the first of a kind: a picker, a folder
    /// of windows that preview where they go, a folder of toggles, and Customize Wheel, which
    /// teaches right-clicking and is meant to be removed.
    static let defaults: [WheelItem] = [
        .action("desktop.missionControl"),
        .action("media.controls"),
        .action("media.volume"),
        .folder("Controls", symbol: "switch.2", [
            .action("media.mute"),
            .action("system.micMute"),
            .action("media.output"),
            .action("system.doNotDisturb"),
            .action("system.appearance"),
            .action("system.keepAwake"),
        ]),
        .action("system.screenshot"),
        .action(WheelActions.customize),
        .action("desktop.switchApps"),
        .folder("Windows", symbol: "macwindow", [
            .action("window.move", argument: "leftHalf"),
            .action("window.move", argument: "rightHalf"),
            .action("window.move", argument: "maximize"),
            .action("window.move", argument: "center"),
            .action("desktop.minimize"),
            .action("desktop.fullScreen"),
        ]),
    ]
}
