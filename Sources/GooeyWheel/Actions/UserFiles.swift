import Foundation

/// The user's home folder, and paths written with `~` for it. In the App Sandbox,
/// `NSHomeDirectory()` and `expandingTildeInPath` name the app's container instead, so paths
/// the user chose or sees are expanded here. Pictures the app keeps in its own Icons folder
/// still use `expandingTildeInPath`, since they live in the container.
enum UserHome {
    static let path: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()

    /// `~` and `~/…` become paths in the home folder. Anything else is left as it is.
    static func expand(_ path: String) -> String {
        if path == "~" { return Self.path }
        if path.hasPrefix("~/") { return (Self.path as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return path
    }

    /// A path in the home folder written with `~`, as the path field shows it.
    static func abbreviate(_ path: String) -> String {
        if path == Self.path { return "~" }
        if path.hasPrefix(Self.path + "/") { return "~" + path.dropFirst(Self.path.count) }
        return path
    }
}

/// What an Open File or Open Folder item stores: the path, then in the App Store edition a line
/// with a security-scoped bookmark in base64, which lets the sandboxed app reach the item again
/// after the user chose it. An argument without the second line is a path alone.
struct ItemLocation: Equatable {
    var path: String
    var bookmark: Data?

    init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
    }

    init?(argument: String?) {
        let lines = (argument ?? "").split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let path = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !path.isEmpty else { return nil }
        self.path = path
        bookmark = lines.count > 1 ? Data(base64Encoded: String(lines[1]).trimmingCharacters(in: .whitespaces)) : nil
    }

    var argument: String {
        bookmark.map { path + "\n" + $0.base64EncodedString() } ?? path
    }

    /// The path as a file URL, with `~` expanded.
    var url: URL { URL(fileURLWithPath: UserHome.expand(path)) }

    /// The path alone, for showing and comparing.
    static func path(of argument: String?) -> String? {
        ItemLocation(argument: argument)?.path
    }

    #if APPSTORE
    /// A location for a file or folder the user chose or dropped, which the app may reach now.
    init(chosen url: URL) {
        path = UserHome.abbreviate(url.path)
        bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The item's URL with access to it started, granted by its bookmark. The caller calls
    /// `stopAccessingSecurityScopedResource()` once done. Nil when there is no bookmark or it
    /// no longer resolves.
    func startAccess() -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }
    #endif
}
