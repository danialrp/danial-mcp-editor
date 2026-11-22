import CoreVideo
import EditorCore
import Foundation
@testable import MediaEngine
import Testing

/// Every colour slider moved one step at a time over its whole range and
/// rendered through the real shader, as a person dragging it would see it.
/// The picture is a fine grey ramp (256 tones) and rows of strong and soft
/// colours. At every step the properties a real editor keeps are checked:
/// nothing changes at 0, the tone order is never reversed, one step never
/// jumps, the picture moves in the slider's direction and only by its job.
enum Sweep {
    static let width = 256, rowH = 4
    /// Row 0 grey ramp; rows 1-8 the band hues strong; 9-16 soft; 17 skin.
    static let rows = 18
    static let height = rows * rowH

    static func pixel(_ x: Int, _ y: Int) -> RGB {
        let r = y / rowH, t = Double(x) / 255
        switch r {
        case 0: return RGB(repeating: t)
        case 1...8: return Chart.hsv(HSLBand.allCases[r - 1].hue / 360, 0.9, 0.15 + 0.8 * t)
        case 9...16: return Chart.hsv(HSLBand.allCases[r - 9].hue / 360, 0.35, 0.15 + 0.8 * t)
        default: return Chart.skin * (0.3 + 0.9 * t)
        }
    }

    static func render(_ look: Look?) async throws -> Picture {
        try await LookRender.render(look, width: width, height: height, pixel: pixel)
    }

    /// The grey ramp, read from the middle line of its row.
    static func ramp(_ p: Picture) -> [Double] { (0..<width).map { Chart.luma(p.at($0, rowH / 2)) } }
    static func row(_ p: Picture, _ r: Int) -> [RGB] { (0..<width).map { p.at($0, r * rowH + rowH / 2) } }

    /// The first grey that comes out darker than a darker grey before it
    /// (beyond half-float rounding), or nil when the order is kept.
    static func reversal(_ g: [Double]) -> Int? {
        var top = -1.0
        for (x, v) in g.enumerated() {
            if v < top - 0.0015 { return x }
            top = max(top, v)
        }
        return nil
    }
}

@Suite("Colour sliders swept step by step", .serialized)
struct LookSweepTests {
    static let tone = ["exposure", "highlights", "shadows", "contrast", "brightness", "whites", "blacks"]

    /// The most one whole step of a slider may move any pixel: 4 levels of
    /// 255, at a hard edge or a fully saturated colour. Four steps from 0
    /// may move it at most 5 levels: a fine touch, never a new picture.
    static let maxStep = 4.0 / 255
    static let maxFirstSteps = 5.0 / 255

    /// Values a drag passes through: every whole step.
    static func steps(_ name: String) -> [Double] {
        let r = Look.sliders.first { $0.name == name }!.range
        return stride(from: r.lowerBound, through: r.upperBound, by: 1).map { $0 }
    }

    @Test(arguments: Look.sliders.map(\.name))
    func sweep(_ name: String) async throws {
        let neutral = try await Sweep.render(nil)
        let zero = try await Sweep.render(LookRender.slider(name, 0))
        var worstZero = 0.0
        for i in zero.px.indices { let d = zero.px[i] - neutral.px[i]; worstZero = max(worstZero, abs(d.x), abs(d.y), abs(d.z)) }
        #expect(worstZero <= same, "\(name) at 0 changes the picture by \(worstZero)")

        let random = name == "grain"
        // A few steps from 0 are a fine touch, never a different picture.
        for v in [4.0, -4.0] where Look.sliders.first(where: { $0.name == name })!.range.contains(v) && !random {
            let p = try await Sweep.render(LookRender.slider(name, v))
            var d = 0.0
            for i in p.px.indices { let e = p.px[i] - neutral.px[i]; d = max(d, abs(e.x), abs(e.y), abs(e.z)) }
            #expect(d <= Self.maxFirstSteps, "\(name) \(Int(v)) already moves a pixel by \(Int((d * 255).rounded())) levels")
        }
        var previous: Picture?
        var problems: [String] = []
        for v in Self.steps(name) {
            let p = try await Sweep.render(LookRender.slider(name, v))
            for c in p.px where !(c.x.isFinite && c.y.isFinite && c.z.isFinite) { problems.append("\(name) \(v): not a number"); break }
            // Tone order: a brighter grey never comes out darker.
            if Self.tone.contains(name) || ["saturation", "vibrance", "fade", "temperature", "tint"].contains(name) {
                if let x = Sweep.reversal(Sweep.ramp(p)) { problems.append("\(name) \(Int(v)): tone order reversed at grey \(x)") }
            }
            // One step of the slider is a small change, never a jump.
            if let q = previous, !random {
                var jump = 0.0
                for i in p.px.indices { let d = p.px[i] - q.px[i]; jump = max(jump, abs(d.x), abs(d.y), abs(d.z)) }
                if jump > Self.maxStep { problems.append("\(name) \(Int(v)): one step moves a pixel by \(String(format: "%.3f", jump))") }
            }
            previous = p
        }
        #expect(problems.isEmpty, "\(problems.prefix(12).joined(separator: "\n"))")
    }

