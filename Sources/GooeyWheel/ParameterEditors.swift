import AppKit

/// The control for one action setting. Its value is the string the item stores.
class ParameterView: NSView {
    let theme: EditorTheme
    var onChange: ((String?) -> Void)?
    /// Return was pressed where it means "done".
    var onReturn: (() -> Void)?

    init(theme: EditorTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func focus() {}

    /// A point in this control for the demo's cursor, in the window's coordinates: `x` and
    /// `y` as fractions of its size, or a row by name in a control that lists things.
    func demoPoint(_ name: String) -> CGPoint? {
        let parts = name.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return convert(CGPoint(x: bounds.width * parts[0], y: bounds.height * parts[1]), to: nil)
    }

    static func make(_ parameter: ActionParameter, value: String?, theme: EditorTheme) -> ParameterView {
        switch parameter {
        case .application: return AppPicker(value: value, theme: theme)
        case .shortcut: return ShortcutPicker(value: value, theme: theme)
        case .file: return PathEditor(folder: false, value: value, theme: theme)
        case .folder: return PathEditor(folder: true, value: value, theme: theme)
        case .url: return LineEditor(value: value, placeholder: "https://", theme: theme)
        case .shellCommand, .appleScript: return TextEditor(value: value, monospaced: true, theme: theme)
        case .text: return TextEditor(value: value, monospaced: false, theme: theme)
        case .keystroke: return KeystrokeRecorder(value: value, theme: theme)
        case .choice(let options): return ChoiceEditor(options: options, value: value, theme: theme)
        case .level(let range, let unit): return LevelEditor(range: range, unit: unit, value: value, theme: theme)
        }
    }
}

// MARK: Lists

/// A searchable list of installed apps with their icons.
private final class AppPicker: ParameterView {
    private let picker: SearchList
    private let apps = AppIndex.shared.apps

    init(value: String?, theme: EditorTheme) {
        picker = SearchList(theme: theme, placeholder: "Search")
        super.init(theme: theme)
        picker.onSearch = { [weak self] in self?.show(matching: $0) }
        picker.onReturn = { [weak self] in self?.onReturn?() }
        picker.list.onChoose = { [weak self] in self?.onChange?($0) }
        picker.list.chosen = value
        addSubview(picker)
        show(matching: "")
        picker.list.reveal(value)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func show(matching query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        picker.list.rows = apps.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }.map { app in
            ListRow(id: app.id, title: app.name, image: { NSWorkspace.shared.icon(forFile: app.url.path) })
        }
    }

    override func layout() {
        super.layout()
        picker.frame = bounds
    }

    override func demoPoint(_ name: String) -> CGPoint? {
        name == "search" ? picker.field.demoPoint : picker.list.demoPoint(name)
    }

    override func focus() { picker.field.focus() }
}

/// The shortcuts in the Shortcuts app, read from its command line tool.
private final class ShortcutPicker: ParameterView {
    private let picker: SearchList
    private var names: [String] = []

