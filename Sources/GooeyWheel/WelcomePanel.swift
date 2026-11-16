import AppKit
import AVFoundation
import CoreImage

/// The panel shown the first time the app opens. A soft yellow gradient comes in from its left
/// edge and reaches toward the text, with a video of the wheel in use on it. The right side has
/// two pages: what Gooey Wheel is, then which mouse button opens the wheel.
final class WelcomePanel: NSObject {
    enum Permission { case accessibility, inputMonitoring }

    /// What the button page shows.
    struct ButtonState: Equatable {
        /// The button that opens the wheel, or nil when there's none yet.
        var name: String?
        /// Permissions the page offers to open, which reading a button needs.
        var missing: [Permission] = []
    }

    /// Called with true when the button page comes up and false when it goes.
    var onButtonPage: ((Bool) -> Void)?
    var onAllow: ((Permission) -> Void)?
    /// Called as the panel closes, however it was closed, with the point on screen where it
    /// drew in to a hub, for the wheel to open on.
    var onClose: ((CGPoint) -> Void)?

    private let window: WelcomeWindow
    private let goo: WelcomeGoo
    private let video: LoopingVideoView?
    private let pages: [NSView]
    private let dots = PageDots(count: 2)
    private let buttonPage = ButtonPage()
    private var page = 0
    /// Slows the page turn, for a recording made slower than real time.
    private var turnStretch = 1.0
    /// Counts page turns, so a turn interrupted by the next one doesn't tidy up after itself.
    private var turns = 0
    private var closing = false
    /// The app in front before the panel came up, which gets the focus back when it closes.
    private var previousApp: NSRunningApplication?

    override init() {
        goo = WelcomeGoo(panel: Metrics.card, margin: Metrics.shadowRoom)
        window = WelcomeWindow(contentRect: goo.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        video = Self.videoURL.map(LoopingVideoView.init(url:))
        pages = [IntroPage(), buttonPage]
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        // The goo draws its own shadow.
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.title = "Welcome to Gooey Wheel"
        window.onCancel = { [weak self] in self?.close() }
        window.onReturn = { [weak self] in self?.next() }
        window.contentView = goo
        goo.onBack = { [weak self] in self?.turn(to: 0) }
        goo.onNext = { [weak self] in self?.next() }

        let content = goo.content
        let yellow = YellowGlow(frame: content.bounds)
        content.addSubview(yellow)
        if let video {
            video.frame = Metrics.videoFrame
            yellow.addSubview(video)
        }

        let text = NSView(frame: Metrics.contentFrame)
        content.addSubview(text)
        for (index, view) in pages.enumerated() {
            view.frame = text.bounds
            view.autoresizingMask = [.width, .height]
            view.isHidden = index != 0
            text.addSubview(view)
        }
        buttonPage.onAllow = { [weak self] in self?.onAllow?($0) }

        dots.frame.origin = CGPoint(x: Metrics.contentFrame.minX + Metrics.margin, y: 46)
        content.addSubview(dots)

        let closeButton = NSButton(image: Self.symbol("xmark", size: 11, weight: .bold), target: self, action: #selector(closeClicked))
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.setAccessibilityLabel("Close")
        closeButton.frame = CGRect(x: Metrics.card.width - 48, y: Metrics.card.height - 48, width: 24, height: 24)
        content.addSubview(closeButton)
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = goo.frame.size
        window.setFrameOrigin(CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded()))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(goo)
        goo.start()
        video?.play()
    }

    /// Shows the button page's state. `assigned` marks a button just pressed and assigned.
    func update(_ state: ButtonState, assigned: Bool = false) {
        buttonPage.show(state, assigned: assigned)
    }

    /// Closes the panel by turning it into the wheel: it draws in to a hub, and the wheel
    /// opens on that spot.
    func close() {
        guard window.isVisible, !closing else { return }
        closing = true
        if page == 1 { onButtonPage?(false) }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish(at: CGPoint(x: goo.panelFrame.midX, y: goo.panelFrame.midY), linger: 0)
            return
        }
        goo.onHandoff = { [self] point in finish(at: point, linger: 0.08 * turnStretch) }
        goo.leave()
    }

