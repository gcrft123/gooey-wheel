import AppKit

/// A search field over a grid of every SF Symbol, or over the installed apps to use one's
/// icon. The item's own default icon comes first among the symbols, so there is always a
/// way back to it. Two round buttons beside the field switch between symbols and apps, and
/// add a picture from a file.
final class IconEditor: EditorContent, EditorAnimated {
    private enum Source {
        case symbols, apps
    }

    private let field: WellField
    private let sourceButton: CircleButton
    private let pictureButton: CircleButton
    private let scroll = NSScrollView()
    private let grid: SymbolGrid
    private let appList: EditorList
    private let defaultSymbol: String
    private var source = Source.symbols
    /// 0 showing the symbols, 1 the apps.
    private var shown = Spring(0, SpringConfig.critical(k: 520))
    private var apps: [AppIndex.App] = []

    override init(context: EditorContext) {
        let theme = EditorTheme(context.style)
        var plain = context.item
        plain.customSymbol = nil
        defaultSymbol = plain.symbol
        field = WellField(theme: theme, placeholder: "Search", symbol: "magnifyingglass")
        sourceButton = CircleButton(theme: theme, symbol: "square.grid.2x2", label: "Apps")
        pictureButton = CircleButton(theme: theme, symbol: "photo.badge.plus", label: "Add Picture")
        grid = SymbolGrid(theme: theme)
        appList = EditorList(theme: theme)
        super.init(context: context)

        let pad = EditorTheme.padding
        let side = EditorTheme.fieldHeight
        let gap: CGFloat = 8
        let buttons = 2 * (side + gap)
        field.frame = CGRect(x: pad, y: pad, width: bounds.width - 2 * pad - buttons, height: side)
        field.onChange = { [weak self] in self?.search($0) }
        field.onMove = { [weak self] delta in
            guard let self else { return }
            switch self.source {
            case .symbols: self.grid.move(rows: delta)
            case .apps: self.appList.move(delta)
            }
        }
        field.onReturn = { [weak self] in self?.onSubmit?() }
        addSubview(field)

        sourceButton.frame = CGRect(x: field.frame.maxX + gap, y: pad, width: side, height: side)
        sourceButton.onPress = { [weak self] in self?.toggleSource() }
        addSubview(sourceButton)
        pictureButton.frame = CGRect(x: sourceButton.frame.maxX + gap, y: pad, width: side, height: side)
        pictureButton.onPress = { [weak self] in self?.choosePicture() }
        addSubview(pictureButton)

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
            self.choose(name == self.defaultSymbol ? nil : name)
        }

        appList.frame = CGRect(x: pad, y: field.frame.maxY + 10, width: bounds.width - 2 * pad, height: bounds.height - field.frame.maxY - 10)
        appList.clearance = EditorTheme.cutout
        appList.onChoose = { [weak self] id in self?.choose(ItemIcon.app(id).name) }
        appList.isHidden = true
        appList.alphaValue = 0
        addSubview(appList)

        let current = context.item.customSymbol.map(ItemIcon.init)
        if case .app(let id) = current {
            appList.chosen = id
            source = .apps
            shown.snap(1)
        }
        showPicture()
        showSource(animated: false)
        search("")
        grid.reveal(grid.chosen)
        appList.reveal(appList.chosen)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sets the draft's icon, and marks it in whichever view has it.
    private func choose(_ name: String?) {
        draft.customSymbol = name
        switch ItemIcon(name ?? defaultSymbol) {
        case .symbol(let symbol):
            grid.chosen = symbol
            appList.chosen = nil
        case .app(let id):
            grid.chosen = nil
            appList.chosen = id
        case .image:
            grid.chosen = nil
            appList.chosen = nil
        }
        showPicture()
    }

    private func toggleSource() {
        source = source == .symbols ? .apps : .symbols
        showSource(animated: true)
        search(field.text)
        switch source {
        case .symbols: grid.reveal(grid.chosen)
        case .apps: appList.reveal(appList.chosen)
        }
        field.focus()
    }

    /// The button shows where it goes: to the apps from the symbols, and back.
    private func showSource(animated: Bool) {
        switch source {
        case .symbols: sourceButton.set(symbol: "square.grid.2x2", label: "Apps", animated: animated)
        case .apps: sourceButton.set(symbol: "star", label: "Symbols", animated: animated)
        }
        shown.target = source == .apps ? 1 : 0
        if !animated { shown.snap(shown.target) }
        tick(0, pointer: nil)
    }

    /// A picture the user added shows on its button, ringed, while it is the icon.
    private func showPicture() {
        if let name = draft.customSymbol, case .image = ItemIcon(name) {
            pictureButton.picture = ItemIcon.picture(name)
        } else {
            pictureButton.picture = nil
        }
    }

