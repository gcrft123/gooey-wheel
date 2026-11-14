import AppKit

/// One line in a list: an entry to pick, or a section that opens and closes.
struct ListRow {
    enum Kind: Equatable {
        case entry
        case section(open: Bool)
    }

    let id: String
    let title: String
    var kind = Kind.entry
    /// An SF Symbol, or an image made when the row first shows, such as an app's icon.
    var symbol: String?
    var image: (() -> NSImage?)?
    var indent: CGFloat = 0
}

/// A scrolling list that moves the way the wheel does. Rows slide on springs when a section
/// opens or closes. One highlight follows the pointer or the arrow keys, and one marks the
/// chosen entry; each glides from row to row instead of switching on and off.
final class EditorList: NSView, EditorAnimated {
    var chosen: String? {
        didSet { canvas.needsDisplay = true }
    }
    var onChoose: ((String) -> Void)?
    var onToggle: ((String) -> Void)?

    /// How far above this list's bottom edge the panel's corner buttons begin. Rows run on
    /// past that line toward the panel's edge, fading, and the last row can scroll to rest
    /// above it.
    var clearance: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    private final class Item {
        var row: ListRow
        var y: Spring
        var alpha: Spring
        /// 0 with the section closed, 1 open: how far its chevron has turned.
        var turn: Spring
        var leaving = false
        /// Where the row set out from, when it is on its way in or out from under the row
        /// above. It shows by how far it has come, so rows don't pile up in view at the start.
        var origin: Double?

        var shown: Double {
            guard let origin, abs(y.target - origin) > 1 else { return clamp01(alpha.value) }
            let along = clamp01((y.value - origin) / (y.target - origin))
            return clamp01(alpha.value) * smooth01((leaving ? 1 - along : along) * 1.25 - 0.2)
        }

        init(_ row: ListRow, y: Double, alpha: Double) {
            self.row = row
            let reduced = EditorTheme.reducedMotion
            self.y = Spring(y, reduced ? .critical(k: 600) : SpringConfig(k: 340, c: 28))
            self.alpha = Spring(alpha, .critical(k: 520))
            turn = Spring(0, reduced ? .critical(k: 600) : SpringConfig(k: 420, c: 26))
            if case .section(let open) = row.kind { turn.snap(open ? 1 : 0) }
        }
    }

    private let theme: EditorTheme
    private let scroll = NSScrollView()
    private let canvas = Canvas()
    private var items: [Item] = []
    private var hover = GlidingRect()
    private var selection = GlidingRect()
    /// The row the arrow keys are on. The pointer takes over when it moves.
    private var keyRow: String?
    private var pointerRow: String?
    private var lastPointer: CGPoint?
    private var images: [String: NSImage] = [:]
    private var pendingReveal: String?
    private var documentHeight: CGFloat = 0
    /// The scroll position on its way somewhere, when the list scrolls itself.
    private var glide: Spring?

    private var rowHeight: CGFloat { EditorTheme.rowHeight }
    private var bottomInset: CGFloat { clearance }

