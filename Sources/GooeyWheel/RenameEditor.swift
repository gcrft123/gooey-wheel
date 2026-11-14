import AppKit

/// A pill with the item's name in it. An empty name goes back to the action's own.
final class RenameEditor: EditorContent {
    private let field: WellField

    override init(context: EditorContext) {
        var unnamed = context.item
        unnamed.customTitle = nil
        field = WellField(
            theme: EditorTheme(context.style), placeholder: unnamed.title,
            font: .systemFont(ofSize: 17, weight: .medium), centered: true, well: false
        )
        super.init(context: context)
        field.text = context.item.customTitle ?? ""
        field.frame = bounds.insetBy(dx: 10, dy: 0)
        field.onChange = { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespaces)
            self?.draft.customTitle = name.isEmpty ? nil : name
        }
        field.onReturn = { [weak self] in self?.onSubmit?() }
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func focus() {
        field.focus(selectAll: true)
    }

    override func demoPoint(_ name: String) -> CGPoint? {
        name == "field" ? field.demoPoint : nil
    }

    override func demo(_ step: Int) {
        field.text = step == 0 ? "Browser" : ""
        field.onChange?(field.text)
    }
}