    /// Hands over to the wheel at a point of the goo view. The panel's hub stays for a few
    /// frames, until the wheel has drawn its own over it.
    private func finish(at point: CGPoint, linger: Double) {
        goo.onHandoff = nil
        video?.pause()
        let onScreen = window.convertPoint(toScreen: goo.convert(point, to: nil))
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
        onClose?(onScreen)
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [self] in
            goo.stop()
            window.orderOut(nil)
        }
    }

    @objc private func closeClicked() { close() }

    /// Continue on the first page, Done on the last.
    private func next() {
        if page == 0 { turn(to: 1) } else { close() }
    }

    /// Turns to the other page a line at a time. The old page's lines slip away in the
    /// direction of travel, top first. The new page's lines follow from the other side on
    /// springs, each a beat after the one above, and settle with a small overshoot.
    private func turn(to index: Int) {
        guard index != page else { return }
        let old = pages[page]
        let new = pages[index]
        let direction: CGFloat = index > page ? 1 : -1
        page = index
        dots.current = index
        goo.backShown = index == 1
        goo.nextMark = index == 1 ? .done : .forward
        onButtonPage?(index == 1)

        turns += 1
        let turn = turns
        let leaving = (old as? WelcomePage)?.lines ?? [old]
        let arriving = (new as? WelcomePage)?.lines ?? [new]
        for line in leaving + arriving { line.layer?.removeAllAnimations() }
        new.isHidden = false

        let stretch = turnStretch
        let now = CACurrentMediaTime()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let gap = reduceMotion ? 0 : 0.03
        for (i, line) in leaving.enumerated() {
            let out = CAAnimationGroup()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 0
            slide.toValue = reduceMotion ? 0 : -direction * 34
            out.animations = [fade, slide]
            out.duration = 0.19 * stretch
            out.beginTime = now + Double(i) * gap * stretch
            out.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.4)
            out.fillMode = .both
            out.isRemovedOnCompletion = false
            line.layer?.add(out, forKey: "turn")
        }
        let lead = 0.13 + Double(leaving.count) * gap * 0.5
        for (i, line) in arriving.enumerated() {
            let begin = now + (lead + Double(i) * (reduceMotion ? 0 : 0.06)) * stretch
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.26 * stretch
            fade.beginTime = begin
            fade.fillMode = .backwards
            line.layer?.add(fade, forKey: "turn.fade")
            guard !reduceMotion else { continue }
            let slide = CASpringAnimation(keyPath: "transform.translation.x")
            slide.fromValue = direction * 52
            slide.toValue = 0
            slide.mass = 1
            slide.stiffness = 210
            slide.damping = 19
            slide.duration = slide.settlingDuration
            slide.speed = Float(1 / stretch)
            slide.beginTime = begin
            slide.fillMode = .backwards
            line.layer?.add(slide, forKey: "turn.slide")
        }
        // Once the old page's lines are gone the page is put away, unless it has come back.
        let gone = (0.19 + Double(leaving.count) * gap + 0.02) * stretch
        DispatchQueue.main.asyncAfter(deadline: .now() + gone) { [weak self] in
            guard let self, turn == self.turns else { return }
            old.isHidden = true
            for line in leaving { line.layer?.removeAllAnimations() }
        }
    }

    #if !APPSTORE
    /// Writes images of both pages into `folder`, from a window kept behind the desktop picture
    /// so nothing shows on screen, for checking how they look.
    func writePreview(to folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.setFrameOrigin(CGPoint(x: 200, y: 200))
        window.orderFrontRegardless()
        goo.start()
        video?.play()
        func capture(_ name: String, after seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            goo.step(0)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-l", String(window.windowNumber), folder + "/" + name + ".png"]
            try? process.run()
            process.waitUntilExit()
        }
        for (index, time) in [0.3, 0.55, 0.3, 0.2, 0.12, 0.12, 0.15, 0.25].enumerated() {
            capture("0-in-\(index)", after: time)
        }
        capture("1-intro", after: 3)
        turn(to: 1)
        update(ButtonState(name: nil, missing: [.accessibility]))
        capture("2-button-permission", after: 0.6)
        update(ButtonState(name: nil))
        capture("3-button-none", after: 0.3)
        update(ButtonState(name: "Thumb Button"), assigned: true)
        capture("4-button-assigned", after: 0.6)
        update(ButtonState(name: "Middle Button", missing: [.inputMonitoring]))
        capture("5-button-input-monitoring", after: 0.3)
    }

    /// Writes the whole panel frame by frame into `folder`, for a video: the way in, a drawn
    /// pointer pressing Continue, a button being assigned, Back, Continue again, and Done.
    /// The window stays behind the desktop picture and the real pointer isn't touched.
    func writeRecording(to folder: String, rate: Double = 30) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.setFrameOrigin(CGPoint(x: 200, y: 200))
        window.orderFrontRegardless()
        // Capturing a frame takes several times as long as the frame lasts, so the page turn,
        // which runs on the clock, is slowed to match.
        turnStretch = 7
        update(ButtonState(name: "Thumb Button"))
        goo.start(manual: true)

        let m = Metrics.shadowRoom
        let next = CGPoint(x: m + Metrics.card.width - 30, y: m + 30)
        let back = CGPoint(x: m + 30, y: m + 30)
        let path: [(Double, CGPoint)] = [
            (0, CGPoint(x: 760, y: 330)), (2.7, CGPoint(x: 760, y: 330)), (3.3, next), (5.9, next),
            (6.6, back), (7.6, back), (8.3, next), (10.4, next),
        ]
        var events: [(Double, () -> Void)] = [
            (3.55, { self.goo.scriptedPress() }), (3.68, { self.goo.scriptedRelease() }),
            (5.0, { self.update(ButtonState(name: "Middle Button"), assigned: true) }),
            (6.85, { self.goo.scriptedPress() }), (6.98, { self.goo.scriptedRelease() }),
            (8.55, { self.goo.scriptedPress() }), (8.68, { self.goo.scriptedRelease() }),
            (10.0, { self.goo.scriptedPress() }), (10.13, { self.goo.scriptedRelease() }),
        ]
        let frames = Int(11.3 * rate)
        for frame in 0...frames {
            let time = Double(frame) / rate
            while let first = events.first, first.0 <= time {
                events.removeFirst()
                first.1()
            }
            let to = path.firstIndex { $0.0 > time } ?? path.count - 1
            let (t0, p0) = path[max(to - 1, 0)]
            let (t1, p1) = path[to]
            let f = CGFloat(t1 > t0 ? smooth01((time - t0) / (t1 - t0)) : 1)
            goo.scriptedCursor = CGPoint(x: p0.x + (p1.x - p0.x) * f, y: p0.y + (p1.y - p0.y) * f)
            goo.step(frame == 0 ? 0 : 1 / rate)
            video?.show(at: time)
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), folder + "/" + String(format: "%04d", frame) + ".png"]
            try? process.run()
            process.waitUntilExit()
        }
    }
    #endif

    /// The video of the wheel in use, in the app's resources, or in the source tree when the
    /// app runs straight from the build folder.
    private static var videoURL: URL? {
        if let url = Bundle.main.url(forResource: "welcome", withExtension: "mov") { return url }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/welcome.mov")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? image
    }
}

