import Foundation

/// How a volume slider's position (0 at the left end, 1 at the right) maps
/// to gain in dB, as on a mixing desk: an audio taper, where the amplitude
/// follows the position to the power `curve`, so every millimetre near 0 dB
/// moves the level by a fraction of a decibel and only the left end of the
/// travel drops towards silence. The slider reaches `top` dB at the right end
/// and holds `floor` dB over the part of the travel below it. Values a
/// command sets outside this range (up to the command's own limits) are
/// still shown; the slider then puts its right end at that value.
public struct VolumeFader: Sendable, Equatable {
    /// Gain at the left end, in dB.
    public var floor: Double
    /// Gain at the right end, in dB.
    public var top: Double
    /// Power of the amplitude curve: 3 is the usual audio taper.
    public var curve: Double
    /// A value this close to 0 dB is 0 dB, so the level as recorded is easy to find again.
    public var snap: Double
    /// Values are rounded to this many dB.
    public var step: Double

    public static let standard = VolumeFader(floor: -60, top: 12, curve: 3, snap: 0.25, step: 0.1)

    public init(floor: Double, top: Double, curve: Double, snap: Double, step: Double) {
        self.floor = floor
        self.top = top
        self.curve = curve
        self.snap = snap
        self.step = step
    }

    /// dB per tenfold change of position.
    private var k: Double { 20 * curve }

    /// The gain at a position, rounded to `step` and snapped to 0 dB.
    public func gain(at position: Double) -> Double {
        let p = min(1, max(0, position))
        let raw = p <= 0 ? floor : max(floor, top + k * log10(p))
        if abs(raw) < snap { return 0 }
        return min(top, max(floor, (raw / step).rounded() * step))
    }

    /// The position of a gain in [floor, top].
    public func position(of gain: Double) -> Double {
        let g = min(top, max(floor, gain))
        let p = pow(10, (g - top) / k)
        let pFloor = pow(10, (floor - top) / k)
        // Below the floor's position the slider holds the floor; the floor itself sits there.
        return g <= floor ? pFloor : p
    }

    /// The fader for a clip whose gain may be above `top`: its right end is then that gain.
    public func covering(_ gain: Double) -> VolumeFader {
        var f = self
        f.top = max(top, gain)
        return f
    }
}
