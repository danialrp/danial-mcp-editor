import EditorCore
import Foundation
import simd

/// A look packed for the shader, in the layout of `LookParams` there:
/// 22 float4 values. All zero means no look.
public struct LookUniforms: Sendable, Equatable {
    var values: [SIMD4<Float>]

    public static let none = LookUniforms(values: Array(repeating: .zero, count: 22))

    public init(values: [SIMD4<Float>]) { self.values = values }

    public init(_ l: Look) {
        func v(_ x: Double) -> Float { Float(x / 100) }
        // Adjust, white balance, fade and vignette answer softly near 0 and more toward the
        // ends (half the slope at 0, one and a half at 100), so a few steps
        // are a fine touch and the whole range is still there.
        func soft(_ x: Double) -> Float { let t = max(-1, min(1, x / 100)); return Float(t * (0.5 + 0.5 * abs(t))) }
        var out: [SIMD4<Float>] = [
            [soft(l.exposure), soft(l.brightness), soft(l.contrast), soft(l.saturation)],
            [soft(l.highlights), soft(l.shadows), soft(l.whites), soft(l.blacks)],
            [soft(l.vibrance), soft(l.clarity), soft(l.temperature), soft(l.tint)],
            [v(l.sharpen), v(l.noiseReduction), soft(l.fade), soft(l.vignette)],
            [v(l.grain), l.enabled ? 1 : 0, 0, 0],
            .zero,   // texel size, filled in per frame
        ]
        for b in HSLBand.allCases {
            let a = l.band(b)
            out.append([v(a.hue), v(a.saturation), v(a.luminance), 0])
        }
        var picks: [SIMD4<Float>] = [], adj: [SIMD4<Float>] = []
        for c in l.picked.prefix(4) {
            guard let (r, g, b) = c.rgb else { continue }
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            var h = 0.0
            if d > 0 {
                if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
                else if mx == g { h = (b - r) / d + 2 }
                else { h = (r - g) / d + 4 }
                h /= 6
                if h < 0 { h += 1 }
            }
            picks.append([Float(h), Float(mx > 0 ? d / mx : 0), Float(mx), Float(c.range / 360)])
            adj.append([v(c.adjust.hue), v(c.adjust.saturation), v(c.adjust.luminance), 1])
        }
        while picks.count < 4 { picks.append(.zero); adj.append(.zero) }
        values = out + picks + adj
    }
}

/// The looks of one built composition, read by the compositor for every
/// frame. A change that only moves colour sliders updates this table in
/// place: the picture follows at once, with no new composition.
public final class LookTable: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [EntityID: LookUniforms] = [:]

    public init(_ looks: [Look] = []) { set(looks) }

    public func set(_ looks: [Look]) {
        let v = Dictionary(uniqueKeysWithValues: looks.map { ($0.id, LookUniforms($0)) })
        lock.withLock { values = v }
    }

    /// The values a look has in this table now (a drag in progress shows
    /// here before the project changes); nil when the table has none.
    public func current(_ id: EntityID) -> LookUniforms? { lock.withLock { values[id] } }

    /// What the shader gets for a look: nothing when it is off or gone.
    func uniforms(_ id: EntityID) -> LookUniforms {
        let u = lock.withLock { values[id] }
        guard let u, u.values[4].y > 0.5 else { return .none }
        return u
    }
}
