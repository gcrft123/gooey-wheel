import AppKit

/// A search field over a grid of every SF Symbol. The item's own default icon comes first,
/// so there is always a way back to it.
final class IconEditor: EditorContent {
    private let field: WellField
    private let scroll = NSScrollView()
    private let grid: SymbolGrid
    private let defaultSymbol: String

    override init(context: EditorContext) {
        let theme = EditorTheme(context.style)
        var plain = context.item
        plain.customSymbol = nil
        defaultSymbol = plain.symbol
        field = WellField(theme: theme, placeholder: "Search", symbol: "magnifyingglass")
        grid = SymbolGrid(theme: theme)
        super.init(context: context)

        let pad = EditorTheme.padding
        field.frame = CGRect(x: pad, y: pad, width: bounds.width - 2 * pad, height: EditorTheme.fieldHeight)
        field.onChange = { [weak self] in self?.search($0) }
        field.onMove = { [weak self] in self?.grid.move(rows: $0) }
        field.onReturn = { [weak self] in self?.onSubmit?() }
        addSubview(field)

        scroll.frame = CGRect(x: pad - 4, y: field.frame.maxY + 10, width: bounds.width - 2 * (pad - 4), height: bounds.height - field.frame.maxY - 10)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = grid
        addSubview(scroll)
        // The grid runs down beside the back and save buttons and fades out above the panel's edge.
        scroll.fadeEdges()

        grid.width = scroll.frame.width
        grid.defaultSymbol = defaultSymbol
        grid.chosen = context.item.symbol
        grid.onChoose = { [weak self] name in
            guard let self else { return }
            self.draft.customSymbol = name == self.defaultSymbol ? nil : name
        }
        search("")
        grid.reveal(grid.chosen)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // With nothing typed, the default leads and isn't repeated further down.
        grid.names = trimmed.isEmpty
            ? [defaultSymbol] + SymbolCatalog.all.filter { $0 != defaultSymbol }
            : SymbolCatalog.search(trimmed)
        grid.scroll(.zero)
    }

    override func focus() {
        field.focus()
    }

    override func demoPoint(_ name: String) -> CGPoint? {
        if name == "search" { return field.demoPoint }
        guard name.hasPrefix("cell:"), let index = Int(name.dropFirst(5)) else { return nil }
        return grid.demoPoint(index)
    }

    override func demo(_ step: Int) {
        if step == 0 {
            field.text = "star"
            search("star")
        } else {
            grid.choose(index: 9)
        }
    }
}

/// Draws only the symbols in view, and makes each image the first time it shows. One
/// highlight follows the pointer and one marks the chosen symbol; both glide between cells.
private final class SymbolGrid: NSView, EditorAnimated {
    static let cell: CGFloat = 52
    /// Space under the last row, so it can scroll to rest above the panel's buttons.
    static let bottomInset: CGFloat = EditorTheme.cutout

    var names: [String] = [] {
        didSet {
            resize()
            // A new set of symbols is a new page: the highlights don't glide across from the old one.
            hover = GlidingRect()
            selection = GlidingRect()
        }
    }
    var width: CGFloat = 0 {
        didSet { resize() }
    }
    var defaultSymbol = ""
    var chosen: String? {
        didSet { needsDisplay = true }
    }
    var onChoose: ((String) -> Void)?

    private let theme: EditorTheme
    private let images = NSCache<NSString, NSImage>()
    private var hover = GlidingRect()
    private var selection = GlidingRect()

