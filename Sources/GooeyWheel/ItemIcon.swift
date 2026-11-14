import AppKit
import UniformTypeIdentifiers

/// What an item's icon is drawn from. An item stores it in `customSymbol` as text: an SF
/// Symbol's name, `app:` and a bundle identifier, or `image:` and the path of a picture the
/// user added. Symbol names never contain a colon.
enum ItemIcon: Equatable {
    case symbol(String)
    /// An app's own icon, by bundle identifier.
    case app(String)
    /// A picture the user added, by path, which may start with `~`.
    case image(String)

    private static let appPrefix = "app:"
    private static let imagePrefix = "image:"

    init(_ name: String) {
        if name.hasPrefix(Self.appPrefix) {
            self = .app(String(name.dropFirst(Self.appPrefix.count)))
        } else if name.hasPrefix(Self.imagePrefix) {
            self = .image(String(name.dropFirst(Self.imagePrefix.count)))
        } else {
            self = .symbol(name)
        }
    }

    /// The text an item stores.
    var name: String {
        switch self {
        case .symbol(let name): return name
        case .app(let id): return Self.appPrefix + id
        case .image(let path): return Self.imagePrefix + path
        }
    }

    private static let pictures = NSCache<NSString, NSImage>()

    /// The picture for an app or image icon. Nil for a symbol, or when the app or file is gone.
    static func picture(_ name: String) -> NSImage? {
        if let cached = pictures.object(forKey: name as NSString) { return cached }
        let image: NSImage?
        switch ItemIcon(name) {
        case .symbol:
            return nil
        case .app(let id):
            image = AppIndex.shared.app(id).map { NSWorkspace.shared.icon(forFile: $0.url.path) }
        case .image(let path):
            image = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath)
        }
        if let image { pictures.setObject(image, forKey: name as NSString) }
        return image
    }
}

/// Pictures the user adds as icons. Each is copied into the folder beside the saved wheel,
/// so the original can be moved or deleted.
enum IconImages {
    /// The longest side of a saved picture, in pixels: enough for a bubble that swells, on a Retina screen.
    private static let side = 256

    /// Copies the picture at `url` into `folder`, laid out on the macOS icon grid like an
    /// app's icon so the two look the same size on the wheel. A picture with transparency
    /// keeps its shape; an opaque one, such as a photo, is cropped to a rounded square.
    /// Returns the icon to store, or nil when the file isn't a picture.
    static func add(_ url: URL, to folder: URL) -> ItemIcon? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        // An 824-point square in a 1024-point canvas, as Apple's icon template has it.
        let box = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: CGFloat(side) * 100 / 1024, dy: CGFloat(side) * 100 / 1024)
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if opaque {
            let corner = box.width * 186 / 824
            context.addPath(CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.clip()
            let fill = max(box.width / w, box.height / h)
            context.draw(image, in: CGRect(x: box.midX - w * fill / 2, y: box.midY - h * fill / 2, width: w * fill, height: h * fill))
        } else {
            let fit = min(box.width / w, box.height / h)
            context.draw(image, in: CGRect(x: box.midX - w * fit / 2, y: box.midY - h * fit / 2, width: w * fit, height: h * fit))
        }
        guard let made = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: made).representation(using: .png, properties: [:])
        else { return nil }
        let file = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("Couldn't save the icon picture: \(error)")
            return nil
        }
        return .image((file.path as NSString).abbreviatingWithTildeInPath)
    }

    /// Deletes the pictures in `folder` that no item uses any more, such as one that was replaced.
    static func prune(_ folder: URL, keeping items: [WheelItem]) {
        var used = Set<String>()
        func visit(_ item: WheelItem) {
            if let name = item.customSymbol, case .image(let path) = ItemIcon(name) {
                used.insert(((path as NSString).expandingTildeInPath as NSString).standardizingPath)
            }
            item.children?.forEach(visit)
        }
        items.forEach(visit)
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        for file in files where file.pathExtension == "png" && !used.contains((file.path as NSString).standardizingPath) {
            try? manager.removeItem(at: file)
        }
    }

    static let contentTypes: [UTType] = [.image]
}