    /// Each value against the neutral picture: the move goes the slider's way
    /// and grows with it (monotonic in the slider), grey stays grey.
    @Test(arguments: tone + ["temperature", "tint", "saturation", "vibrance", "fade"])
    func direction(_ name: String) async throws {
        let base = Sweep.ramp(try await Sweep.render(nil))
        var last: [Double]?
        var problems: [String] = []
        for half in [Self.steps(name).filter { $0 >= 0 }, Self.steps(name).filter { $0 <= 0 }.reversed()] {
        last = nil
        for v in half {
            let p = try await Sweep.render(LookRender.slider(name, v))
            let g = Sweep.ramp(p)
            // Grey stays neutral for every slider except white balance.
            if !["temperature", "tint"].contains(name) {
                for x in stride(from: 8, to: 256, by: 8) {
                    let c = p.at(x, 2)
                    if c.max() - c.min() > 0.01 { problems.append("\(name) \(Int(v)): grey \(x) gets a colour \(c)"); break }
                }
            }
            if let last, Self.tone.contains(name) {
                // As the slider goes up, no tone goes the other way.
                for x in 0..<256 where abs(g[x] - base[x]) + 0.003 < abs(last[x] - base[x]) {
                    problems.append("\(name) \(Int(v)): grey \(x) moves back (\(last[x]) to \(g[x]))"); break
                }
            }
            last = g
        }
        }
        #expect(problems.isEmpty, "\(problems.prefix(12).joined(separator: "\n"))")
    }