    init(value: String?, theme: EditorTheme) {
        picker = SearchList(theme: theme, placeholder: "Search")
        super.init(theme: theme)
        picker.onSearch = { [weak self] in self?.show(matching: $0) }
        picker.onReturn = { [weak self] in self?.onReturn?() }
        picker.list.onChoose = { [weak self] in self?.onChange?($0) }
        picker.list.chosen = value
        addSubview(picker)
        // A shortcut that was set stays listed while the rest load, and if it has since been deleted.
        names = value.map { [$0] } ?? []
        if AppIndex.systemAppsOnly {
            // The scripted demo's made-up names need no loading.
            names = Self.list() + names.filter { !Self.list().contains($0) }
            show(matching: "")
            return
        }
        show(matching: "")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listed = Self.list()
            DispatchQueue.main.async {
                guard let self else { return }
                self.names = listed + self.names.filter { !listed.contains($0) }
                self.show(matching: self.picker.field.text)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func list() -> [String] {
        // The scripted demo shows made-up names in place of this Mac's shortcuts.
        if AppIndex.systemAppsOnly { return ["Morning Report", "Start Timer", "Toggle Focus", "Log Water", "Text Last Photo"] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func show(matching query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        picker.list.rows = names.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }.map {
            ListRow(id: $0, title: $0, symbol: "square.2.layers.3d")
        }
    }

    override func layout() {
        super.layout()
        picker.frame = bounds
    }

    override func demoPoint(_ name: String) -> CGPoint? {
        name == "search" ? picker.field.demoPoint : picker.list.demoPoint(name)
    }

    override func focus() { picker.field.focus() }
}

// MARK: Text

/// One line, for a web address.
private final class LineEditor: ParameterView {
    private let field: WellField

    init(value: String?, placeholder: String, theme: EditorTheme) {
        field = WellField(theme: theme, placeholder: placeholder)
        super.init(theme: theme)
        field.text = value ?? ""
        field.onChange = { [weak self] in self?.onChange?($0.isEmpty ? nil : $0) }
        field.onReturn = { [weak self] in self?.onReturn?() }
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        field.frame = CGRect(x: 0, y: 0, width: bounds.width, height: EditorTheme.fieldHeight)
    }

    override func focus() { field.focus() }
}

/// Several lines: a command, a script, or text to type. Return makes a new line.
private final class TextEditor: ParameterView, NSTextViewDelegate, EditorAnimated {
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private var ring = Spring(0, SpringConfig.critical(k: 500))

    init(value: String?, monospaced: Bool, theme: EditorTheme) {
        super.init(theme: theme)
        wantsLayer = true
        layer?.backgroundColor = theme.well.cgColor
        layer?.cornerRadius = 22
        layer?.borderWidth = 1.5
        layer?.borderColor = theme.accent.withAlphaComponent(0).cgColor
        text.string = value ?? ""
        text.font = monospaced ? EditorTheme.mono : EditorTheme.font
        text.textColor = theme.text
        text.insertionPointColor = theme.accent
        text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.32)]
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.textContainerInset = NSSize(width: 12, height: 14)
        text.defaultParagraphStyle = { let p = NSMutableParagraphStyle(); p.lineSpacing = 3; return p }()
        text.typingAttributes[.paragraphStyle] = text.defaultParagraphStyle
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.delegate = self
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = text
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Inset from the well's round corners, so text never runs into them.
        scroll.frame = bounds.insetBy(dx: 4, dy: 6)
        text.minSize = scroll.contentSize
        text.frame.size.width = scroll.contentSize.width
    }

    func textDidChange(_ notification: Notification) {
        onChange?(text.string.isEmpty ? nil : text.string)
    }

    override func mouseDown(with event: NSEvent) {
        focus()
    }

    override func focus() {
        window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: text.string.count, length: 0))
    }

    func tick(_ dt: Double, pointer: CGPoint?) {
        ring.target = window?.firstResponder === text ? 1 : 0
        guard abs(ring.value - ring.target) > 0.002 else { return }
        ring.step(dt)
        layer?.borderColor = theme.accent.withAlphaComponent(CGFloat(clamp01(ring.value)) * 0.9).cgColor
    }
}

// MARK: Files

/// A place to drop a file or folder from Finder, over a field for typing its path.
private final class PathEditor: ParameterView {
    private let folder: Bool
    private let field: WellField
    private var path: String?
    private var hovering = false

