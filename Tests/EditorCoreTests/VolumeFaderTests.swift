import EditorCore
import Testing

/// The volume slider: fine near 0 dB, silent only at the left end, and a
/// position always gives back the gain it was made from.
@Suite("Volume fader")
struct VolumeFaderTests {
    let f = VolumeFader.standard

    @Test func endsAndNeutral() {
        #expect(f.gain(at: 0) == -60)
        #expect(f.gain(at: 1) == 12)
        #expect(f.gain(at: f.position(of: 0)) == 0)
        #expect(f.position(of: 0) > 0.6 && f.position(of: 0) < 0.7, "0 dB sits about two thirds along")
    }

    @Test func roundTripsEveryTenthOfADecibel() {
        for i in -600...120 {
            let g = Double(i) / 10
            let want = abs(g) < f.snap ? 0 : g
            #expect(abs(f.gain(at: f.position(of: g)) - want) < 1e-9, "\(g) dB")
        }
    }

    /// One point of a 150-point slider (the panel's width) near 0 dB moves the
    /// level by well under a decibel, and a third of the travel left of 0 dB
    /// is a clear but not silent drop.
    @Test func fineNearZero() {
        let point = 1.0 / 150
        let z = f.position(of: 0)
        for p in stride(from: z - 0.15, to: 1 - point, by: point) {
            #expect(abs(f.gain(at: p + point) - f.gain(at: p)) <= 0.45, "step at \(p)")
        }
        let third = f.gain(at: z - z / 3)
        #expect(third < -6 && third > -15, "a third of the way down: \(third) dB")
    }

    @Test func neverGoesBackwards() {
        var last = -1000.0
        for i in 0...1000 { let g = f.gain(at: Double(i) / 1000); #expect(g >= last); last = g }
    }

    @Test func aGainAboveTheTopMovesTheTop() {
        let c = f.covering(20)
        #expect(c.top == 20)
        #expect(c.gain(at: c.position(of: 20)) == 20)
        #expect(f.covering(3) == f)
    }
}