    init(theme: EditorTheme) {
        self.theme = theme
        super.init(frame: .zero)
        images.countLimit = 1200
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var columns: Int { max(Int(width / Self.cell), 1) }
    private var margin: CGFloat { (width - CGFloat(columns) * Self.cell) / 2 }

    private func resize() {
        let rows = (names.count + columns - 1) / columns
        frame = CGRect(x: 0, y: 0, width: width, height: CGFloat(rows) * Self.cell + Self.bottomInset)
        needsDisplay = true
    }

    private func rect(_ index: Int) -> CGRect {
        CGRect(x: margin + CGFloat(index % columns) * Self.cell, y: CGFloat(index / columns) * Self.cell, width: Self.cell, height: Self.cell)
    }

    private func tile(_ index: Int) -> CGRect {
        rect(index).insetBy(dx: 3, dy: 3)
    }

    private func index(at p: CGPoint) -> Int? {
        let column = Int((p.x - margin) / Self.cell)
        guard p.x >= margin, column < columns, p.y >= 0 else { return nil }
        let i = Int(p.y / Self.cell) * columns + column
        return i < names.count ? i : nil
    }

    func demoPoint(_ index: Int) -> CGPoint? {
        names.indices.contains(index) ? convert(CGPoint(x: rect(index).midX, y: rect(index).midY), to: nil) : nil
    }

    func choose(index: Int) {
        guard names.indices.contains(index) else { return }
        chosen = names[index]
        onChoose?(names[index])
        scrollToVisible(clear(rect(index)))
    }

    /// A cell's frame with room around it, so scrolling it into view leaves it above the
    /// panel's buttons, not beside them.
    private func clear(_ cell: CGRect) -> CGRect {
        CGRect(x: cell.minX, y: cell.minY - 8, width: cell.width, height: cell.height + 8 + Self.bottomInset)
    }

    func reveal(_ name: String?) {
        guard let name, let i = names.firstIndex(of: name) else { return }
        scrollToVisible(clear(rect(i)))
    }

    /// The arrow keys move the choice a row at a time. With nothing chosen, down starts at the top.
    func move(rows delta: Int) {
        guard let current = chosen.flatMap(names.firstIndex(of:)) else {
            choose(index: 0)
            return
        }
        choose(index: min(max(current + delta * columns, 0), names.count - 1))
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { choose(index: i) }
    }

    func tick(_ dt: Double, pointer: CGPoint?) {
        enclosingScrollView?.fadeEdges()
        var under: Int?
        if let pointer, let visible = enclosingScrollView?.contentView.bounds {
            let local = convert(pointer, from: nil)
            // Only where cells are in clear view, above the fade.
            if local.y >= visible.minY, local.y <= visible.maxY - NSScrollView.fadeStart { under = index(at: local) }
        }
        if let under, names[under] != chosen {
            hover.show(at: tile(under))
        } else {
            hover.hide()
        }
        if let picked = chosen.flatMap(names.firstIndex(of:)) {
            selection.show(at: tile(picked))
        } else {
            selection.hide()
        }
        hover.step(dt)
        selection.step(dt)
        if hover.isMoving || selection.isMoving { needsDisplay = true }
    }

    private func image(_ name: String, chosen: Bool) -> NSImage? {
        let key = (name + (chosen ? "*" : "")) as NSString
        if let cached = images.object(forKey: key) { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            .applying(.init(hierarchicalColor: chosen ? theme.onAccent : theme.text))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    private func rounded(_ rect: CGRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !names.isEmpty else { return }
        if hover.isVisible {
            theme.well.withAlphaComponent(theme.well.alphaComponent * CGFloat(clamp01(hover.alpha.value))).setFill()
            rounded(hover.rect).fill()
        }
        let selected = selection.rect
        if selection.isVisible {
            theme.accent.withAlphaComponent(CGFloat(clamp01(selection.alpha.value))).setFill()
            rounded(selected).fill()
        }
        let firstRow = max(Int(dirtyRect.minY / Self.cell), 0)
        let lastRow = Int(dirtyRect.maxY / Self.cell)
        let first = firstRow * columns
        let last = min((lastRow + 1) * columns, names.count) - 1
        guard first <= last else { return }
        for i in first...last {
            let name = names[i]
            let cell = rect(i)
            guard cell.intersects(dirtyRect) else { continue }
            let tile = tile(i)
            if name == defaultSymbol {
                // The default wears a ring, so it can be found again after choosing another.
                theme.hairline.setStroke()
                let ring = rounded(tile.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            // A glyph takes the accent's contrasting color by as much as the selection covers its cell.
            let overlap = tile.intersection(selected)
            let cover = selection.isVisible ? clamp01(Double(overlap.width * overlap.height / (tile.width * tile.height)) * selection.alpha.value) : 0
            for (onAccent, weight) in [(false, 1 - cover), (true, cover)] where weight > 0.01 {
                guard let image = image(name, chosen: onAccent) else { continue }
                // Wide symbols are scaled down to fit their cell.
                let fit = min(1, (Self.cell - 16) / max(image.size.width, image.size.height))
                let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
                image.draw(in: CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: CGFloat(weight), respectFlipped: true, hints: nil)
            }
        }
    }
}
