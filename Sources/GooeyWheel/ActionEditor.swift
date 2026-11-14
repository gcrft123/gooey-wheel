import AppKit

/// Every action, by category, on the left. What the chosen action needs set, on the right.
final class ActionEditor: EditorContent {
    private let picker: SearchList
    private let pane = FlippedView()
    private let preview: ActionPreview
    private var parameter: ParameterView?
    /// The category that is open. One at a time, so the list stays short.
    private var open: String?
    private var query = ""

    override init(context: EditorContext) {
        let theme = EditorTheme(context.style)
        picker = SearchList(theme: theme, placeholder: "Search")
        preview = ActionPreview(theme: theme)
        super.init(context: context)
        open = draft.actionID.flatMap(ActionCatalog.category(of:))?.id

        let pad = EditorTheme.padding
        let column: CGFloat = 300
        // The search pill sits in the panel's corner, concentric with it.
        picker.frame = CGRect(x: pad, y: pad, width: column, height: bounds.height - pad)
        picker.list.clearance = EditorTheme.cutout
        picker.list.chosen = draft.actionID
        picker.onSearch = { [weak self] in
            self?.query = $0.trimmingCharacters(in: .whitespaces)
            self?.reload()
        }
        picker.onReturn = { [weak self] in self?.onSubmit?() }
        picker.list.onChoose = { [weak self] in self?.choose($0) }
        picker.list.onToggle = { [weak self] id in
            guard let self else { return }
            self.open = self.open == id ? nil : id
            self.reload()
            if self.open == id { self.picker.list.revealSection(id) }
        }
        addSubview(picker)

        let rule = NSView(frame: CGRect(x: picker.frame.maxX + 14, y: pad + 6, width: 1, height: bounds.height - 2 * pad - 12))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = theme.hairline.cgColor
        addSubview(rule)

        pane.frame = CGRect(x: rule.frame.maxX + 18, y: pad, width: bounds.width - rule.frame.maxX - 18 - pad, height: bounds.height - 2 * pad)
        addSubview(pane)
        pane.addSubview(preview)

        reload()
        picker.list.reveal(draft.actionID)
        showSetting()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: List

    private func reload() {
        var rows: [ListRow] = []
        if query.isEmpty {
            for category in ActionCatalog.categories {
                rows.append(ListRow(id: category.id, title: category.title, kind: .section(open: open == category.id), symbol: category.symbol))
                guard open == category.id else { continue }
                rows += category.actions.map { ListRow(id: $0.id, title: $0.title, symbol: $0.symbol, indent: 14) }
            }
        } else {
            // Titles that start with what was typed come first, then other matches.
            var starts: [ListRow] = []
            var contains: [ListRow] = []
            for category in ActionCatalog.categories {
                for action in category.actions {
                    let row = ListRow(id: action.id, title: action.title, symbol: action.symbol)
                    if action.title.range(of: query, options: [.caseInsensitive, .anchored]) != nil {
                        starts.append(row)
                    } else if action.title.localizedCaseInsensitiveContains(query)
                        || action.keywords.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                        || category.title.localizedCaseInsensitiveContains(query) {
                        contains.append(row)
                    }
                }
            }
            rows = starts + contains
        }
        picker.list.rows = rows
    }

    private func choose(_ id: String) {
        guard id != draft.actionID, let action = ActionCatalog.action(id) else { return }
        // A setting carries over only to an action that takes the same kind.
        let before = draft.actionID.flatMap(ActionCatalog.action)?.parameter
        if before != action.parameter { draft.argument = nil }
        draft.actionID = id
        showSetting()
    }

    // MARK: Setting

    /// The draft under its action's own name and icon. A custom name or icon stays on the
    /// bubble whatever the action, so it would say nothing about the action being chosen.
    private var plain: WheelItem {
        var item = draft
        item.customTitle = nil
        item.customSymbol = nil
        return item
    }

    private func showSetting() {
        parameter?.removeFromSuperview()
        parameter = nil
        let action = draft.actionID.flatMap(ActionCatalog.action)
        preview.item = plain
        guard let kind = action?.parameter else {
            // Nothing to set: the bubble itself, large, is all there is to show.
            preview.large = true
            preview.frame = pane.bounds
            return
        }
        preview.large = false
        // The heading is as tall as the search pill beside it, so the two line up.
        let heading = EditorTheme.fieldHeight
        preview.frame = CGRect(x: 0, y: 0, width: pane.bounds.width, height: heading)
        let view = ParameterView.make(kind, value: draft.argument, theme: theme)
        // A setting ends above the line where the save button's corner begins, so nothing in
        // it is ever under that button.
        let floor = pane.bounds.height - (EditorTheme.cutout - EditorTheme.padding) - 6
        view.frame = CGRect(x: 0, y: heading + 10, width: pane.bounds.width, height: floor - heading - 10)
        view.onChange = { [weak self] value in
            self?.draft.argument = value
            self?.preview.item = self?.plain
        }
        view.onReturn = { [weak self] in self?.onSubmit?() }
        pane.addSubview(view)
        parameter = view
    }

    override func focus() {
        picker.field.focus()
    }

    // MARK: Demo

    override func demoPoint(_ name: String) -> CGPoint? {
        if name == "search" { return picker.field.demoPoint }
        if name.hasPrefix("row:") { return picker.list.demoPoint(String(name.dropFirst(4))) }
        if name.hasPrefix("setting:") { return parameter?.demoPoint(String(name.dropFirst(8))) }
        return nil
    }

    private func show(_ id: String, _ argument: String?) {
        guard let action = ActionCatalog.action(id) else { return }
        picker.field.text = ""
        query = ""
        open = ActionCatalog.category(of: id)?.id
        _ = action
        draft.actionID = id
        draft.argument = argument
        reload()
        picker.list.chosen = id
        picker.list.reveal(id)
        showSetting()
    }

    override func demo(_ step: Int) {
        switch step {
        case 0: show("apps.open", "com.apple.Safari")
        case 1: show("automation.shell", "open -a Terminal ~/Projects\nsay \"Ready\"")
        case 2: show("automation.keystroke", "⌃⌥⌘T")
        case 3: show("system.screenshot", "selection")
        case 4: show("window.move", "leftHalf")
        case 5: show("apps.openFile", "/System/Library/CoreServices/Applications/Directory Utility.app")
        case 6: show("apps.openWebsite", "https://apple.com")
        case 7: show("automation.shortcut", nil)
        case 8: show("automation.appleScript", "display notification \"Done\" with title \"Gooey Wheel\"")
        case 9: show("media.playPause", nil)
        default:
            picker.field.text = "vol"
            query = "vol"
            reload()
        }
    }
}

/// The chosen action's icon and name: small as a heading over its setting, or large, like
/// the bubble it makes, when there is nothing to set.
private final class ActionPreview: NSView {
    var item: WheelItem? {
        didSet { needsDisplay = true }
    }
    var large = false {
        didSet { needsDisplay = true }
    }
    private let theme: EditorTheme

    init(theme: EditorTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let chosen = item.actionID != nil
        let radius: CGFloat = large ? 56 : 21
        let center = large ? CGPoint(x: bounds.midX, y: bounds.midY - 26) : CGPoint(x: radius + 1, y: bounds.midY)
        let disc = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        theme.well.setFill()
        NSBezierPath(ovalIn: disc).fill()

        let color = chosen ? (item.color?.nsColor ?? theme.text) : theme.secondary
        let config = NSImage.SymbolConfiguration(pointSize: large ? 38 : 16, weight: .medium).applying(.init(hierarchicalColor: color))
        let symbol = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)
        if let image = symbol?.withSymbolConfiguration(config) {
            image.draw(in: CGRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2, width: image.size.width, height: image.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        guard chosen else { return }
        let title = NSAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: large ? 18 : 16, weight: .semibold), .foregroundColor: theme.text,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = large ? .center : .natural; return p }(),
        ])
        let height = ceil(title.size().height)
        if large {
            title.draw(in: CGRect(x: 0, y: disc.maxY + 16, width: bounds.width, height: height))
        } else {
            title.draw(in: CGRect(x: disc.maxX + 12, y: center.y - height / 2, width: bounds.width - disc.maxX - 12, height: height))
        }
    }
}
