import Foundation
import simd

extension WheelSim {
    /// Every shape in the goo for this frame.
    func blobs() -> [Blob] {
        guard phase != .closed else { return [] }
        let t = tuning
        var out: [Blob] = []
        out.reserveCapacity(64)

        for level in allLevels {
            if level.isControl {
                if let bar = barBlob(level) { out.append(bar) }
                continue
            }
            let hw = max(level.hubHalfW.value, 0)
            let hh = max(level.hubHalfH.value, 0)
            if hw > 0.3, hh > 0.3 {
                // While it holds a label the hub keeps to itself, so a wide label doesn't reach
                // for the bubbles beside it.
                let labeled = level === levels.last ? clamp01(labelMix.value) : 0
                out.append(Blob(
                    center: hubDisplayPosition(level), half: V2(hw, hh), corner: min(hw, hh),
                    tint: clamp01(level.hubTint.value), alpha: clamp01(level.alpha.value), color: level.color?.rgb,
                    firm: 0.35 * labeled
                ))
            }
        }
        for b in bubbles where b.active {
            let r = b.radius.value
            guard r > 0.3 else { continue }
            let level = b.level
            let tint = clamp01(b.tint.value)
            let color = bubbleColor(b)
            // The open folder's dot stays bright in the shrunken ring to mark the path taken.
            let marksPath = level.openKey == b.key
            let alpha = marksPath ? max(clamp01(level.alpha.value), 0.95) : clamp01(level.alpha.value)
            let lift = 0.09 * clamp01(b.lift.value)
            // Out on a ring that is being configured, bubbles keep to themselves: two that
            // come close stay two circles instead of stretching toward each other.
            let firm = staysRound(b) ? clamp01(config.presence.value) : 0
            out.append(Blob(center: displayPosition(b), half: V2(r, r), corner: r, tint: tint, alpha: alpha, color: color, ink: lift, firm: firm))
            // The tail only has size while it trails, so a bubble at rest is a clean circle.
            // A shrunken ring has no tails: they would bridge its dots.
            // While configuring, a bubble that is out on its ring stays round as it slides,
            // is dragged, and settles: a teardrop there would read as a folder.
            let trailing = (level.role == .active || b.leaving) && !staysRound(b)
            let tr = trailing ? r * 0.72 * clamp01(simd_distance(b.tail.value, b.pos.value) / 9) : 0
            if tr > 0.5 {
                out.append(Blob(center: b.tail.value, half: V2(tr, tr), corner: tr, tint: tint, alpha: alpha, color: color))
            }
            // Folders carry a small bud on their outer edge. It swells just before the folder
            // opens. While configuring, every bubble grows one to hold its remove or edit button.
            let br = badgeRadius(b)
            if br > 0.5 {
                out.append(Blob(center: badgeCenter(b), half: V2(br, br), corner: br, tint: tint, alpha: alpha, color: color, ink: lift))
            }
        }
        let dr = dropRadius.value
        if dr > 0.3 {
            out.append(Blob(center: dropPos.value, half: V2(dr, dr), corner: dr, tint: clamp01(dropTint.value), color: dropColor))
        }
        if let tag = tagBlob() { out.append(tag) }
        editorBlobs(into: &out)
        let hp = hintPresence.value
        if hp > 0.02 {
            let s = max(hp, 0)
            let half = V2(hintHalfWidth * s, t.hintHalfHeight * s)
            out.append(Blob(center: hintCenter, half: half, corner: min(half.x, half.y), tint: 0))
        }
        return out
    }

    /// Where the hovered edit option's name goes: just past the bubble, on the side away from
    /// the item, close enough that the goo joins them.
    var tagCenter: V2? {
        guard let key = config.tag.key, let level = levels.last, level.isEdit,
              let b = bubbles.first(where: { $0.level === level && $0.key == key }) else { return nil }
        let t = tuning
        let v = b.pos.value - level.center
        let length = simd_length(v)
        guard length > 1 else { return nil }
        let u = v / length
        let h = t.tagHalfHeight
        let w = max(labelWidth(config.tag.title) / 2 + t.tagPadding, h)
        return b.pos.value + u * (b.radius.value + 5 + h + (w - h) * abs(u.x))
    }

    private func tagBlob() -> Blob? {
        let presence = config.tag.presence.value
        guard presence > 0.03, let center = tagCenter else { return nil }
        let t = tuning
        let s = min(presence, 1.05)
        let w = max(labelWidth(config.tag.title) / 2 + t.tagPadding, t.tagHalfHeight)
        let half = V2(w * s, t.tagHalfHeight * s)
        return Blob(center: center, half: half, corner: min(half.x, half.y), tint: 0)
    }
}