    /// Exposure: a gain in light. Black stays black, colours keep their hue
    /// while they are not clipped, and the ramp stays in order.
    @Test(arguments: [-100.0, -50.0, -10.0, 10.0, 50.0, 100.0])
    func exposureKeepsHue(_ v: Double) async throws {
        let n = try await Sweep.render(nil), p = try await Sweep.render(LookRender.slider("exposure", v))
        var problems: [String] = []
        for r in 1...16 {
            let a = Sweep.row(n, r), b = Sweep.row(p, r)
            for x in stride(from: 0, to: 256, by: 8) where b[x].max() - b[x].min() > 0.06 {
                let dh = abs(Chart.hue(a[x]) - Chart.hue(b[x])); let d = min(dh, 360 - dh)
                if d > 5 { problems.append("row \(r) x \(x): hue \(Chart.hue(a[x])) to \(Chart.hue(b[x]))"); break }
            }
        }
        #expect(abs(Sweep.ramp(p)[0]) < same)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Two tone sliders at their ends together still keep the tone order:
    /// the case single-slider sweeps miss.
    @Test(arguments: [("highlights", "whites"), ("shadows", "blacks"), ("highlights", "shadows"), ("whites", "blacks"),
                      ("exposure", "highlights"), ("exposure", "whites"), ("contrast", "brightness")])
    func pairsKeepToneOrder(_ pair: (String, String)) async throws {
        var problems: [String] = []
        for a in [-100.0, 100.0] {
            for b in [-100.0, 100.0] {
                let p = try await Sweep.render(LookRender.look { $0[slider: pair.0] = a; $0[slider: pair.1] = b })
                if let x = Sweep.reversal(Sweep.ramp(p)) { problems.append("\(pair.0) \(Int(a)) + \(pair.1) \(Int(b)): reversed at grey \(x)") }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// The tone controls change light, not colour: on every colour row the
    /// hue stays, and a colour keeps most of its strength (no grey veil).
    @Test(arguments: ["highlights", "shadows", "whites", "blacks", "brightness", "contrast", "exposure", "clarity"])
    func toneKeepsColour(_ name: String) async throws {
        let n = try await Sweep.render(nil)
        var problems: [String] = []
        for v in [-100.0, -50.0, 50.0, 100.0] {
            let p = try await Sweep.render(LookRender.slider(name, v))
            for r in 1...17 {
                let a = Sweep.row(n, r), b = Sweep.row(p, r)
                for x in stride(from: 4, to: 256, by: 12) {
                    guard Chart.saturation(a[x]) > 0.2, b[x].max() > 0.08, b[x].max() < 0.97 else { continue }
                    let dh = abs(Chart.hue(a[x]) - Chart.hue(b[x])), d = min(dh, 360 - dh)
                    if d > 5 { problems.append("\(name) \(Int(v)) row \(r) x \(x): hue \(Int(Chart.hue(a[x]))) to \(Int(Chart.hue(b[x])))"); break }
                    if Chart.saturation(b[x]) < Chart.saturation(a[x]) * 0.7 {
                        problems.append("\(name) \(Int(v)) row \(r) x \(x): colour fades \(Chart.saturation(a[x])) to \(Chart.saturation(b[x]))"); break
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(12).joined(separator: "\n"))")
    }

    /// At its ends every control is plainly visible where it works: the
    /// mean change over its own tones, colours or area.
    @Test(arguments: [("exposure", 0.05, 0.95, 0.12), ("highlights", 0.55, 0.95, 0.04), ("shadows", 0.05, 0.45, 0.04),
                      ("whites", 0.75, 1.0, 0.025), ("blacks", 0.0, 0.2, 0.03), ("brightness", 0.2, 0.8, 0.06),
                      ("contrast", 0.05, 0.35, 0.04), ("contrast", 0.65, 0.95, 0.04)])
    func visibleAtTheEnds(_ c: (String, Double, Double, Double)) async throws {
        let base = Sweep.ramp(try await Sweep.render(nil))
        for v in [-100.0, 100.0] {
            let g = Sweep.ramp(try await Sweep.render(LookRender.slider(c.0, v)))
            let xs = (0..<256).filter { Double($0) / 255 >= c.1 && Double($0) / 255 <= c.2 }
            let mean = xs.map { abs(g[$0] - base[$0]) }.reduce(0, +) / Double(xs.count)
            #expect(mean > c.3, "\(c.0) \(Int(v)) moves tones \(c.1)-\(c.2) by \(mean) only")
        }
    }

    @Test func whiteBalanceAndVibranceVisible() async throws {
        let n = try await Sweep.render(nil)
        let grey = n.at(160, 2)
        for v in [-100.0, 100.0] {
            let t = try await Sweep.render(LookRender.slider("temperature", v)).at(160, 2)
            #expect(abs((t.x - t.z) - (grey.x - grey.z)) > 0.15, "temperature \(Int(v)) turns mid grey: \(t)")
            let i = try await Sweep.render(LookRender.slider("tint", v)).at(160, 2)
            #expect(abs(i.y - grey.y) > 0.06, "tint \(Int(v)) moves green: \(i)")
        }
        let p = try await Sweep.render(LookRender.slider("vibrance", 100))
        var soft = 0.0, strong = 0.0
        for r in 1...8 {
            strong += Chart.saturation(Sweep.row(p, r)[160]) - Chart.saturation(Sweep.row(n, r)[160])
            soft += Chart.saturation(Sweep.row(p, r + 8)[160]) - Chart.saturation(Sweep.row(n, r + 8)[160])
        }
        #expect(soft / 8 > 0.15, "vibrance lifts soft colours: \(soft / 8)")
        #expect(strong < soft / 3, "and leaves strong ones mostly alone")
        let m = try await Sweep.render(LookRender.slider("vibrance", -100))
        #expect(Chart.saturation(Sweep.row(m, 9)[160]) < Chart.saturation(Sweep.row(n, 9)[160]) * 0.3, "vibrance -100 takes colour out")
    }

    /// Clarity is a local contrast in the picture's own scale: the same
    /// picture at twice the size gets the same change, not a sharpening.
    @Test func claritySameAtAnySize() async throws {
        func edge(_ scale: Int) -> (Int, Int) -> RGB { { x, _ in RGB(repeating: x / scale < 256 ? 0.35 : 0.65) } }
        var deltas: [Double] = []
        for s in [1, 2, 4] {
            let w = 512 * s
            let n = try await LookRender.render(nil, width: w, height: 8, pixel: edge(s))
            let p = try await LookRender.render(LookRender.slider("clarity", 80), width: w, height: 8, pixel: edge(s))
            // Change 2 picture-units from the edge, in this picture's pixels.
            let x = (256 - 2) * s
            deltas.append(Chart.luma(n.at(x, 4)) - Chart.luma(p.at(x, 4)))
        }
        #expect(deltas.allSatisfy { $0 > 0.005 }, "clarity darkens the dark side near an edge: \(deltas)")
        #expect(abs(deltas[0] - deltas[2]) < max(0.01, deltas[0] * 0.3), "same change at 1x and 4x: \(deltas)")
    }

    /// Every control at once (clarity's 16 extra samples included) on a 4K
    /// frame still fits a 60 fps frame.
    @Test func timedFullLookAt4KFitsAFrame() async throws {
        let (w, h) = (3840, 2160)
        let look = LookRender.look { l in for s in Look.sliders { l[slider: s.name] = s.range.lowerBound < 0 ? 40 : 30 } }
        let pair = Unchecked((LookRender.buffer(w, h, kCVPixelFormatType_32BGRA), LookRender.buffer(w, h, kCVPixelFormatType_64RGBAHalf)))
        let layer = RenderLayer(transform: .identity, opacity: 1, sourceRotation: 0, look: LookUniforms(look))
        func once() async throws {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                RenderGraph.shared.render([(pair.value.0, layer)], into: pair.value.1, hdr: false) { e in
                    if let e { k.resume(throwing: e) } else { k.resume() }
                }
            }
        }
        try await once()
        let n = 30, t0 = Date()
        for _ in 0..<n { try await once() }
        let ms = Date().timeIntervalSince(t0) / Double(n) * 1000
        print(String(format: "[perf] 4K frame with every colour control: %.2f ms", ms))
        #expect(ms < 16.6)
    }
}
