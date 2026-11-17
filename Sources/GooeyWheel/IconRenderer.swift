import AppKit
import simd

/// Renders the layers of the app icon, `assets/AppIcon.icon`, with the same shader the wheel
/// uses. `bubbles.png` holds the seven bubbles, and `droplet.png` the hub joined by its neck to
/// the selected bubble. Icon Composer adds the glass and the colors: the droplet is one shape
/// filled with a gradient from white to yellow along the neck, since two glass layers meeting in
/// the neck would each draw an edge there. The gradient's ends in icon.json sit on the neck, at
/// 45 degrees up and to the right of the center.
enum IconRenderer {
    static func writeLayers(to directory: String) -> Bool {
        guard let renderer = GooRenderer() else { return false }
        let side = 1024
        // Lay the wheel out in a 400-point square and scale it up to fill the icon's canvas.
        let points = 400.0
        let center = V2(points / 2, points / 2)
        let ring = 108.0
        let selected = 1

        var droplet = [Blob(center: center, half: V2(27, 27), corner: 27, tint: 0)]
        var bubbles: [Blob] = []
        for i in 0..<8 {
            let a = -Double.pi / 2 + Double(i) * .pi / 4
            let r = i == selected ? 35.0 : 29.0
            let blob = Blob(center: center + ring * V2(cos(a), sin(a)), half: V2(r, r), corner: r, tint: 0)
            if i == selected { droplet.append(blob) } else { bubbles.append(blob) }
        }
        let a = -Double.pi / 4
        droplet.append(Blob(center: center + 44 * V2(cos(a), sin(a)), half: V2(11, 11), corner: 11, tint: 0))
        droplet.append(Blob(center: center + 62 * V2(cos(a), sin(a)), half: V2(9, 9), corner: 9, tint: 0))

        // Flat white, with no shading or shadow, so each layer is only its shape.
        var style = GooStyle.resolve(dark: false, accent: .white)
        style.neutral = SIMD3(1, 1, 1)
        style.strokeAlpha = 0
        style.highlight = 0
        style.shade = 0
        style.shadowAlpha = 0
        style.contactAlpha = 0
        style.gooReach = 13
        for (name, blobs) in [("bubbles", bubbles), ("droplet", droplet)] {
            guard let image = renderer.image(blobs: blobs, origin: V2(0, 0), pointSize: points, scale: Double(side) / points, style: style),
                  write(image, to: "\(directory)/\(name).png") else { return false }
        }
        return true
    }

    private static func write(_ image: CGImage, to path: String) -> Bool {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
