import CoreGraphics

// Only Move Window's Accessibility path in the direct download places windows itself.
#if !APPSTORE

/// Where the window actions put a window, worked out from rectangles alone so the math can be
/// checked against made-up screens. Frames are in AppKit screen coordinates (origin at the
/// bottom left of the primary screen, y going up) unless a name says otherwise.
enum WindowGeometry {
    /// Layouts that grow and shrink when chosen again with the window still where they left it:
    /// a half, then two thirds, then one third, as in Rectangle.
    static let cyclingLayouts: Set<String> = ["leftHalf", "rightHalf", "topHalf", "bottomHalf"]
    private static let cycle: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    /// The share of a screen's visible frame a layout covers, as a rectangle within the unit
    /// square. Nil for layouts that depend on the window's own frame.
    static func unitRect(for layout: String, step: Int = 0) -> CGRect? {
        let f = cycle[step % cycle.count]
        let third: CGFloat = 1.0 / 3
        switch layout {
        case "leftHalf": return CGRect(x: 0, y: 0, width: f, height: 1)
        case "rightHalf": return CGRect(x: 1 - f, y: 0, width: f, height: 1)
        case "topHalf": return CGRect(x: 0, y: 1 - f, width: 1, height: f)
        case "bottomHalf": return CGRect(x: 0, y: 0, width: 1, height: f)
        case "topLeft": return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case "topRight": return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case "bottomLeft": return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case "bottomRight": return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case "leftThird": return CGRect(x: 0, y: 0, width: third, height: 1)
        case "centerThird": return CGRect(x: third, y: 0, width: third, height: 1)
        case "rightThird": return CGRect(x: 2 * third, y: 0, width: third, height: 1)
        case "leftTwoThirds": return CGRect(x: 0, y: 0, width: 2 * third, height: 1)
        case "rightTwoThirds": return CGRect(x: third, y: 0, width: 2 * third, height: 1)
        case "maximize": return CGRect(x: 0, y: 0, width: 1, height: 1)
        case "almostMaximize": return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        default: return nil
        }
    }

    /// The frame a layout gives a window whose frame is `window`, on a screen whose visible
    /// frame is `visible`. `step` counts how many times in a row the layout was chosen before.
    /// Nil for Restore and unknown layouts.
    static func frame(for layout: String, window: CGRect, visible: CGRect, step: Int = 0) -> CGRect? {
        switch layout {
        case "maximizeHeight":
            return CGRect(x: window.minX, y: visible.minY, width: window.width, height: visible.height)
        case "center":
            let width = min(window.width, visible.width)
            let height = min(window.height, visible.height)
            return CGRect(
                x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(),
                width: width, height: height
            )
        default:
            return unitRect(for: layout, step: step).map { place($0, in: visible) }
        }
    }

    /// A unit rectangle scaled into `visible`, with edges on whole points so neighboring
    /// layouts meet without a gap or overlap.
    static func place(_ unit: CGRect, in visible: CGRect) -> CGRect {
        let x0 = (visible.minX + unit.minX * visible.width).rounded()
        let x1 = (visible.minX + unit.maxX * visible.width).rounded()
        let y0 = (visible.minY + unit.minY * visible.height).rounded()
        let y1 = (visible.minY + unit.maxY * visible.height).rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `frame` moved the least it can to lie inside `visible`. A frame larger than `visible`
    /// keeps its top left corner on the screen's, where the title bar stays reachable.
    static func fitted(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var result = frame
        if result.maxX > visible.maxX { result.origin.x = visible.maxX - result.width }
        if result.minX < visible.minX { result.origin.x = visible.minX }
        if result.minY < visible.minY { result.origin.y = visible.minY }
        if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
        return result
    }

    /// The same frame on another screen: the same place and size relative to its visible
    /// frame, scaled to the new one's.
    static func moved(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let sx = target.width / source.width
        let sy = target.height / source.height
        let width = min((window.width * sx).rounded(), target.width)
        let height = min((window.height * sy).rounded(), target.height)
        let moved = CGRect(
            x: (target.minX + (window.minX - source.minX) * sx).rounded(),
            y: (target.minY + (window.minY - source.minY) * sy).rounded(),
            width: width, height: height
        )
        return fitted(moved, in: target)
    }

    /// Which of `screens` a window is on: the one holding the largest part of it, or the
    /// nearest one when it's on none of them.
    static func screenIndex(for window: CGRect, among screens: [CGRect]) -> Int? {
        let areas = screens.map { screen -> CGFloat in
            let overlap = screen.intersection(window)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let center = CGPoint(x: window.midX, y: window.midY)
        func distance(_ screen: CGRect) -> CGFloat {
            let dx = max(screen.minX - center.x, 0, center.x - screen.maxX)
            let dy = max(screen.minY - center.y, 0, center.y - screen.maxY)
            return dx * dx + dy * dy
        }
        return screens.indices.min { distance(screens[$0]) < distance(screens[$1]) }
    }

    /// The screen after `index` going left to right, and top to bottom among screens that
    /// share a left edge. Wraps around.
    static func nextScreenIndex(after index: Int, among screens: [CGRect]) -> Int {
        let order = screens.indices.sorted { a, b in
            screens[a].minX != screens[b].minX ? screens[a].minX < screens[b].minX : screens[a].maxY > screens[b].maxY
        }
        guard let position = order.firstIndex(of: index) else { return index }
        return order[(position + 1) % order.count]
    }

    /// A rectangle flipped between AppKit coordinates and the Accessibility API's, whose origin
    /// is the top left of the primary screen with y going down. Flipping twice gives it back.
    static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Whether two frames are the same to within a couple of points, as a window that was
    /// moved and read back may differ by rounding.
    static func same(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
#endif