// MARK: - Layout

private enum Metrics {
    static let card = CGSize(width: 1000, height: 560)
    /// Room around the panel for the goo's shadow.
    static let shadowRoom: CGFloat = 56
    /// Where the pages start: the gradient takes about 60% of the panel, the text 40%.
    static let contentX: CGFloat = 546
    static let margin: CGFloat = 40

    static var contentFrame: CGRect { CGRect(x: contentX, y: 0, width: card.width - contentX, height: card.height) }
    /// The video, on the widest part of the gradient.
    static var videoFrame: CGRect {
        let side: CGFloat = 384
        return CGRect(x: 60, y: 70, width: side, height: side)
    }
}

private extension NSFont {
    static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }
}

private extension NSColor {
    /// The yellow darkened enough to read on a light panel.
    static let gooeyAmber = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.5, blue: 0, alpha: 1)
    }
}

private final class WelcomeWindow: NSWindow {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        // Return and Enter press the right button.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The yellow: a blurred mesh of warm patches, mostly yellow with deeper and paler areas, with
/// film grain. It's full at the panel's left edge and fades out as it reaches toward the text.
private final class YellowGlow: NSView {
    private struct Patch {
        /// Center and size in points from the panel's bottom-left corner.
        var center: CGPoint
        var size: CGSize
        /// Turned this many degrees counterclockwise.
        var angle: CGFloat = 0
        var color: (r: CGFloat, g: CGFloat, b: CGFloat)
        var opacity: CGFloat
        var blur: CGFloat
    }

