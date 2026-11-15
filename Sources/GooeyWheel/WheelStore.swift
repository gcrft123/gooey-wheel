import Foundation

/// The wheel's items, saved as JSON after every change. Each change can be undone until
/// `beginSession` is called again.
final class WheelStore {
    private(set) var root: [WheelItem]
    /// Colors the user has given items, most recent first, offered again in the color panel.
    private(set) var savedColors: [ItemColor] = []
    private let url: URL?
    private var undoStack: [[WheelItem]] = []
    private var redoStack: [[WheelItem]] = []

    private static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gooey Wheel", isDirectory: true)
    }

    /// The saved wheel, or the default one on first launch.
    static func saved(at path: String? = nil) -> WheelStore {
        if let path { return WheelStore(url: URL(fileURLWithPath: path)) }
        return WheelStore(url: supportFolder.appendingPathComponent("wheel.json"))
    }

    /// The default wheel, never written to disk. Used by the scripted demo.
    static func temporary(rootCount: Int? = nil) -> WheelStore {
        let store = WheelStore(url: nil)
        if let rootCount { store.root = Array(store.root.prefix(rootCount)) }
        return store
    }

    private init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            root = file.items.map(ActionMigration.migrate)
            savedColors = file.savedColors ?? []
            if root != file.items { save() }
        } else {
            root = WheelItem.defaults
            save()
        }
        if let iconFolder { IconImages.prune(iconFolder, keeping: root) }
    }

    /// Where pictures added as icons are kept, beside the saved wheel. Nil for a wheel that isn't saved.
    var iconFolder: URL? {
        url?.deletingLastPathComponent().appendingPathComponent("Icons", isDirectory: true)
    }

    private struct File: Codable {
        var version = 1
        var items: [WheelItem]
        var savedColors: [ItemColor]?
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(items: root, savedColors: savedColors.isEmpty ? nil : savedColors)).write(to: url, options: .atomic)
        } catch {
            NSLog("Couldn't save the wheel: \(error)")
        }
    }

    // MARK: Reading

    func items(in container: Container) -> [WheelItem]? {
        switch container {
        case .root: return root
        case .folder(let id): return root.first { $0.id == id }?.children
        }
    }

    func item(_ id: UUID) -> WheelItem? {
        for item in root {
            if item.id == id { return item }
            if let child = item.children?.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    func location(of id: UUID) -> (container: Container, index: Int)? {
        for (i, item) in root.enumerated() {
            if item.id == id { return (.root, i) }
            if let j = item.children?.firstIndex(where: { $0.id == id }) { return (.folder(item.id), j) }
        }
        return nil
    }

    func hasRoom(in container: Container) -> Bool {
        guard let items = items(in: container) else { return false }
        return items.count < WheelLimits.capacity(of: container)
    }

    // MARK: Changing

    func beginSession() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(root)
        root = previous
        save()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(root)
        root = next
        save()
        return true
    }

    static let savedColorLimit = 6

    /// Keeps a color for the color panel's presets. Not part of undo.
    func remember(_ color: ItemColor) {
        savedColors.removeAll { $0.hex == color.hex }
        savedColors.insert(color, at: 0)
        savedColors = Array(savedColors.prefix(Self.savedColorLimit))
        save()
    }

    /// Drops an item that was just added, as if it never had been: no undo step is left
    /// for it. If something else changed since, it is removed like any other item.
    func discardInsert(_ id: UUID) {
        var without = root
        _ = Self.take(id, from: &without)
        guard let previous = undoStack.last, previous == without else {
            remove(id)
            return
        }
        undoStack.removeLast()
        root = previous
        save()
    }

    /// Applies one undoable change. Folders left empty by it are removed. `joined` makes it
    /// part of the change before it, so one undo takes back both.
    private func change(joined: Bool = false, _ body: (inout [WheelItem]) -> Void) {
        var next = root
        body(&next)
        next.removeAll { $0.children?.isEmpty == true }
        guard next != root else { return }
        if !joined || undoStack.isEmpty { undoStack.append(root) }
        redoStack.removeAll()
        root = next
        save()
    }

    private static func take(_ id: UUID, from items: inout [WheelItem]) -> WheelItem? {
        if let i = items.firstIndex(where: { $0.id == id }) { return items.remove(at: i) }
        for i in items.indices {
            if let j = items[i].children?.firstIndex(where: { $0.id == id }) {
                return items[i].children?.remove(at: j)
            }
        }
        return nil
    }

    private static func put(_ item: WheelItem, in container: Container, at index: Int, of items: inout [WheelItem]) {
        switch container {
        case .root:
            items.insert(item, at: min(max(index, 0), items.count))
        case .folder(let id):
            guard let i = items.firstIndex(where: { $0.id == id }), var children = items[i].children else { return }
            children.insert(item, at: min(max(index, 0), children.count))
            items[i].children = children
        }
    }

    func insert(_ item: WheelItem, in container: Container, at index: Int) {
        change { Self.put(item, in: container, at: index, of: &$0) }
    }

    func remove(_ id: UUID) {
        change { _ = Self.take(id, from: &$0) }
    }

    /// Moves an item into a ring and arranges that ring in `order`, which lists every item
    /// the ring then holds.
    func place(_ id: UUID, in container: Container, order: [UUID]) {
        change { items in
            guard let item = Self.take(id, from: &items) else { return }
            Self.put(item, in: container, at: .max, of: &items)
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            func arranged(_ ring: [WheelItem]) -> [WheelItem] {
                ring.enumerated().sorted {
                    (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset)
                }.map(\.element)
            }
            switch container {
            case .root:
                items = arranged(items)
            case .folder(let folder):
                guard let i = items.firstIndex(where: { $0.id == folder }) else { return }
                items[i].children = items[i].children.map(arranged)
            }
        }
    }

    /// Puts both items in a new folder where `target` was. The folder takes `folderID`.
    func makeFolder(_ folderID: UUID, from target: UUID, adding id: UUID) {
        change { items in
            guard let at = items.firstIndex(where: { $0.id == target }), !items[at].isFolder,
                  let added = Self.take(id, from: &items),
                  let index = items.firstIndex(where: { $0.id == target }) else { return }
            var folder = WheelItem(id: folderID, children: [items[index], added])
            folder.color = items[index].color
            items[index] = folder
        }
    }

    func update(_ id: UUID, joined: Bool = false, _ edit: (inout WheelItem) -> Void) {
        change(joined: joined) { items in
            for i in items.indices {
                if items[i].id == id {
                    edit(&items[i])
                } else if let j = items[i].children?.firstIndex(where: { $0.id == id }) {
                    edit(&items[i].children![j])
                }
            }
        }
    }
}
