import AppKit
import simd

/// Clips a view to a goo panel, so what is inside it follows the panel's edge as drawn. Away
/// from the bottom corners that is a rounded rectangle. At each corner with a cutout, the mask
/// is an image of the panel's distance field, the one the shader draws, so the contents follow
/// the cutout and its soft shoulders exactly, while it opens and when the button leans.
///
/// Set `layer` as the mask of a view whose coordinates run bottom-up.
final class PanelMask {
    let layer = CALayer()
    private let body = CAShapeLayer()
    private let corners = [CALayer(), CALayer()]
    private var key: [Double] = []
    /// The side of a corner image, enough for a cutout, its shoulders, and a leaning button.
    private static let tile = 120.0

    init() {
        layer.addSublayer(body)
        for corner in corners { layer.addSublayer(corner) }
    }

    /// Fits the mask to `panel`, a blob in the goo's coordinates (y down). `origin` is where
    /// the masked view's top-left corner is in those coordinates, and `size` is its size.
    func update(panel: Blob?, origin: V2, size: CGSize, scale: CGFloat) {
        guard let panel else {
            key = []
            body.path = nil
            for corner in corners { corner.contents = nil }
            return
        }
        let cuts = [panel.cutoutLeft, panel.cutoutRight]
        var next: [Double] = [panel.center.x - origin.x, panel.center.y - origin.y, panel.half.x, panel.half.y, panel.corner, panel.cornerBottom ?? -1, Double(size.width), Double(size.height)]
        for cut in cuts { next += [cut?.center.x ?? 0, cut?.center.y ?? 0, cut?.radius ?? 0] }
        guard next.count != key.count || zip(next, key).contains(where: { abs($0 - $1) > 0.02 }) else { return }
        key = next

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.frame = CGRect(origin: .zero, size: size)
        // The panel's body in the view's coordinates, y up: its top edge is the goo's top.
        let left = panel.center.x - panel.half.x - origin.x
        let bottom = Double(size.height) - (panel.center.y + panel.half.y - origin.y)
        let box = CGRect(x: left, y: bottom, width: 2 * panel.half.x, height: 2 * panel.half.y)
        var path: CGPath = Self.roundedRect(box, top: panel.corner, bottom: panel.cornerBottom ?? panel.corner)
        let side = min(Self.tile, panel.half.x, panel.half.y)
        for (index, cut) in cuts.enumerated() {
            let corner = corners[index]
            guard cut != nil, side > 1 else {
                corner.contents = nil
                continue
            }
            let frame = CGRect(x: index == 0 ? box.minX : box.maxX - side, y: box.minY, width: side, height: side)
            path = path.subtracting(CGPath(rect: frame, transform: nil))
            corner.frame = frame
            corner.contentsScale = scale
            // The tile's top-left corner in the goo's coordinates.
            let topLeft = V2(origin.x + Double(frame.minX), origin.y + Double(size.height - frame.maxY))
            corner.contents = Self.coverage(of: panel, from: topLeft, side: side, scale: Double(scale))
        }
        body.path = path
    }

    /// A rectangle in bottom-up coordinates with one radius for its top corners and another
    /// for its bottom ones.
    private static func roundedRect(_ r: CGRect, top: Double, bottom: Double) -> CGPath {
        let t = min(CGFloat(top), r.width / 2, r.height / 2)
        let b = min(CGFloat(bottom), r.width / 2, r.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.midX, y: r.minY))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: b)
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: t)
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: t)
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: b)
        path.closeSubpath()
        return path
    }

    /// An alpha image of how much of each pixel is inside `blob`, over a square of the goo's space.
    private static func coverage(of blob: Blob, from topLeft: V2, side: Double, scale: Double) -> CGImage? {
        let n = Int((side * scale).rounded(.up))
        var pixels = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let p = topLeft + V2(Double(x) + 0.5, Double(y) + 0.5) / scale
                pixels[y * n + x] = UInt8(clamp01(0.5 - distance(p, to: blob) * scale) * 255)
            }
        }
        return pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)?.makeImage()
        }
    }

    /// A blob's signed distance at `p`: a rounded box less its corner cutouts, as `sd_blob`
    /// in the goo's shader computes it.
    private static func distance(_ p: V2, to b: Blob) -> Double {
        let local = p - b.center
        let r = local.y > 0 ? b.cornerBottom ?? b.corner : b.corner
        let q = simd_abs(local) - b.half + V2(r, r)
        var d = simd_length(simd_max(q, V2(0, 0))) + min(max(q.x, q.y), 0) - r
        for (cut, side) in [(b.cutoutLeft, -1.0), (b.cutoutRight, 1.0)] {
            guard let cut, cut.radius >= 0.05 else { continue }
            let c = p - cut.center
            let u = V2(side * c.x, c.y)
            let quad = u.x > 0 && u.y > 0 ? -min(u.x, u.y) : simd_length(simd_min(u, V2(0, 0)))
            let hole = min(simd_length(c) - cut.radius, quad)
            // The shader's smooth maximum, which makes the shoulders.
            let soft = min(20, cut.radius * 0.5)
            let h = clamp01(0.5 - 0.5 * (hole + d) / soft)
            d = d + (-hole - d) * h + soft * h * (1 - h)
        }
        return d
    }
}