    /// Laid over a golden base, in order.
    private static let patches: [Patch] = [
        // Deep amber in the bottom-left corner
        Patch(center: CGPoint(x: 70, y: 90), size: CGSize(width: 440, height: 300), angle: 12, color: (0.97, 0.5, 0.06), opacity: 0.95, blur: 70),
        // Honey down the top-left edge
        Patch(center: CGPoint(x: 20, y: 420), size: CGSize(width: 260, height: 300), color: (0.94, 0.63, 0.1), opacity: 0.8, blur: 60),
        // Peach along the bottom
        Patch(center: CGPoint(x: 340, y: 80), size: CGSize(width: 340, height: 170), angle: -8, color: (0.98, 0.64, 0.5), opacity: 0.7, blur: 60),
        // Pale butter across the top
        Patch(center: CGPoint(x: 290, y: 450), size: CGSize(width: 480, height: 190), angle: -10, color: (1, 0.95, 0.72), opacity: 0.9, blur: 58),
        // Bright lemon where it reaches toward the text
        Patch(center: CGPoint(x: 400, y: 270), size: CGSize(width: 300, height: 260), color: (1, 0.87, 0.12), opacity: 0.9, blur: 55),
        // A pale glint left of center
        Patch(center: CGPoint(x: 190, y: 270), size: CGSize(width: 170, height: 120), angle: 20, color: (1, 0.98, 0.86), opacity: 0.55, blur: 45),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.contents = Self.render(size: frame.size, scale: scale)
        layer?.contentsGravity = .resize
        layer?.contentsScale = scale
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func render(size: CGSize, scale: CGFloat) -> CGImage? {
        // Drawn with a margin all round, so the blur has room and the left edge stays full.
        let pad: CGFloat = 200
        let canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        func painted(blur: CGFloat, _ draw: (CGContext) -> Void) -> CIImage? {
            guard let context = CGContext(
                data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: pad, y: pad)
            draw(context)
            return context.makeImage().map { CIImage(cgImage: $0).applyingGaussianBlur(sigma: blur * scale) }
        }

        // The color, everywhere.
        guard var color = painted(blur: 0, { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0.79, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: -pad, y: -pad, width: canvas.width, height: canvas.height))
        }) else { return nil }
        for patch in patches {
            guard let layer = painted(blur: patch.blur, { context in
                context.translateBy(x: patch.center.x, y: patch.center.y)
                context.rotate(by: patch.angle * .pi / 180)
                let c = patch.color
                context.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: patch.opacity))
                context.fillEllipse(in: CGRect(x: -patch.size.width / 2, y: -patch.size.height / 2, width: patch.size.width, height: patch.size.height))
            }) else { continue }
            color = layer.composited(over: color)
        }

        // Where it shows: a strip down the left edge, reaching a little further at mid-height.
        guard let coverage = painted(blur: 75, { context in
            context.setFillColor(.black)
            context.fill(CGRect(x: -pad, y: -pad, width: pad + 90, height: size.height + pad * 2))
            context.fillEllipse(in: CGRect(x: -140, y: 70, width: 520, height: 420))
        }) else { return nil }
        let extent = CGRect(origin: .zero, size: CGSize(width: canvas.width * scale, height: canvas.height * scale))
        let image = color.cropped(to: extent).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: coverage,
        ])

        let crop = CGRect(x: pad * scale, y: pad * scale, width: size.width * scale, height: size.height * scale)
        guard let smooth = CIContext(options: [.workingColorSpace: space]).createCGImage(image, from: crop, format: .RGBA8, colorSpace: space) else { return nil }
        return grained(smooth, space: space)
    }

    /// Film grain: light and dark specks of up to `strength` opacity, only where there's color.
    private static func grained(_ image: CGImage, space: CGColorSpace, strength: Double = 0.09) -> CGImage? {
        let width = image.width, height = image.height
        var specks = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<(width * height) {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let alpha = UInt8(Double(state & 0xFF) * strength)
            let light = state & 0x100 != 0
            specks[i * 4] = light ? alpha : 0
            specks[i * 4 + 1] = light ? alpha : 0
            specks[i * 4 + 2] = light ? alpha : 0
            specks[i * 4 + 3] = alpha
        }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let noise = specks.withUnsafeMutableBytes({ bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)?.makeImage()
        }), let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        context.setBlendMode(.sourceAtop)
        context.draw(noise, in: rect)
        return context.makeImage()
    }
}

/// Plays a video with no sound over and over. Its background can be transparent.
private final class LoopingVideoView: NSView {
    private let player = AVQueuePlayer()
    private let looper: AVPlayerLooper

    init(url: URL) {
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        super.init(frame: .zero)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("A cursor using Gooey Wheel")
    }

    required init?(coder: NSCoder) { fatalError() }

    func play() { player.play() }