    init(theme: EditorTheme) {
        self.theme = theme
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = canvas
        canvas.list = self
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Rows

    /// The rows in order. Setting them slides the rows that stay to their new places, lets
    /// new ones out from under the row above them, and tucks removed ones back under it.
    var rows: [ListRow] {
        get { items.filter { !$0.leaving }.map(\.row) }
        set { apply(newValue) }
    }

    private func apply(_ rows: [ListRow]) {
        let animated = window != nil && bounds.height > 0
        var existing: [String: Item] = [:]
        for item in items where !item.leaving { existing[item.row.id] = item }
        var kept: [Item] = []
        // New rows come out from under the nearest row above that was already there.
        var anchor: Item?
        for (index, row) in rows.enumerated() {
            let target = Double(CGFloat(index) * rowHeight)
            if let item = existing.removeValue(forKey: row.id) {
                item.row = row
                item.y.target = target
                item.alpha.target = 1
                if case .section(let open) = row.kind { item.turn.target = open ? 1 : 0 }
                if !animated {
                    item.y.snap(target)
                    item.turn.snap(item.turn.target)
                }
                kept.append(item)
                anchor = item
            } else {
                let item = Item(row, y: animated ? (anchor?.y.value ?? target) : target, alpha: animated ? 0 : 1)
                item.y.target = target
                item.alpha.target = 1
                if animated, anchor != nil { item.origin = item.y.value }
                kept.append(item)
            }
        }
        // Rows that are gone slide back under the row they came out from, fading.
        var leaving = items.filter(\.leaving)
        if animated {
            let order = items.filter { !$0.leaving }
            for (index, item) in order.enumerated() where existing[item.row.id] != nil {
                let above = order[..<index].last { old in kept.contains { $0 === old } }
                item.leaving = true
                item.origin = item.y.value
                item.y.target = above?.y.target ?? item.y.target
                item.alpha.target = 0
                leaving.append(item)
            }
        }
        items = leaving + kept
        if !rows.contains(where: { $0.id == keyRow }) { keyRow = nil }
        resizeDocument()
        canvas.needsDisplay = true
    }

    private var live: [Item] { items.filter { !$0.leaving } }

    private func item(_ id: String?) -> Item? {
        guard let id else { return nil }
        return items.first { !$0.leaving && $0.row.id == id }
    }

    private func frame(of item: Item) -> CGRect {
        CGRect(x: 4, y: CGFloat(item.y.value) + 2, width: canvas.bounds.width - 8, height: rowHeight - 4)
    }

    private func restFrame(of item: Item) -> CGRect {
        CGRect(x: 4, y: CGFloat(item.y.target) + 2, width: canvas.bounds.width - 8, height: rowHeight - 4)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scroll.frame = bounds
        scroll.fadeEdges()
        resizeDocument()
        // A row asked for before the list had a size is shown now that it has one.
        if let pending = pendingReveal, bounds.height > 0 {
            pendingReveal = nil
            reveal(pending)
        }
    }

    /// The document is as tall as its lowest row, which moves while a section opens or closes.
    private func resizeDocument() {
        // Tall enough for the rows where they are now and where they are headed, so the list
        // can already scroll to a section that is still opening.
        let lowest = items.map { CGFloat($0.y.value) }.max().map { $0 + rowHeight } ?? 0
        let height = max(max(lowest, CGFloat(live.count) * rowHeight) + bottomInset, bounds.height)
        guard abs(height - documentHeight) > 0.5 || canvas.frame.width != bounds.width else { return }
        documentHeight = height
        canvas.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
    }

    func reveal(_ id: String?) {
        guard bounds.height > 0 else {
            pendingReveal = id
            return
        }
        guard let item = item(id) else { return }
        let visible = scroll.contentView.bounds
        let row = CGRect(x: 0, y: CGFloat(item.y.target), width: 1, height: rowHeight)
        // A row already in clear view stays put. Otherwise it is brought to the middle, away
        // from the panel's buttons in the bottom corners.
        guard row.minY < visible.minY + rowHeight || row.maxY > visible.maxY - bottomInset - rowHeight else { return }
        let rest = CGFloat(live.count) * rowHeight + bottomInset
        let top = min(max(row.midY - visible.height / 2, 0), max(rest - visible.height, 0))
        canvas.scroll(CGPoint(x: 0, y: top))
    }

    /// Scrolls, on a spring, so that an opened section's rows are in clear view: as little as
    /// it takes when they fit, and the section's heading to the top when they don't.
    func revealSection(_ id: String) {
        let rows = live
        guard bounds.height > 0, let start = rows.firstIndex(where: { $0.row.id == id }) else { return }
        let end = rows[(start + 1)...].firstIndex { $0.row.kind != .entry } ?? rows.count
        let visible = scroll.contentView.bounds
        let top = CGFloat(start) * rowHeight
        let bottom = CGFloat(end) * rowHeight
        let room = visible.height - bottomInset
        var target = visible.minY
        if bottom > target + room { target = min(top, bottom - room) }
        if top < target { target = top }
        let limit = max(CGFloat(rows.count) * rowHeight + bottomInset - visible.height, 0)
        target = min(max(target, 0), limit)
        guard abs(target - visible.minY) > 0.5 else { return }
        var spring = Spring(Double(visible.minY), EditorTheme.reducedMotion ? .critical(k: 600) : SpringConfig(k: 300, c: 30))
        spring.target = Double(target)
        glide = spring
    }

    // MARK: Choosing

    private func activate(_ item: Item) {
        switch item.row.kind {
        case .entry:
            chosen = item.row.id
            onChoose?(item.row.id)
        case .section:
            keyRow = item.row.id
            onToggle?(item.row.id)
        }
    }

    /// Moves the highlight a row up or down. Entries are chosen as it lands on them.
    func move(_ delta: Int) {
        let rows = live
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.row.id == (keyRow ?? chosen) }
        let next = rows[min(max((current ?? (delta > 0 ? -1 : rows.count)) + delta, 0), rows.count - 1)]
        keyRow = next.row.id
        if next.row.kind == .entry { activate(next) }
        reveal(next.row.id)
        canvas.needsDisplay = true
    }

