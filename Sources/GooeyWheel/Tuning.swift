import Foundation
import simd

/// What the parent ring does while one of its folders is open.
enum ParentStyle: String {
    /// It shrinks and dims in place, and hovering it goes back.
    case shrink
    /// It disappears.
    case hide
}

struct Tuning {
    var ringRadius = 108.0
    var bubbleRadius = 30.0
    var hoverRadius = 35.5
    var hubRadius = 26.0
    var pillHalfHeight = 16.0
    var pillPadding = 14.0
    /// The cursor has to leave this radius to start hovering, and come back inside the smaller one to stop.
    var deadZoneEnter = 25.0
    var deadZoneExit = 19.0
    /// Pointing back at the parent ring only counts this far from a folder's hub. A folder opens
    /// with the cursor already on its inner side, and that shouldn't read as heading back.
    var backZoneEnter = 44.0
    var backZoneExit = 38.0
    /// Past this distance a sticky wheel treats the cursor as outside.
    var outerLimit = 235.0
    /// A press shorter than this pins the wheel open. A longer one closes it on release.
    var pinTapDuration = 0.4
    var dropRadius = 11.0
    var stagger = 0.016
    var hintOffset = 190.0
    var hintHalfHeight = 14.0

    // Folders
    /// Size and opacity of a parent ring while its folder is open.
    var parentScale = 0.38
    var parentAlpha = 0.55
    /// Bubbles in a shrunken ring shrink further than the ring does, so they stay separate dots
    /// instead of merging into one shape.
    var parentDotScale = 0.58
    /// A folder's ring spans this arc, facing away from its parent. The rest is the way back.
    var childArc = 244.0 * .pi / 180
    /// Seconds the cursor rests on a folder before it opens, and on the parent ring before it returns.
    var folderDwell = 0.12
    var backDwell = 0.12

    // Springs. Stiffness and damping at mass 1, the same units as Gooey's presets.
    var enterPos = SpringConfig(k: 340, c: 22)
    var retractPos = SpringConfig(k: 700, c: 50)
    var radiusRest = SpringConfig(k: 300, c: 25)
    var radiusHover = SpringConfig(k: 520, c: 25)
    var radiusLeave = SpringConfig.critical(k: 900)
    var tint = SpringConfig.critical(k: 700)
    var push = SpringConfig(k: 300, c: 26)
    var hubPos = SpringConfig(k: 300, c: 24)
    var hubSize = SpringConfig(k: 520, c: 30)
    var hubMorph = SpringConfig(k: 400, c: 26)
    /// How loosely each bubble's tail follows it. The lag is what draws a bubble out into a teardrop.
    var tailPos = SpringConfig(k: 1500, c: 42)
    var hubClose = SpringConfig.critical(k: 520)
    var levelScale = SpringConfig.critical(k: 300)
    /// Bubbles of a shrunken ring follow its size closely and without bounce. Any overshoot
    /// makes the small dots merge and separate, which reads as a flash.
    var ghostTrack = SpringConfig.critical(k: 1600)
    var levelAlpha = SpringConfig.critical(k: 400)
    var dropPos = SpringConfig(k: 1300, c: 50)
    var dropSize = SpringConfig(k: 400, c: 26)
    var fade = SpringConfig.critical(k: 900)

    // Configuration
    /// Bubbles slide to a new place on the ring when it gains, loses, or reorders items.
    var respace = SpringConfig(k: 260, c: 24)
    var badge = SpringConfig(k: 520, c: 28)
    /// The remove or edit button on a bubble.
    var badgeRadius = 8.0
    /// The button sits on the bubble's rim, its center this far inside the edge.
    var badgeInset = 4.0
    /// A folder's button sits where its bud is, further out, so a folder keeps its teardrop.
    var folderBadgeOffset = 1.2
    var folderBadgeSocket = 8.5
    /// The button's target is a little larger than it looks, and larger still where it
    /// sticks out past the bubble and can't be confused with it.
    var badgeHitRadius = 11.0
    var badgeHitRadiusOutside = 14.0
    var wobble = SpringConfig.critical(k: 500)
    /// 1 jiggles bubbles while configuring. 0 keeps them still, for the Reduce Motion setting.
    var jiggle = 1.0
    /// Clicking this far past the ring's bubbles counts as outside the wheel.
    var outsideMargin = 18.0
    /// The cursor has to move this far with the button down before a bubble lifts.
    var dragSlop = 4.0
    var dragPos = SpringConfig.critical(k: 3600)
    var dragRadius = 34.0
    var targetRadius = 38.0
    /// How close the dragged bubble's center has to be to another bubble to drop onto it.
    var mergeRadius = 30.0
    /// Seconds a dragged bubble rests on a folder, or on the parent ring, before that ring opens.
    var springLoad = 0.55
    /// A bubble turning into an editing panel, and back.
    var panelPos = SpringConfig(k: 300, c: 28)
    var panelSize = SpringConfig(k: 300, c: 27)
    var panelOpen = SpringConfig.critical(k: 220)
    var tagHalfHeight = 13.0
    var tagPadding = 11.0

    /// Critically damped everywhere and no stagger, for the Reduce Motion setting.
    static var reducedMotion: Tuning {
        var t = Tuning()
        t.stagger = 0
        t.enterPos = .critical(k: 600)
        t.radiusRest = .critical(k: 600)
        t.radiusHover = .critical(k: 600)
        t.push = .critical(k: 600)
        t.hubPos = .critical(k: 600)
        t.hubSize = .critical(k: 600)
        t.hubMorph = .critical(k: 600)
        t.tailPos = .critical(k: 900)
        t.levelScale = .critical(k: 600)
        t.dropPos = .critical(k: 1300)
        t.dropSize = .critical(k: 600)
        t.respace = .critical(k: 500)
        t.badge = .critical(k: 600)
        t.jiggle = 0
        t.panelPos = .critical(k: 500)
        t.panelSize = .critical(k: 500)
        return t
    }
}

/// One rounded box in the goo field. A circle is a box whose corner radius equals its half size.
struct Blob {
    var center: V2
    var half: V2
    var corner: Double
    /// 0 is the neutral fill, 1 is the accent color.
    var tint: Double
    var alpha: Double = 1
    /// The color at full tint. Nil is the system accent.
    var color: SIMD3<Float>? = nil
    /// How far the neutral fill leans toward the glyph color, for small controls that have to
    /// stand out from the bubble they sit on.
    var ink: Double = 0
    /// 0 fuses with shapes nearby. 1 keeps a clean gap to them, for a panel and the buttons
    /// that sit in its corners.
    var firm: Double = 0
    /// A round bite out of a bottom corner, where a button sits: everything within `radius`
    /// of `center`, and everything from there on toward the corner.
    struct Cutout {
        var center: V2
        var radius: Double
    }

    var cutoutLeft: Cutout? = nil
    var cutoutRight: Cutout? = nil
    /// Radius of the bottom corners when it differs from `corner`.
    var cornerBottom: Double? = nil
    var notchInset: Double = 0
    var notchGap: Double = 0
}

enum Palette {
    /// Fill for anything that removes.
    static let danger = SIMD3<Float>(1.0, 0.25, 0.22)
}