    /// Holds the video at a moment of its loop, for a recording made frame by frame.
    func show(at seconds: Double) {
        player.pause()
        guard let item = player.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 else { return }
        let time = CMTime(seconds: seconds.truncatingRemainder(dividingBy: item.duration.seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func pause() { player.pause() }
}

// MARK: - Controls

/// Which of the pages is showing, as dots; the current one is drawn longer.
private final class PageDots: NSView {
    private let dots: [CALayer]
    var current = 0 { didSet { needsDisplay = true } }

    init(count: Int) {
        dots = (0..<count).map { _ in CALayer() }
        super.init(frame: CGRect(x: 0, y: 0, width: 40, height: 7))
        wantsLayer = true
        for dot in dots { layer?.addSublayer(dot) }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        var x: CGFloat = 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, dot) in dots.enumerated() {
                let width: CGFloat = index == current ? 20 : 7
                dot.frame = CGRect(x: x, y: 0, width: width, height: 7)
                dot.cornerRadius = 3.5
                dot.backgroundColor = (index == current ? NSColor.labelColor : NSColor.tertiaryLabelColor).cgColor
                x += width + 6
            }
        }
    }
}

// MARK: - Pages

private func heading(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .rounded(29, weight: .bold)
    label.textColor = .labelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setAccessibilityRole(.staticText)
    return label
}

/// A page whose lines turn one at a time.
private protocol WelcomePage {
    var lines: [NSView] { get }
}

/// What Gooey Wheel is, with a few points.
private final class IntroPage: NSView, WelcomePage {
    private(set) var lines: [NSView] = []

    private static let points: [(symbol: String, text: String)] = [
        ("circle.hexagongrid.fill", "Gooey is an open-source mouse-activated action wheel overlay."),
        ("computermouse.fill", "It works with every mouse across every brand and gives haptic feedback on supported ones."),
        ("cursorarrow.click.2", "Right-click to customize with actions from color picking to shell commands."),
        ("folder.fill", "Add up to 8 items, plus even more in folders."),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = heading("Welcome to Gooey Wheel!")

        let rows = Self.points.map { Self.row(symbol: $0.symbol, text: $0.text) }
        lines = [title] + rows
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 15

        let stack = NSStackView(views: [title, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.setCustomSpacing(26, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let m = Metrics.margin
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 70),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func row(symbol: String, text: String) -> NSView {
        let icon = NSImageView(image: WelcomePanel.symbol(symbol, size: 14, weight: .semibold))
        icon.contentTintColor = .gooeyAmber
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.centerYAnchor.constraint(equalTo: label.topAnchor, constant: 9),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            label.widthAnchor.constraint(equalToConstant: Metrics.contentFrame.width - Metrics.margin * 2 - 34),
        ])
        return row
    }
}

/// Which mouse button opens the wheel: the one assigned, which a press of another replaces.
private final class ButtonPage: NSView, WelcomePage {
    /// The lines showing now. The permission links come and go.
    var lines: [NSView] { allLines.filter { !$0.isHidden } }
    private var allLines: [NSView] = []
    var onAllow: ((WelcomePanel.Permission) -> Void)?

    private let mouse = NSImageView(image: WelcomePanel.symbol("computermouse.fill", size: 20, weight: .semibold))
    private let name = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let allowAccessibility = LinkButton("Allow Accessibility")
    private let allowInputMonitoring = LinkButton("Allow Input Monitoring")
    private var shown: WelcomePanel.ButtonState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = heading("Which button should activate Gooey?")

        mouse.contentTintColor = .gooeyAmber
        name.font = .rounded(22, weight: .semibold)
        caption.font = .systemFont(ofSize: 14)
        caption.textColor = .secondaryLabelColor
        caption.stringValue = "Press another button to change it."
        allowAccessibility.target = self
        allowAccessibility.action = #selector(allowAccessibilityClicked)
        allowInputMonitoring.target = self
        allowInputMonitoring.action = #selector(allowInputMonitoringClicked)

        let current = NSStackView(views: [mouse, name])
        allLines = [title, current, caption, allowAccessibility, allowInputMonitoring]
        current.spacing = 10
        let stack = NSStackView(views: [title, current, caption, allowAccessibility, allowInputMonitoring])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(30, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let m = Metrics.margin
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 70),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        show(WelcomePanel.ButtonState(), assigned: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: WelcomePanel.ButtonState, assigned: Bool) {
        guard state != shown || assigned else { return }
        shown = state
        name.stringValue = state.name ?? "Press a mouse button"
        name.textColor = state.name == nil ? .secondaryLabelColor : .labelColor
        caption.isHidden = state.name == nil
        allowAccessibility.isHidden = !state.missing.contains(.accessibility)
        allowInputMonitoring.isHidden = !state.missing.contains(.inputMonitoring)
        if assigned {
            mouse.addSymbolEffect(.bounce)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    @objc private func allowAccessibilityClicked() { onAllow?(.accessibility) }
    @objc private func allowInputMonitoringClicked() { onAllow?(.inputMonitoring) }
}

/// A plain text button in the amber, with an arrow after it.
private final class LinkButton: NSButton {
    init(_ title: String) {
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: title + " →", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.gooeyAmber,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
