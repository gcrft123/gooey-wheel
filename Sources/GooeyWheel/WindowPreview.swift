import AppKit
import QuartzCore

/// A tinted rounded rectangle where a window would go. It fades in where it first appears
/// and glides between layouts after that.
struct WindowPreview {
    let layer = CALayer()
    var key: BubbleKey?
    var frame: CGRect?
    private var minX = Spring(0, Self.glide), minY = Spring(0, Self.glide)
    private var maxX = Spring(0, Self.glide), maxY = Spring(0, Self.glide)
    private var alpha = Spring(0, SpringConfig.critical(k: 500))
    private static let glide = SpringConfig(k: 420, c: 38)

    init() {
        layer.cornerRadius = 12
        layer.borderWidth = 2
        layer.opacity = 0
    }

    mutating func show(_ rect: CGRect, style: GooStyle) {
        let inset = rect.insetBy(dx: 3, dy: 3)
        if alpha.value < 0.02 {
            minX.snap(inset.minX)
            minY.snap(inset.minY)
            maxX.snap(inset.maxX)
            maxY.snap(inset.maxY)
        } else {
            minX.target = inset.minX
            minY.target = inset.minY
            maxX.target = inset.maxX
            maxY.target = inset.maxY
        }
        alpha.target = 1
        let a = style.accent
        layer.backgroundColor = CGColor(srgbRed: CGFloat(a.x), green: CGFloat(a.y), blue: CGFloat(a.z), alpha: 0.16)
        layer.borderColor = CGColor(srgbRed: CGFloat(a.x), green: CGFloat(a.y), blue: CGFloat(a.z), alpha: 0.6)
    }

    mutating func hide() {
        alpha.target = 0
    }

    /// Call inside a CATransaction with actions disabled.
    mutating func step(_ dt: Double) {
        for i in 0..<4 {
            switch i {
            case 0: minX.step(dt)
            case 1: minY.step(dt)
            case 2: maxX.step(dt)
            default: maxY.step(dt)
            }
        }
        alpha.step(dt)
        layer.frame = CGRect(x: minX.value, y: minY.value, width: max(maxX.value - minX.value, 0), height: max(maxY.value - minY.value, 0))
        layer.opacity = Float(clamp01(alpha.value))
    }
}
