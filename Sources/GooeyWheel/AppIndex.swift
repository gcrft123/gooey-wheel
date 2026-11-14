import AppKit

/// The apps installed on this Mac, for the app picker and for naming an item after its app.
final class AppIndex {
    struct App {
        let id: String
        let name: String
        let url: URL
    }

    static let shared = AppIndex()
    /// The scripted demo lists only the apps that come with macOS, so a recording doesn't
    /// show what is installed on this Mac.
    static var systemAppsOnly = false

    /// Sorted by name. Found once, when `shared` is first used, which is safe from any thread.
    let apps: [App]
    private let byID: [String: App]

    private init() {
        apps = Self.scan()
        byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func app(_ id: String) -> App? {
        if let app = byID[id] { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return App(id: id, name: Self.name(of: url), url: url)
    }

    private static func name(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func scan() -> [App] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.path
        var found: [String: App] = [:]
        func add(_ url: URL) {
            guard let id = Bundle(url: url)?.bundleIdentifier, found[id] == nil else { return }
            found[id] = App(id: id, name: name(of: url), url: url)
        }
        // Safari and a few others are kept apart from the rest of the system's apps.
        let system = ["/System/Applications", "/System/Cryptexes/App/System/Applications"]
        for folder in systemAppsOnly ? system : system + ["/Applications", home + "/Applications"] {
            let root = URL(fileURLWithPath: folder)
            guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            for entry in entries {
                if entry.pathExtension == "app" {
                    add(entry)
                } else if entry.hasDirectoryPath, let inner = try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    // One level down covers Utilities and suites that keep their apps in a folder.
                    for app in inner where app.pathExtension == "app" { add(app) }
                }
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension WheelItem {
    /// Names an item after what its action is set to: the app, file, website, or shortcut.
    static func argumentTitle(_ action: ActionDefinition, _ argument: String) -> String? {
        switch action.parameter {
        case .application:
            return AppIndex.shared.app(argument)?.name
        case .file, .folder:
            // The name Finder shows: the user's name for the home folder, "Trash" for ~/.Trash.
            let path = (argument as NSString).expandingTildeInPath
            if path == (NSHomeDirectory() as NSString).appendingPathComponent(".Trash") { return "Trash" }
            let name = FileManager.default.fileExists(atPath: path) ? FileManager.default.displayName(atPath: path) : (path as NSString).lastPathComponent
            return name.isEmpty ? nil : name
        case .url:
            return URL(string: argument)?.host
        case .shortcut:
            return argument
        default:
            return nil
        }
    }
}
