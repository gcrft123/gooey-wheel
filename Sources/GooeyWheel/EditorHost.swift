import AppKit
import QuartzCore
import simd

/// Puts an editing panel's views over the goo panel that the sim draws, and keeps them in
/// step with it: they fade in late as the panel opens and out early as it closes.
final class EditorHost {
    let view = NSView()
    private(set) var content: EditorContent?
    private var focused = false
    private var closing = false

    init() {
        view.wantsLayer = true
    }

    func open(_ request: EditorRequest, sim: WheelSim, style: GooStyle) {
        remove()
        EditorTheme.reducedMotion = sim.tuning.jiggle == 0
        guard let item = sim.store.item(request.itemID), let rect = sim.editorRect else { return }
        let context = EditorContext(item: item, store: sim.store, style: style, shape: PanelShape.shape(for: request.option))
        let content: EditorContent
        switch request.option {
        case .rename: content = RenameEditor(context: context)
        case .color: content = ColorEditor(context: context)
        case .icon: content = IconEditor(context: context)
        case .action, .remove: content = ActionEditor(context: context)
        }
        content.frame = CGRect(
            x: rect.center.x - rect.half.x, y: Double(view.bounds.height) - rect.center.y - rect.half.y,
            width: 2 * rect.half.x, height: 2 * rect.half.y
        )
        let mask = CAShapeLayer()
        mask.path = content.outline()
        content.layer?.mask = mask
        content.alphaValue = 0
        content.onChange = { [weak sim, weak content] in
            guard let content else { return }
            sim?.setEditorDirty(content.isDirty)
        }
        content.onSubmit = { [weak sim, weak self] in
            guard let sim, let content = self?.content else { return }
            if content.isDirty { sim.onEditorSave?() } else { sim.closeEditor() }
        }
        view.addSubview(content)
        self.content = content
        focused = false
        closing = false
    }

    /// Writes the panel's changes to the store.
    func commit(joined: Bool) {
        content?.commit(joined: joined)
    }

    /// The panel has started to close. Its views stop taking input and fade with it.
    func close() {
        closing = true
        if let content, let window = content.window {
            window.makeFirstResponder(window.contentView)
        }
    }

    func demo(_ step: Int) {
        content?.demo(step)
    }

    /// A named place in the open panel, in the wheel's coordinates.
    func demoPoint(_ name: String) -> V2? {
        guard let p = content?.demoPoint(name) else { return nil }
        return V2(Double(p.x), Double(view.bounds.height - p.y))
    }

    /// Call once per frame, with the time that passed.
    func update(sim: WheelSim, dt: Double) {
        guard let content else { return }
        let alpha = sim.editorContentAlpha
        content.alphaValue = alpha
        // Laid out now, not whenever the run loop next gets to it: the views are stepped and
        // measured this frame.
        content.layoutSubtreeIfNeeded()
        // The views follow the same pointer the wheel does, and only while it is on the panel.
        let onPanel = alpha > 0.5 && sim.config.editor?.hit == .panel
        content.step(dt, pointer: onPanel ? CGPoint(x: sim.cursor.x, y: Double(view.bounds.height) - sim.cursor.y) : nil)
        if !focused, !closing, alpha > 0.5 {
            focused = true
            content.focus()
        }
        if !sim.editorIsOpen || (closing && alpha <= 0.001) { remove() }
    }

    func remove() {
        content?.removeFromSuperview()
        content = nil
    }
}