    /// Return on a section opens or closes it. Returns false when the highlight is on an entry.
    func toggleHighlightedSection() -> Bool {
        guard let item = item(keyRow), item.row.kind != .entry else { return false }
        onToggle?(item.row.id)
        return true
    }

    fileprivate func click(at point: CGPoint) {
        guard let item = row(at: point) else { return }
        activate(item)
    }

    private func row(at point: CGPoint) -> Item? {
        live.first { point.y >= CGFloat($0.y.value) && point.y < CGFloat($0.y.value) + rowHeight }
    }

    /// The middle of a row, in the window's coordinates, for the demo's cursor.
    func demoPoint(_ id: String) -> CGPoint? {
        guard let item = item(id) else { return nil }
        let frame = restFrame(of: item)
        // Only a row that is in view can be pointed at.
        let visible = scroll.contentView.bounds
        guard frame.minY >= visible.minY, frame.maxY <= visible.maxY - clearance else { return nil }
        return canvas.convert(CGPoint(x: frame.minX + min(frame.width * 0.45, 120), y: frame.midY), to: nil)
    }

    // MARK: Motion

    func tick(_ dt: Double, pointer: CGPoint?) {
        if var spring = glide {
            // Scrolling by hand in the meantime takes over.
            if abs(Double(scroll.contentView.bounds.minY) - spring.value) > 2 {
                glide = nil
            } else {
                spring.step(dt)
                let done = abs(spring.value - spring.target) < 0.3 && abs(spring.velocity) < 2
                canvas.scroll(CGPoint(x: 0, y: done ? spring.target : spring.value))
                glide = done ? nil : spring
            }
        }
        scroll.fadeEdges()
        var moving = glide != nil
        for item in items {
            item.y.step(dt)
            item.alpha.step(dt)
            item.turn.step(dt)
            if abs(item.y.value - item.y.target) > 0.05 || abs(item.alpha.value - item.alpha.target) > 0.01 || abs(item.turn.value - item.turn.target) > 0.01 {
                moving = true
            }
        }
        let before = items.count
        items.removeAll { $0.leaving && $0.alpha.value < 0.02 }
        if items.count != before || moving { resizeDocument() }

        // The pointer counts only where rows are in clear view: inside the list, above the fade.
        var under: Item?
        if let pointer {
            let local = canvas.convert(pointer, from: nil)
            let visible = scroll.contentView.bounds
            if local.x >= 0, local.x <= canvas.bounds.width, local.y >= visible.minY, local.y <= visible.maxY - NSScrollView.fadeStart {
                under = row(at: local)
            }
            if lastPointer.map({ hypot($0.x - pointer.x, $0.y - pointer.y) > 0.5 }) ?? true, under != nil { keyRow = nil }
        }
        lastPointer = pointer
        pointerRow = under?.row.id

        // One highlight, for whichever the pointer or the keys are on. On the chosen entry
        // the selection already says it.
        if let lit = item(pointerRow ?? keyRow), !(lit.row.kind == .entry && lit.row.id == chosen) {
            hover.show(at: restFrame(of: lit))
        } else {
            hover.hide()
        }
        if let picked = item(chosen), picked.row.kind == .entry {
            selection.show(at: restFrame(of: picked))
        } else {
            selection.hide()
        }
        hover.step(dt)
        selection.step(dt)
        if moving || hover.isMoving || selection.isMoving { canvas.needsDisplay = true }
    }

    // MARK: Drawing

