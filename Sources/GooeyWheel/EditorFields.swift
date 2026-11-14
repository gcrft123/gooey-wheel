import AppKit

extension NSScrollView {
    /// Room between a panel's bottom edge and the scrolling contents, as at its sides.
    static let bottomSpace: CGFloat = EditorTheme.padding
    static let fadeLength: CGFloat = 28
    /// How far above the bottom edge the contents start to fade.
    static var fadeStart: CGFloat { bottomSpace + fadeLength }

    /// Fades the scrolling contents out toward the bottom, so they are gone `bottomSpace`
    /// above the panel's edge, beside the buttons in its corners. Once scrolled, the top fades
    /// too, so rows slide out of sight under the field above instead of being sliced by it.
    /// Call again when the view's size or scroll position changes.
    func fadeEdges() {
        wantsLayer = true
        let mask = (layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        let h = max(bounds.height, 1)
        let top = min(max(contentView.bounds.minY, 0), 16)
        let key = "\(Int(h))-\(Int(top * 2))"
        guard mask.name != key else { return }
        mask.name = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        let clear = NSColor.clear.cgColor
        let solid = NSColor.black.cgColor
        mask.colors = [top > 0.5 ? clear : solid, solid, solid, clear, clear]
        // A scroll view's layer runs top-down.
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        let gone = max(1 - Self.bottomSpace / h, 0)
        let fade = max(1 - Self.fadeStart / h, 0)
        mask.locations = [0, NSNumber(value: Double(top / h)), NSNumber(value: Double(fade)), NSNumber(value: Double(gone)), 1]
        layer?.mask = mask
        CATransaction.commit()
    }
}

/// A text field that shows a long value shortened in the middle, such as a path, and shows
/// all of it, scrolling, while it is being edited.
private final class MiddleTruncatingField: NSTextField {
    func rest() {
        cell?.isScrollable = false
        cell?.lineBreakMode = .byTruncatingMiddle
    }

    override func becomeFirstResponder() -> Bool {
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
        return super.becomeFirstResponder()
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        rest()
    }
}

/// A plain view whose coordinates run top-down, like the panels'.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A text field without a frame, in a pill. The pill gains an accent outline while the
/// field has the keyboard.
final class WellField: NSView, NSTextFieldDelegate, EditorAnimated {
    let field: NSTextField
    var onChange: ((String) -> Void)?
    var onReturn: (() -> Void)?
    /// Arrow keys, for a field that searches a list.
    var onMove: ((Int) -> Void)?
    private let symbol: NSImageView?
    private let theme: EditorTheme
    private let hasWell: Bool
    private var ring = Spring(0, SpringConfig.critical(k: 500))
    private var styledEditor = false

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init(theme: EditorTheme, placeholder: String, symbol name: String? = nil, font: NSFont = EditorTheme.font, centered: Bool = false, well: Bool = true, truncatesMiddle: Bool = false) {
        self.theme = theme
        hasWell = well
        symbol = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }.map(NSImageView.init(image:))
        field = truncatesMiddle ? MiddleTruncatingField() : NSTextField()
        super.init(frame: .zero)
        wantsLayer = true
        if well {
            layer?.backgroundColor = theme.well.cgColor
            layer?.borderWidth = 1.5
            layer?.borderColor = theme.accent.withAlphaComponent(0).cgColor
        }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = theme.text
        field.alignment = centered ? .center : .natural
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.allowsUndo = true
        (field as? MiddleTruncatingField)?.rest()
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: theme.secondary,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = centered ? .center : .natural; return p }(),
        ])
        field.delegate = self
        addSubview(field)
        if let symbol {
            symbol.contentTintColor = theme.secondary
            symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            addSubview(symbol)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let height = ceil(field.intrinsicContentSize.height)
        // The text starts where the pill's round end has straightened out.
        var left: CGFloat = 18
        if let symbol {
            symbol.frame = CGRect(x: 15, y: (bounds.height - 18) / 2, width: 18, height: 18)
            left = 40
        }
        field.frame = CGRect(x: left, y: (bounds.height - height) / 2, width: bounds.width - left - 18, height: height)
    }

    /// A click anywhere in the pill puts the cursor in the field.
    override func mouseDown(with event: NSEvent) {
        focus(selectAll: false)
    }

    func focus(selectAll: Bool = false) {
        window?.makeFirstResponder(field)
        if !selectAll { field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0) }
    }

    private var isEditing: Bool { field.currentEditor() != nil }

    var demoPoint: CGPoint { convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil) }

    func tick(_ dt: Double, pointer: CGPoint?) {
        let editing = isEditing
        if editing, !styledEditor, let editor = field.currentEditor() as? NSTextView {
            // The caret and the selection take the wheel's accent.
            editor.insertionPointColor = theme.accent
            editor.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.32)]
        }
        styledEditor = editing
        ring.target = editing ? 1 : 0
        guard abs(ring.value - ring.target) > 0.002 else { return }
        ring.step(dt)
        if hasWell { layer?.borderColor = theme.accent.withAlphaComponent(CGFloat(clamp01(ring.value)) * 0.9).cgColor }
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard let onReturn else { return false }
            onReturn()
        case #selector(NSResponder.moveDown(_:)):
            guard let onMove else { return false }
            onMove(1)
        case #selector(NSResponder.moveUp(_:)):
            guard let onMove else { return false }
            onMove(-1)
        default:
            return false
        }
        return true
    }
}
