import AppKit
import Metal
import QuartzCore
import simd

/// Colors and lighting for the goo, resolved from the system appearance.
struct GooStyle {
    var neutral: SIMD3<Float>
    var accent: SIMD3<Float>
    var stroke: SIMD3<Float>
    var strokeAlpha: Float
    var highlight: Float
    var shade: Float
    var shadowAlpha: Float
    var shadowRadius: Float
    var shadowOffset: SIMD2<Float>
    var contactAlpha: Float
    /// How far apart two shapes still bridge. Higher is stickier.
    var gooReach: Float = 13

    var icon: SIMD3<Float>
    var iconOnAccent: SIMD3<Float>
    var glyphAlpha: Float

    /// The glyph color that reads on a filled bubble. Light fills such as yellow need a dark glyph.
    static func glyphColor(on fill: SIMD3<Float>) -> SIMD3<Float> {
        let luminance = 0.2126 * fill.x + 0.7152 * fill.y + 0.0722 * fill.z
        return luminance > 0.55 ? SIMD3(0.09, 0.09, 0.1) : SIMD3(1, 1, 1)
    }

    static func resolve(dark: Bool, accent: NSColor) -> GooStyle {
        let a = accent.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
        let accentRGB = SIMD3<Float>(Float(a.redComponent), Float(a.greenComponent), Float(a.blueComponent))
        let onAccent = glyphColor(on: accentRGB)
        if dark {
            return GooStyle(
                neutral: SIMD3(0.085, 0.085, 0.095), accent: accentRGB,
                stroke: SIMD3(1, 1, 1), strokeAlpha: 0.13, highlight: 0.16, shade: 0.0,
                shadowAlpha: 0.42, shadowRadius: 30, shadowOffset: SIMD2(0, 9), contactAlpha: 0.3,
                icon: SIMD3(1, 1, 1), iconOnAccent: onAccent, glyphAlpha: 0.5
            )
        }
        return GooStyle(
            neutral: SIMD3(0.985, 0.985, 0.99), accent: accentRGB,
            stroke: SIMD3(0, 0, 0), strokeAlpha: 0.05, highlight: 0.0, shade: 0.045,
            shadowAlpha: 0.2, shadowRadius: 30, shadowOffset: SIMD2(0, 9), contactAlpha: 0.12,
            icon: SIMD3(0.1, 0.1, 0.12), iconOnAccent: onAccent, glyphAlpha: 0.42
        )
    }
}

/// Draws every blob as one signed distance field. Shapes are joined with an exponential smooth
/// minimum, which is what makes them neck, bridge, and pinch off like liquid. Color is blended
/// with the same weights, so tint flows through a bridge.
final class GooRenderer {
    static let maxBlobs = 96

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let headerSize = MemoryLayout<Header>.stride
    private let blobSize = MemoryLayout<GPUBlob>.stride
    private let bufferLength: Int
    private let buffer: UnsafeMutableRawPointer
    private let previous: UnsafeMutableRawPointer
    private var hasPrevious = false

    private struct Header {
        var view: SIMD4<Float>      // origin.xy in points, scale, blob count
        var params: SIMD4<Float>    // goo sharpness, color sharpness, stroke alpha, unused
        var light: SIMD4<Float>     // highlight, shade, shadow alpha, shadow radius
        var shadow: SIMD4<Float>    // offset.xy, contact alpha, unused
        var stroke: SIMD4<Float>    // rgb, unused
    }

