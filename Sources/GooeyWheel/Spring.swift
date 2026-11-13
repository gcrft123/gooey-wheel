import Foundation
import simd

typealias V2 = SIMD2<Double>

/// Mass is always 1, so a spring is its stiffness and damping, the same pair Gooey's presets use.
struct SpringConfig {
    var k: Double
    var c: Double

    /// Gooey's "bouncy" preset.
    static let bouncy = SpringConfig(k: 320, c: 17)
    /// Gooey's "snappy" preset.
    static let snappy = SpringConfig(k: 480, c: 34)

    static func critical(k: Double) -> SpringConfig {
        SpringConfig(k: k, c: 2 * k.squareRoot())
    }
}

/// Closed-form damped spring. `step` is exact for any `dt`, so motion is identical at 60 and 120 Hz,
/// and retargeting mid-flight keeps the current velocity.
struct Spring {
    var value: Double
    var velocity: Double = 0
    var target: Double
    var config: SpringConfig

    init(_ value: Double, _ config: SpringConfig) {
        self.value = value
        self.target = value
        self.config = config
    }

    mutating func snap(_ v: Double) {
        value = v
        target = v
        velocity = 0
    }

    mutating func step(_ dt: Double) {
        let x0 = value - target
        let v0 = velocity
        let w0 = config.k.squareRoot()
        let zeta = config.c / (2 * w0)

        if zeta < 0.999 {
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let e = exp(-zeta * w0 * dt)
            let cs = cos(wd * dt)
            let sn = sin(wd * dt)
            let b = (v0 + zeta * w0 * x0) / wd
            value = target + e * (x0 * cs + b * sn)
            velocity = e * ((b * wd - zeta * w0 * x0) * cs - (x0 * wd + zeta * w0 * b) * sn)
        } else if zeta <= 1.001 {
            let e = exp(-w0 * dt)
            let b = v0 + w0 * x0
            value = target + e * (x0 + b * dt)
            velocity = e * (v0 - w0 * b * dt)
        } else {
            let r = (zeta * zeta - 1).squareRoot()
            let r1 = -w0 * (zeta - r)
            let r2 = -w0 * (zeta + r)
            let c2 = (v0 - r1 * x0) / (r2 - r1)
            let c1 = x0 - c2
            let e1 = exp(r1 * dt)
            let e2 = exp(r2 * dt)
            value = target + c1 * e1 + c2 * e2
            velocity = c1 * r1 * e1 + c2 * r2 * e2
        }
    }
}

struct Spring2 {
    var x: Spring
    var y: Spring

    init(_ value: V2, _ config: SpringConfig) {
        x = Spring(value.x, config)
        y = Spring(value.y, config)
    }

    var value: V2 { V2(x.value, y.value) }
    var velocity: V2 {
        get { V2(x.velocity, y.velocity) }
        set { x.velocity = newValue.x; y.velocity = newValue.y }
    }
    var target: V2 {
        get { V2(x.target, y.target) }
        set { x.target = newValue.x; y.target = newValue.y }
    }
    var config: SpringConfig {
        get { x.config }
        set { x.config = newValue; y.config = newValue }
    }

    mutating func snap(_ v: V2) {
        x.snap(v.x)
        y.snap(v.y)
    }

    mutating func step(_ dt: Double) {
        x.step(dt)
        y.step(dt)
    }
}

@inline(__always) func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

@inline(__always) func smooth01(_ x: Double) -> Double {
    let t = clamp01(x)
    return t * t * (3 - 2 * t)
}

func clampLength(_ v: V2, _ maxLength: Double) -> V2 {
    let l = simd_length(v)
    return l > maxLength && l > 0 ? v * (maxLength / l) : v
}

/// Wraps an angle to (-π, π].
func wrapAngle(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r > .pi { r -= 2 * .pi }
    if r <= -.pi { r += 2 * .pi }
    return r
}