    private func image(for row: ListRow, onAccent: Bool) -> NSImage? {
        let key = row.id + (row.symbol == nil ? "" : (onAccent ? "*" : "."))
        if let cached = images[key] { return cached }
        var made: NSImage?
        if let symbol = row.symbol {
            let color = onAccent ? theme.onAccent : (row.kind == .entry ? theme.text : theme.secondary)
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium).applying(.init(hierarchicalColor: color))
            made = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        } else {
            made = row.image?()
        }
        images[key] = made
        return made
    }

    private lazy var chevron: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold).applying(.init(hierarchicalColor: theme.secondary))
        return NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }()

    private func pill(_ rect: CGRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    }

    fileprivate func drawRows(in dirty: CGRect) {
        if hover.isVisible {
            theme.well.withAlphaComponent(theme.well.alphaComponent * CGFloat(clamp01(hover.alpha.value))).setFill()
            pill(hover.rect).fill()
        }
        let selected = selection.rect
        if selection.isVisible {
            theme.accent.withAlphaComponent(CGFloat(clamp01(selection.alpha.value))).setFill()
            pill(selected).fill()
        }
        for item in items {
            let frame = frame(of: item)
            guard frame.intersects(dirty.insetBy(dx: 0, dy: -rowHeight)) else { continue }
            let alpha = CGFloat(item.shown)
            guard alpha > 0.01 else { continue }
            // A row takes the accent's contrasting color by as much as the selection covers it.
            let cover = selection.isVisible ? clamp01(Double(frame.intersection(selected).height / frame.height) * selection.alpha.value) : 0
            let base = item.row.kind == .entry ? theme.text : theme.secondary
            let color = (base.blended(withFraction: CGFloat(cover), of: theme.onAccent) ?? base).withAlphaComponent(base.alphaComponent * alpha)

            var x = frame.minX + 12 + item.row.indent
            let side: CGFloat = 22
            for (onAccent, weight) in [(false, 1 - cover), (true, cover)] where weight > 0.01 {
                guard let image = image(for: item.row, onAccent: onAccent) else { continue }
                let size = item.row.symbol == nil ? CGSize(width: side, height: side) : image.size
                image.draw(in: CGRect(x: x + (side - size.width) / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: alpha * CGFloat(item.row.symbol == nil ? 1 : weight), respectFlipped: true, hints: nil)
                if item.row.symbol == nil { break }
            }
            x += side + 10

            var trailing: CGFloat = 12
            if item.row.kind != .entry, let chevron {
                // The chevron turns a quarter of the way round as its section opens.
                let center = CGPoint(x: frame.maxX - 18, y: frame.midY)
                NSGraphicsContext.saveGraphicsState()
                let turn = NSAffineTransform()
                turn.translateX(by: center.x, yBy: center.y)
                turn.rotate(byRadians: CGFloat(item.turn.value) * .pi / 2)
                turn.concat()
                chevron.draw(in: CGRect(x: -chevron.size.width / 2, y: -chevron.size.height / 2, width: chevron.size.width, height: chevron.size.height),
                             from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                trailing = 34
            }
            let title = NSAttributedString(string: item.row.title, attributes: [
                .font: item.row.kind == .entry ? EditorTheme.font : EditorTheme.strong, .foregroundColor: color,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p }(),
            ])
            let height = ceil(title.size().height)
            title.draw(in: CGRect(x: x, y: frame.midY - height / 2, width: frame.maxX - trailing - x, height: height))
        }
    }

    /// The scrolling document. It draws the list and passes clicks to it.
    private final class Canvas: NSView {
        weak var list: EditorList?

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            list?.drawRows(in: dirtyRect)
        }

        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            list?.click(at: convert(event.locationInWindow, from: nil))
        }
    }
}

/// A search field over a list. The field keeps the keyboard: typing filters, the arrow
/// keys move through the list, and Return is passed on.
final class SearchList: NSView {
    let field: WellField
    let list: EditorList
    var onSearch: ((String) -> Void)?
    var onReturn: (() -> Void)?

    init(theme: EditorTheme, placeholder: String) {
        field = WellField(theme: theme, placeholder: placeholder, symbol: "magnifyingglass")
        list = EditorList(theme: theme)
        super.init(frame: .zero)
        field.onChange = { [weak self] in self?.onSearch?($0) }
        field.onMove = { [weak self] in self?.list.move($0) }
        field.onReturn = { [weak self] in
            guard let self else { return }
            if !self.list.toggleHighlightedSection() { self.onReturn?() }
        }
        addSubview(field)
        addSubview(list)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        field.frame = CGRect(x: 0, y: 0, width: bounds.width, height: EditorTheme.fieldHeight)
        list.frame = CGRect(x: 0, y: EditorTheme.fieldHeight + 10, width: bounds.width, height: bounds.height - EditorTheme.fieldHeight - 10)
    }
}