    private func choosePicture() {
        let folder = context.store.iconFolder ?? FileManager.default.temporaryDirectory.appendingPathComponent("Gooey Wheel Icons")
        context.runModal {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = IconImages.contentTypes
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.prompt = "Choose"
            // Over the wheel, which covers the screen.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard let icon = IconImages.add(url, to: folder) else {
                NSSound.beep()
                return
            }
            choose(icon.name)
        }
    }

    private func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        switch source {
        case .symbols:
            // With nothing typed, the default leads and isn't repeated further down.
            grid.names = trimmed.isEmpty
                ? [defaultSymbol] + SymbolCatalog.all.filter { $0 != defaultSymbol }
                : SymbolCatalog.search(trimmed)
            grid.scroll(.zero)
        case .apps:
            if apps.isEmpty { apps = AppIndex.shared.apps }
            appList.rows = apps.filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }.map { app in
                ListRow(id: app.id, title: app.name, image: { NSWorkspace.shared.icon(forFile: app.url.path) })
            }
        }
    }

    func tick(_ dt: Double, pointer: CGPoint?) {
        shown.step(dt)
        let apps = CGFloat(clamp01(shown.value))
        scroll.alphaValue = 1 - apps
        appList.alphaValue = apps
        // Only the view being switched to takes the pointer.
        scroll.isHidden = source == .apps && apps > 0.99
        appList.isHidden = source == .symbols && apps < 0.01
    }

    override func focus() {
        field.focus()
    }

    override func demoPoint(_ name: String) -> CGPoint? {
        switch name {
        case "search": return field.demoPoint
        case "source": return sourceButton.demoPoint
        case "picture": return pictureButton.demoPoint
        default: break
        }
        if source == .apps { return appList.demoPoint(name) }
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

/// A round button the height of a field, with a glyph, or a picture ringed in the accent.
private final class CircleButton: NSView, EditorAnimated {
    var onPress: (() -> Void)?
    var picture: NSImage? {
        didSet { needsDisplay = true }
    }
    private let theme: EditorTheme
    private var symbol: String
    /// The glyph it is changing from, while `swap` runs from 0 to 1.
    private var previous: String?
    private var swap = Spring(1, SpringConfig(k: 420, c: 30))
    private var hover = Spring(0, SpringConfig.critical(k: 600))
    private var press = Spring(0, SpringConfig.critical(k: 900))
    private var pressed = false

    init(theme: EditorTheme, symbol: String, label: String) {
        self.theme = theme
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var demoPoint: CGPoint { convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil) }

    func set(symbol next: String, label: String, animated: Bool) {
        setAccessibilityLabel(label)
        toolTip = label
        guard next != symbol else { return }
        previous = animated ? symbol : nil
        symbol = next
        if animated, !EditorTheme.reducedMotion { swap.snap(0) }
        swap.target = 1
        if !animated || EditorTheme.reducedMotion { swap.snap(1) }
        needsDisplay = true
    }

    private func inside(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        return hypot(p.x - bounds.midX, p.y - bounds.midY) <= bounds.width / 2
    }

    override func mouseDown(with event: NSEvent) {
        pressed = inside(event)
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = inside(event)
    }

    override func mouseUp(with event: NSEvent) {
        let hit = pressed && inside(event)
        pressed = false
        if hit { onPress?() }
    }

    func tick(_ dt: Double, pointer: CGPoint?) {
        let over = pointer.map { convert($0, from: nil) }.map { hypot($0.x - bounds.midX, $0.y - bounds.midY) <= bounds.width / 2 } ?? false
        hover.target = over ? 1 : 0
        press.target = pressed && over ? 1 : 0
        let moving = [hover, press, swap].contains { abs($0.value - $0.target) > 0.002 }
        hover.step(dt)
        press.step(dt)
        swap.step(dt)
        if swap.value >= 0.999, swap.target == 1 { previous = nil }
        if moving { needsDisplay = true }
    }

    private func glyph(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium).applying(.init(hierarchicalColor: theme.text))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = CGFloat(clamp01(hover.value))
        let shrink = CGFloat(clamp01(press.value)) * 2
        let disc = bounds.insetBy(dx: shrink, dy: shrink)
        theme.well.withAlphaComponent(theme.well.alphaComponent * (1 + h)).setFill()
        NSBezierPath(ovalIn: disc).fill()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let picture {
            let face = disc.insetBy(dx: 5, dy: 5)
            picture.draw(in: face, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            theme.accent.setStroke()
            let ring = NSBezierPath(ovalIn: disc.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
            return
        }
        // The new glyph grows in as the old one shrinks away.
        let t = CGFloat(clamp01(swap.value))
        for (name, weight) in [(previous, 1 - t), (symbol, t)] where weight > 0.01 {
            guard let name, let image = glyph(name) else { continue }
            let scale = 0.6 + 0.4 * weight
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: weight, respectFlipped: true, hints: nil)
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