    private struct GPUBlob {
        var geom: SIMD4<Float>      // center.xy, half.xy
        var color: SIMD4<Float>     // rgb, corner radius
        var extra: SIMD4<Float>     // opacity, firmness, bottom corner radius
        var cutLeft: SIMD4<Float>   // bottom-left cutout: center.xy, radius
        var cutRight: SIMD4<Float>  // bottom-right cutout: center.xy, radius
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "goo_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "goo_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Goo shader failed to build: \(error)")
            return nil
        }
        bufferLength = headerSize + Self.maxBlobs * blobSize
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferLength, alignment: 16)
        previous = UnsafeMutableRawPointer.allocate(byteCount: bufferLength, alignment: 16)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bufferLength)
        previous.initializeMemory(as: UInt8.self, repeating: 0, count: bufferLength)
    }

    deinit {
        buffer.deallocate()
        previous.deallocate()
    }

    /// Packs the frame and returns the pixel rect that needs shading.
    private func pack(blobs: [Blob], origin: V2, scale: Double, style: GooStyle, pixelSize: (Int, Int)) -> MTLScissorRect {
        let count = min(blobs.count, Self.maxBlobs)
        memset(buffer, 0, bufferLength)
        let k = Float(2 * log(2.0)) / style.gooReach
        let header = Header(
            view: SIMD4(Float(origin.x), Float(origin.y), Float(scale), Float(count)),
            params: SIMD4(k, k * 1.9, style.strokeAlpha, 0),
            light: SIMD4(style.highlight, style.shade, style.shadowAlpha, style.shadowRadius),
            shadow: SIMD4(style.shadowOffset.x, style.shadowOffset.y, style.contactAlpha, 0),
            stroke: SIMD4(style.stroke, 0)
        )
        buffer.storeBytes(of: header, as: Header.self)

        var minP = V2(.infinity, .infinity)
        var maxP = V2(-.infinity, -.infinity)
        for i in 0..<count {
            let b = blobs[i]
            let t = Float(b.tint)
            let base = style.neutral + (style.icon - style.neutral) * Float(b.ink)
            let rgb = base + ((b.color ?? style.accent) - base) * t
            let gpu = GPUBlob(
                geom: SIMD4(Float(b.center.x), Float(b.center.y), Float(b.half.x), Float(b.half.y)),
                color: SIMD4(rgb, Float(b.corner)),
                extra: SIMD4(Float(b.alpha), Float(b.firm), Float(b.cornerBottom ?? b.corner), 0),
                cutLeft: b.cutoutLeft.map { SIMD4(Float($0.center.x), Float($0.center.y), Float($0.radius), 0) } ?? SIMD4(repeating: 0),
                cutRight: b.cutoutRight.map { SIMD4(Float($0.center.x), Float($0.center.y), Float($0.radius), 0) } ?? SIMD4(repeating: 0)
            )
            buffer.storeBytes(of: gpu, toByteOffset: headerSize + i * blobSize, as: GPUBlob.self)
            minP = simd_min(minP, b.center - b.half)
            maxP = simd_max(maxP, b.center + b.half)
        }
        guard count > 0 else { return MTLScissorRect(x: 0, y: 0, width: 1, height: 1) }

        let margin = Double(style.shadowRadius) + Double(simd_length(style.shadowOffset)) + Double(style.gooReach) + 4
        let x0 = max(0, Int(((minP.x - margin - origin.x) * scale).rounded(.down)))
        let y0 = max(0, Int(((minP.y - margin - origin.y) * scale).rounded(.down)))
        let x1 = min(pixelSize.0, Int(((maxP.x + margin - origin.x) * scale).rounded(.up)))
        let y1 = min(pixelSize.1, Int(((maxP.y + margin - origin.y) * scale).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return MTLScissorRect(x: 0, y: 0, width: 1, height: 1) }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func encode(into texture: MTLTexture, scissor: MTLScissorRect) -> MTLCommandBuffer? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setScissorRect(scissor)
        encoder.setFragmentBytes(buffer, length: bufferLength, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return commands
    }

    /// Renders into the layer. Call inside the same CATransaction that moves the icon layers:
    /// the drawable is presented with that transaction, so goo and icons land on the same frame.
    func draw(blobs: [Blob], origin: V2, scale: Double, style: GooStyle, in layer: CAMetalLayer) {
        let size = (Int(layer.drawableSize.width), Int(layer.drawableSize.height))
        guard size.0 > 0, size.1 > 0 else { return }
        let scissor = pack(blobs: blobs, origin: origin, scale: scale, style: style, pixelSize: size)

        // A settled wheel produces identical frames. Skip them.
        if hasPrevious, memcmp(buffer, previous, bufferLength) == 0 { return }

        guard let drawable = layer.nextDrawable(),
              let commands = encode(into: drawable.texture, scissor: scissor) else { return }
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
        memcpy(previous, buffer, bufferLength)
        hasPrevious = true
    }

    func invalidate() {
        hasPrevious = false
    }

    /// Offscreen render of a square, used to produce the app icon.
    func image(blobs: [Blob], origin: V2, pointSize: Double, scale: Double, style: GooStyle) -> CGImage? {
        image(blobs: blobs, origin: origin, size: V2(pointSize, pointSize), scale: scale, style: style)
    }

    /// Offscreen render of any rectangle, also used for the demo's snapshots.
    func image(blobs: [Blob], origin: V2, size: V2, scale: Double, style: GooStyle) -> CGImage? {
        let width = Int(size.x * scale)
        let height = Int(size.y * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let scissor = pack(blobs: blobs, origin: origin, scale: scale, style: style, pixelSize: (width, height))
        guard let commands = encode(into: texture, scissor: scissor) else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        // The next frame drawn to the screen must not be compared with this one.
        hasPrevious = false
        return Self.image(from: texture)
    }

    /// Reads a BGRA texture with premultiplied alpha back as an image.
    static func image(from texture: MTLTexture) -> CGImage? {
        let rowBytes = texture.width * 4
        var data = [UInt8](repeating: 0, count: rowBytes * texture.height)
        texture.getBytes(&data, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Blob {
        float4 geom;   // center.xy, half.xy
        float4 color;  // rgb, corner radius
        float4 extra;  // opacity, firmness, bottom corner radius
        float4 cutLeft;   // bottom-left cutout: center.xy, radius
        float4 cutRight;  // bottom-right cutout: center.xy, radius
    };

    struct Uniforms {
        float4 view;    // origin.xy (points), scale, count
        float4 params;  // k, color k, stroke alpha
        float4 light;   // highlight, shade, shadow alpha, shadow radius
        float4 shadow;  // offset.xy, contact alpha
        float4 stroke;  // rgb
        Blob blobs[96];
    };

    struct VertexOut {
        float4 position [[position]];
    };

    vertex VertexOut goo_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // Rounded box distance with its gradient in yz.
    static inline float3 sd_round_box(float2 p, float2 h, float r) {
        float2 s = float2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
        float2 q = abs(p) - h + r;
        float2 m = max(q, 0.0);
        float lm = length(m);
        float2 g = lm > 0.0 ? m / lm : (q.x > q.y ? float2(1.0, 0.0) : float2(0.0, 1.0));
        return float3(lm + min(max(q.x, q.y), 0.0) - r, s * g);
    }

    // One corner cutout: a disc around the button that sits there, joined to everything
    // beyond it toward the corner. Distance with its gradient in yz.
    static inline float3 sd_cutout(float2 p, float2 center, float radius, float side) {
        float2 q = p - center;
        float len = length(q);
        float3 disc = float3(len - radius, len > 0.0 ? q / len : float2(0.0, -1.0));
        // u is positive on both axes in the quadrant between the button and the corner.
        float2 u = float2(side * q.x, q.y);
        float3 quad = u.x > 0.0 && u.y > 0.0
            ? (u.x < u.y ? float3(-u.x, -side, 0.0) : float3(-u.y, 0.0, -1.0))
            : float3(length(min(u, 0.0)), -q / max(len, 1e-4));
        return disc.x < quad.x ? disc : quad;
    }

    // A blob's distance with its gradient in yz: a rounded box, less its corner cutouts.
    static inline float3 sd_blob(float2 p, Blob b) {
        float2 local = p - b.geom.xy;
        float3 d = sd_round_box(local, b.geom.zw, local.y > 0.0 ? b.extra.z : b.color.w);
        for (int i = 0; i < 2; i++) {
            float4 c = i == 0 ? b.cutLeft : b.cutRight;
            if (c.z < 0.05) continue;
            float3 cut = sd_cutout(p, c.xy, c.z, i == 0 ? -1.0 : 1.0);
            // Smooth maximum: the panel's edge turns into the cutout over a wide, soft
            // shoulder instead of meeting it at a corner.
            float soft = min(20.0, c.z * 0.5);
            float h = clamp(0.5 - 0.5 * (cut.x + d.x) / soft, 0.0, 1.0);
            d = float3(mix(d.x, -cut.x, h) + soft * h * (1.0 - h), mix(d.yz, -cut.yz, h));
        }
        return d;
    }

    fragment float4 goo_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float scale = u.view.z;
        float2 p = in.position.xy / scale + u.view.xy;
        int count = int(u.view.w);
        float k = u.params.x;
        float kc = u.params.y;
        float2 so = u.shadow.xy;

        float acc = 0.0;
        float accShadow = 0.0;
        float2 grad = float2(0.0);
        float3 colorSum = float3(0.0);
        float colorWeight = 0.0;
        float opacitySum = 0.0;
        float shadowOpacitySum = 0.0;
        float shadowWeight = 0.0;

        for (int i = 0; i < count; i++) {
            Blob b = u.blobs[i];
            float3 dg = sd_blob(p, b);
            // A firm blob's field falls off faster outside it, so it doesn't reach for its neighbors.
            float firm = 1.0 + 2.6 * b.extra.y;
            float e = exp(-k * (dg.x > 0.0 ? dg.x * firm : dg.x));
            acc += e;
            grad += e * dg.yz;
            float w = exp(-kc * dg.x);
            colorSum += w * b.color.rgb;
            colorWeight += w;
            opacitySum += w * b.extra.x;
            float ds = sd_blob(p - so, b).x;
            accShadow += exp(-k * ds);
            float ws = exp(-kc * ds);
            shadowOpacitySum += ws * b.extra.x;
            shadowWeight += ws;
        }

        float d = -log(max(acc, 1e-30)) / k;
        float dShadow = -log(max(accShadow, 1e-30)) / k;
        float3 base = colorSum / max(colorWeight, 1e-30);
        // Opacity blends like color, so a dimmed shape fades smoothly into a solid one it touches.
        float opacity = opacitySum / max(colorWeight, 1e-30);
        float shadowOpacity = shadowOpacitySum / max(shadowWeight, 1e-30);
        float2 n = grad / max(length(grad), 1e-6);

        // Coverage, antialiased over one pixel of the field.
        float aa = max(fwidth(d), 1e-4);
        float cover = clamp(0.5 - d / aa, 0.0, 1.0) * opacity;

        // Gel lighting: a soft highlight along upper edges, a little shade along lower ones.
        float depth = max(-d, 0.0);
        float edge = clamp(1.0 - depth / 9.0, 0.0, 1.0);
        edge *= edge;
        float up = clamp(-n.y * 0.92 - n.x * 0.18 + 0.12, 0.0, 1.0);
        float down = clamp(n.y, 0.0, 1.0);
        float3 color = base + u.light.x * edge * up;
        color *= 1.0 - u.light.y * edge * down;

        // Hairline just inside the edge so dark goo separates from dark windows.
        float hair = clamp(1.0 - abs(depth - 0.7) / 0.7, 0.0, 1.0);
        color = mix(color, u.stroke.rgb, u.params.z * hair * (0.55 + 0.45 * up));

        // Shadow from the same field, so it follows every merge and split.
        float soft = clamp(1.0 - dShadow / u.light.w, 0.0, 1.0);
        float shadowA = u.light.z * soft * soft * soft * shadowOpacity;
        float contact = u.shadow.z * clamp(1.0 - d / 3.0, 0.0, 1.0) * opacity;
        shadowA = 1.0 - (1.0 - shadowA) * (1.0 - contact);

        float alpha = cover + shadowA * (1.0 - cover);
        return float4(clamp(color, 0.0, 1.0) * cover, alpha);
    }
    """
}

/// A view whose backing layer is the Metal drawable for the goo.
final class GooView: NSView {
    let metalLayer = CAMetalLayer()

    init(device: MTLDevice) {
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = true
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(scale: CGFloat) {
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}
