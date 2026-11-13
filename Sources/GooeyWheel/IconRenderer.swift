import AppKit
import simd

/// Renders the app icon with the same shader the wheel uses: a hub, eight bubbles, and the
/// accent droplet bridging to one of them.
enum IconRenderer {
    static func write(to path: String) -> Bool {
        guard let renderer = GooRenderer() else { return false }
        let side = 1024.0
        // Lay the wheel out in a 400-point square and scale it up to fill the icon.
        let points = 400.0
        let scale = side / points
        let center = V2(points / 2, points / 2)
        let ring = 108.0

        var blobs = [Blob(center: center, half: V2(27, 27), corner: 27, tint: 0)]
        let selected = 1
        for i in 0..<8 {
            let a = -Double.pi / 2 + Double(i) * .pi / 4
            let r = i == selected ? 35.0 : 29.0
            blobs.append(Blob(center: center + ring * V2(cos(a), sin(a)), half: V2(r, r), corner: r, tint: i == selected ? 1 : 0))
        }
        let a = -Double.pi / 4
        blobs.append(Blob(center: center + 44 * V2(cos(a), sin(a)), half: V2(11, 11), corner: 11, tint: 1))
        blobs.append(Blob(center: center + 62 * V2(cos(a), sin(a)), half: V2(9, 9), corner: 9, tint: 1))

        var style = GooStyle.resolve(dark: false, accent: NSColor(srgbRed: 0.33, green: 0.42, blue: 1.0, alpha: 1))
        style.shadowAlpha = 0.34
        style.shadowRadius = 24
        style.gooReach = 13
        guard let goo = renderer.image(blobs: blobs, origin: V2(0, 0), pointSize: points, scale: scale, style: style) else { return false }

        let pixels = Int(side)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        // macOS icon grid: an 824-pixel rounded square centered in the 1024 canvas.
        let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
        context.addPath(shape)
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.13, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        let colors = [
            CGColor(srgbRed: 0.17, green: 0.18, blue: 0.24, alpha: 1),
            CGColor(srgbRed: 0.06, green: 0.06, blue: 0.09, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: plate.maxY), end: CGPoint(x: 512, y: plate.minY), options: [])
        }
        let inset = plate.insetBy(dx: 4, dy: 4)
        context.draw(goo, in: inset)
        context.restoreGState()

        guard let image = context.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