    init(folder: Bool, value: String?, theme: EditorTheme) {
        self.folder = folder
        field = WellField(theme: theme, placeholder: folder ? "~/Folder" : "~/File", font: EditorTheme.mono, truncatesMiddle: true)
        super.init(theme: theme)
        path = value
        field.text = value ?? ""
        field.onChange = { [weak self] in self?.set($0.isEmpty ? nil : $0, typed: true) }
        field.onReturn = { [weak self] in self?.onReturn?() }
        addSubview(field)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var well: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - EditorTheme.fieldHeight - 12)
    }

    override func layout() {
        super.layout()
        field.frame = CGRect(x: 0, y: well.maxY + 12, width: bounds.width, height: EditorTheme.fieldHeight)
    }

    private func set(_ value: String?, typed: Bool) {
        path = value
        if !typed { field.text = value ?? "" }
        needsDisplay = true
        onChange?(value)
    }

    /// The file's own icon when the path leads somewhere of the right kind.
    private var icon: NSImage? {
        guard let path else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isFolder) else { return nil }
        let bundle = expanded.hasSuffix(".app")
        guard folder ? isFolder.boolValue && !bundle : (!isFolder.boolValue || bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile: expanded)
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = well.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 22, yRadius: 22)
        if hovering {
            theme.accent.withAlphaComponent(0.16).setFill()
            outline.fill()
        }
        (hovering ? theme.accent : theme.secondary.withAlphaComponent(0.35)).setStroke()
        outline.lineWidth = 1.5
        outline.lineCapStyle = .round
        outline.setLineDash([1, 7], count: 2, phase: 0)
        outline.stroke()
        if let icon {
            let side = min(96, frame.height - 32)
            icon.draw(in: CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 38, weight: .regular).applying(.init(hierarchicalColor: theme.secondary))
            let name = folder ? "folder.badge.plus" : "arrow.down.doc"
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                image.draw(in: CGRect(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2, width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    private func dropped(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let url = urls?.first else { return nil }
        let bundle = url.pathExtension == "app"
        return folder == (url.hasDirectoryPath && !bundle) ? url : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovering = dropped(sender) != nil
        needsDisplay = true
        return hovering ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hovering = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering = false
        guard let url = dropped(sender) else {
            needsDisplay = true
            return false
        }
        set((url.path as NSString).abbreviatingWithTildeInPath, typed: false)
        return true
    }

    override func focus() { field.focus() }
}

// MARK: Keys

/// A view that takes key presses whole, including ones with ⌘ that would otherwise be shortcuts.
protocol KeyRecording: AnyObject {
    func record(_ event: NSEvent)
}

/// Shows a key combination. Click it and press the keys to set it; Delete clears it.
private final class KeystrokeRecorder: ParameterView, KeyRecording, EditorAnimated {
    private var value: String?
    /// Modifiers held right now, shown while waiting for the key.
    private var held = ""

    init(value: String?, theme: EditorTheme) {
        self.value = value
        super.init(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private var recording: Bool { window?.firstResponder === self }

    private var well: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: 120) }
    private var ring = Spring(0, SpringConfig.critical(k: 500))

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        held = ""
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func focus() {
        window?.makeFirstResponder(self)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    private static let named: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 76: "⌤",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        // Delete on its own clears the combination.
        if event.keyCode == 51, flags.isEmpty {
            set(nil)
            return
        }
        let key = Self.named[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !key.isEmpty else { return }
        set(Self.modifiers(flags) + key)
    }

    func set(_ next: String?) {
        value = next
        held = ""
        needsDisplay = true
        onChange?(next)
    }

    override func keyDown(with event: NSEvent) {
        record(event)
    }

    override func flagsChanged(with event: NSEvent) {
        held = Self.modifiers(event.modifierFlags)
        needsDisplay = true
    }

    func tick(_ dt: Double, pointer: CGPoint?) {
        ring.target = recording ? 1 : 0
        guard abs(ring.value - ring.target) > 0.002 else { return }
        ring.step(dt)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = well.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 28, yRadius: 28)
        theme.well.setFill()
        outline.fill()
        let lit = CGFloat(clamp01(ring.value))
        if lit > 0.01 {
            theme.accent.withAlphaComponent(0.9 * lit).setStroke()
            outline.lineWidth = 1.5
            outline.stroke()
        }
        let shown = held.isEmpty ? value : held
        if let shown {
            let text = NSAttributedString(string: shown, attributes: [
                .font: NSFont.systemFont(ofSize: 36, weight: .medium),
                .foregroundColor: held.isEmpty ? theme.text : theme.secondary, .kern: 4,
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        } else {
            let tint = theme.secondary.blended(withFraction: lit, of: theme.accent) ?? theme.secondary
            let config = NSImage.SymbolConfiguration(pointSize: 36, weight: .regular).applying(.init(hierarchicalColor: tint))
            if let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                image.draw(in: CGRect(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2, width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
}

// MARK: Values

/// A few fixed options side by side in a pill. The chosen one is marked by a thumb that
/// glides to wherever it is picked.
private final class ChoiceEditor: ParameterView, EditorAnimated {
    private let options: [String]
    private var chosen: Int?
    private var thumb = GlidingRect()
    private var hover = GlidingRect()

    init(options: [String], value: String?, theme: EditorTheme) {
        self.options = options
        chosen = value.flatMap(options.firstIndex(of:))
        super.init(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var track: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: EditorTheme.fieldHeight) }

    private func segment(_ index: Int) -> CGRect {
        let inner = track.insetBy(dx: 4, dy: 4)
        let width = inner.width / CGFloat(max(options.count, 1))
        return CGRect(x: inner.minX + CGFloat(index) * width, y: inner.minY, width: width, height: inner.height)
    }

    private func index(at p: CGPoint) -> Int? {
        guard track.contains(p) else { return nil }
        return options.indices.first { segment($0).insetBy(dx: 0, dy: -4).contains(p) }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)), i != chosen else { return }
        chosen = i
        onChange?(options[i])
    }

    func tick(_ dt: Double, pointer: CGPoint?) {
        let under = pointer.flatMap { index(at: convert($0, from: nil)) }
        if let under, under != chosen { hover.show(at: segment(under)) } else { hover.hide() }
        if let chosen { thumb.show(at: segment(chosen)) } else { thumb.hide() }
        hover.step(dt)
        thumb.step(dt)
        if hover.isMoving || thumb.isMoving { needsDisplay = true }
    }

    private func pill(_ rect: CGRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.well.setFill()
        pill(track).fill()
        if hover.isVisible {
            theme.well.withAlphaComponent(theme.well.alphaComponent * CGFloat(clamp01(hover.alpha.value))).setFill()
            pill(hover.rect).fill()
        }
        let marked = thumb.rect
        if thumb.isVisible {
            theme.accent.withAlphaComponent(CGFloat(clamp01(thumb.alpha.value))).setFill()
            pill(marked).fill()
        }
        for (i, option) in options.enumerated() {
            let frame = segment(i)
            // A label takes the accent's contrasting color by as much as the thumb covers it.
            let cover = thumb.isVisible ? clamp01(Double(frame.intersection(marked).width / frame.width) * thumb.alpha.value) : 0
            let color = theme.text.blended(withFraction: CGFloat(cover), of: theme.onAccent) ?? theme.text
            let label = NSAttributedString(string: option, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: color,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
    }
}

/// A slider drawn like the rest of the panel: a pill track that fills with the accent up
/// to a round knob, which swells while it is held, and the value beside it.
private final class LevelEditor: ParameterView, EditorAnimated {
    private let range: ClosedRange<Double>
    private let unit: String
    private var value: Double
    private var isSet: Bool
    private var dragging = false
    private var knob = Spring(11, SpringConfig(k: 520, c: 25))
    /// The knob's place, which glides when the value jumps from a click on the track.
    private var position: Spring

    init(range: ClosedRange<Double>, unit: String, value: String?, theme: EditorTheme) {
        self.range = range
        self.unit = unit
        isSet = value.flatMap(Double.init) != nil
        self.value = value.flatMap(Double.init) ?? (range.lowerBound + range.upperBound) / 2
        position = Spring(0, SpringConfig(k: 700, c: 44))
        super.init(theme: theme)
        position.snap(fraction)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    private var track: CGRect { CGRect(x: 14, y: EditorTheme.fieldHeight / 2 - 5, width: bounds.width - 14 - 86, height: 10) }

    private func set(from event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let f = Double(min(max((x - track.minX) / track.width, 0), 1))
        value = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
        isSet = true
        position.target = fraction
        needsDisplay = true
        onChange?(String(Int(value)))
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        set(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        set(from: event)
        // While it is held the knob keeps up with the pointer exactly.
        position.snap(fraction)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    func tick(_ dt: Double, pointer: CGPoint?) {
        let over = pointer.map { p -> Bool in
            let local = convert(p, from: nil)
            return abs(local.y - track.midY) < 18 && local.x > track.minX - 14 && local.x < track.maxX + 14
        } ?? false
        knob.target = dragging ? 15 : (over ? 13 : 11)
        knob.step(dt)
        position.step(dt)
        if abs(knob.value - knob.target) > 0.02 || abs(position.value - position.target) > 0.0005 { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = self.track
        let x = track.minX + track.width * CGFloat(clamp01(position.value))
        theme.well.setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        (isSet ? theme.accent : theme.secondary).setFill()
        NSBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: max(x - track.minX, 10), height: track.height), xRadius: 5, yRadius: 5).fill()
        let r = CGFloat(knob.value)
        let disc = CGRect(x: x - r, y: track.midY - r, width: 2 * r, height: 2 * r)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = CGSize(width: 0, height: -1.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: disc).fill()
        NSGraphicsContext.restoreGraphicsState()

        let label = NSAttributedString(string: "\(Int(value))\(unit)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium),
            .foregroundColor: isSet ? theme.text : theme.secondary,
        ])
        let size = label.size()
        label.draw(at: CGPoint(x: bounds.width - size.width - 4, y: track.midY - size.height / 2))
    }
}
