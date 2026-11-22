import CoreVideo
import EditorCore
import Foundation
@testable import MediaEngine
import Testing

/// Each look control is rendered through the real shader on test patterns and
/// checked twice: it does its own job, and it leaves alone what it must not
/// touch. Values are this editor's own scale; only the behaviour is tested.

typealias RGB = SIMD3<Double>

/// A test picture made of 32x32 patches, 16 across and 4 down.
struct Chart {
    static let patch = 32, cols = 16, rows = 4
    static let width = patch * cols, height = patch * rows

    /// Row 0: grey steps 0 to 1. Row 1: the eight band hues, strong then
    /// weak. Row 2: skin, fine checker, coarse checker, flat 0.5.
    static func pixel(_ x: Int, _ y: Int) -> RGB {
        let c = x / patch, r = y / patch
        switch r {
        case 0: return RGB(repeating: Double(c) / 15)
        case 1:
            let hue = HSLBand.allCases[c % 8].hue / 360
            return hsv(hue, c < 8 ? 1 : 0.3, 0.8)
        case 2:
            switch c {
            case 0: return skin
            case 1: return RGB(repeating: (x + y) % 2 == 0 ? 0.4 : 0.6)
            case 2: return RGB(repeating: ((x / 6) + (y / 6)) % 2 == 0 ? 0.4 : 0.6)
            default: return RGB(repeating: 0.5)
            }
        default: return RGB(repeating: 0.5)
        }
    }

    static let skin = RGB(0xC6, 0x8E, 0x6E) / 255

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        let p = { (n: Double) -> Double in
            let k = (n + h * 6).truncatingRemainder(dividingBy: 6)
            return v - v * s * max(0, min(k, 4 - k, 1))
        }
        return RGB(p(5), p(3), p(1))
    }

    static func hue(_ c: RGB) -> Double {
        let mx = c.max(), mn = c.min(), d = mx - mn
        guard d > 1e-6 else { return 0 }
        var h: Double
        if mx == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.y { h = (c.z - c.x) / d + 2 }
        else { h = (c.x - c.y) / d + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    static func saturation(_ c: RGB) -> Double { c.max() > 0 ? (c.max() - c.min()) / c.max() : 0 }
    static func luma(_ c: RGB) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
}

/// A rendered picture.
struct Picture {
    var width: Int, height: Int
    var px: [RGB]

    func at(_ x: Int, _ y: Int) -> RGB { px[y * width + x] }

    /// Mean of the inside of a chart patch (edges left out, so neighbour
    /// sampling at patch borders does not count).
    func patch(_ c: Int, _ r: Int, inset: Int = 8) -> RGB {
        var sum = RGB.zero, n = 0.0
        for y in (r * Chart.patch + inset)..<((r + 1) * Chart.patch - inset) {
            for x in (c * Chart.patch + inset)..<((c + 1) * Chart.patch - inset) { sum += at(x, y); n += 1 }
        }
        return sum / n
    }

    /// Standard deviation of luma inside a chart patch.
    func spread(_ c: Int, _ r: Int, inset: Int = 8) -> Double {
        var v: [Double] = []
        for y in (r * Chart.patch + inset)..<((r + 1) * Chart.patch - inset) {
            for x in (c * Chart.patch + inset)..<((c + 1) * Chart.patch - inset) { v.append(Chart.luma(at(x, y))) }
        }
        let m = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    }
}

enum LookRender {
    static func buffer(_ w: Int, _ h: Int, _ format: OSType) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &pb)
        return pb!
    }

    static func render(_ look: Look?, width: Int = Chart.width, height: Int = Chart.height, seed: Float = 0,
                       effects: [ActiveEffect] = [], transform: Transform = .identity,
                       pixel: (Int, Int) -> RGB = Chart.pixel, hdr: Bool = false, sourceHLG: Bool = false) async throws -> Picture {
        let src = buffer(width, height, kCVPixelFormatType_32BGRA)
        if sourceHLG {
            CVBufferSetAttachment(src, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        }
        CVPixelBufferLockBaseAddress(src, [])
        let row = CVPixelBufferGetBytesPerRow(src)
        let base = CVPixelBufferGetBaseAddress(src)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let c = pixel(x, y), i = y * row + x * 4
                let q = { (v: Double) in UInt8((min(max(v, 0), 1) * 255).rounded()) }
                base[i] = q(c.z); base[i + 1] = q(c.y); base[i + 2] = q(c.x); base[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(src, [])

        let out = buffer(width, height, kCVPixelFormatType_64RGBAHalf)
        let layer = RenderLayer(transform: transform, opacity: 1, sourceRotation: 0, look: look.map(LookUniforms.init) ?? .none, effects: effects)
        let pair = Unchecked((src, out))
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            RenderGraph.shared.render([(pair.value.0, layer)], into: pair.value.1, hdr: hdr, seed: seed) { e in
                if let e { k.resume(throwing: e) } else { k.resume() }
            }
        }

        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let orow = CVPixelBufferGetBytesPerRow(out) / 2
        let o = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: Float16.self)
        var px: [RGB] = []
        px.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * orow + x * 4
                px.append(RGB(Double(o[i]), Double(o[i + 1]), Double(o[i + 2])))
            }
        }
        return Picture(width: width, height: height, px: px)
    }

    static func look(_ edit: (inout Look) -> Void) -> Look {
        var l = Look(id: EntityID("look_t"), name: "t")
        edit(&l)
        return l
    }

    static func slider(_ name: String, _ value: Double) -> Look { look { $0[slider: name] = value } }
}

let same = 0.006   // two renders count as equal within this (8-bit source, half float output)

func close(_ a: RGB, _ b: RGB, _ tol: Double = same) -> Bool { let d = a - b; return max(abs(d.x), abs(d.y), abs(d.z)) <= tol }
func greys(_ p: Picture) -> [Double] { (0..<16).map { p.patch($0, 0).x } }

@Suite("Look controls, rendered", .serialized)
struct LookRenderTests {
    let neutral: Picture

    init() async throws { neutral = try await LookRender.render(nil) }

    @Test func zeroLookChangesNothing() async throws {
        let p = try await LookRender.render(LookRender.look { _ in })
        for i in p.px.indices { #expect(close(p.px[i], neutral.px[i]), "pixel \(i)") ; if !close(p.px[i], neutral.px[i]) { break } }
        // and the chart arrives as drawn
        #expect(close(neutral.patch(5, 0), RGB(repeating: 5.0 / 15), 0.004))
    }

    @Test func disabledLookChangesNothing() async throws {
        let p = try await LookRender.render(LookRender.look { $0.exposure = 80; $0.vignette = 100; $0.enabled = false })
        #expect(p.px == neutral.px)
    }

    @Test(arguments: [40.0, -40.0]) func exposure(_ v: Double) async throws {
        let p = try await LookRender.render(LookRender.slider("exposure", v))
        let a = greys(neutral), b = greys(p)
        #expect(abs(b[0]) < same, "black stays black")
        for i in 1..<16 { #expect(v > 0 ? b[i] > a[i] + 0.005 || (a[i] > 0.98 && b[i] > 0.99) : b[i] < a[i] - 0.005, "grey step \(i)") }
        for i in 1..<16 { #expect(b[i] >= b[i - 1], "order of tones kept") }
        for c in 0..<8 where Chart.saturation(p.patch(c, 1)) > 0.1 {
            #expect(abs(Chart.hue(p.patch(c, 1)) - Chart.hue(neutral.patch(c, 1))) < 2, "hue of band \(c) kept")
        }
        #expect(Chart.saturation(p.patch(3, 0)) < 0.01, "grey stays grey")
    }

    @Test(arguments: [50.0, -50.0]) func brightness(_ v: Double) async throws {
        let p = try await LookRender.render(LookRender.slider("brightness", v))
        let a = greys(neutral), b = greys(p)
        #expect(abs(b[0] - a[0]) < same && abs(b[15] - a[15]) < same, "black and white stay put")
        #expect(v > 0 ? b[7] > a[7] + 0.03 : b[7] < a[7] - 0.03, "mid tones move")
        for i in 1..<16 { #expect(b[i] >= b[i - 1]) }
    }

    @Test(arguments: [50.0, -50.0]) func contrast(_ v: Double) async throws {
        let p = try await LookRender.render(LookRender.slider("contrast", v))
        let a = greys(neutral), b = greys(p)
        let mid = p.patch(3, 2).x   // flat 0.5
        #expect(abs(mid - 0.5) < same, "middle grey is the pivot")
        #expect(v > 0 ? b[3] < a[3] - 0.02 && b[12] > a[12] + 0.02 : b[3] > a[3] + 0.02 && b[12] < a[12] - 0.02)
        for i in 1..<16 { #expect(b[i] >= b[i - 1]) }
    }

    @Test(arguments: [50.0, -50.0]) func highlights(_ v: Double) async throws {
        let p = try await LookRender.render(LookRender.slider("highlights", v))
        let a = greys(neutral), b = greys(p)
        for i in 0...6 { #expect(abs(b[i] - a[i]) < same, "dark step \(i) untouched") }
        #expect(v > 0 ? b[12] > a[12] + 0.02 : b[12] < a[12] - 0.02, "bright tones move")
    }

    @Test(arguments: [50.0, -50.0]) func shadows(_ v: Double) async throws {
        let p = try await LookRender.render(LookRender.slider("shadows", v))
        let a = greys(neutral), b = greys(p)
        for i in 8...15 { #expect(abs(b[i] - a[i]) < same, "bright step \(i) untouched") }
        #expect(v > 0 ? b[3] > a[3] + 0.015 : b[3] < a[3] - 0.015, "dark tones move")
    }

    @Test(arguments: [60.0, -60.0]) func whites(_ v: Double) async throws {
        let p = try await LookRender.render(LookRender.slider("whites", v))
        let a = greys(neutral), b = greys(p)
        // Whites works on the bright end (from about 55 %), so footage with
        // no clipped highlights still answers to it.
        for i in 0...8 { #expect(abs(b[i] - a[i]) < same, "step \(i) untouched") }
        #expect(v > 0 ? b[15] >= a[15] - same && b[13] > a[13] + 0.015 : b[15] < a[15] - 0.03, "the brightest tones move (white itself stays white)")
        #expect(v > 0 ? b[11] > a[11] + 0.004 : b[11] < a[11] - 0.004, "bright, unclipped tones move too")
    }

    @Test(arguments: [60.0, -60.0]) func blacks(_ v: Double) async throws {
        let p = try await LookRender.render(LookRender.slider("blacks", v))
        let a = greys(neutral), b = greys(p)
        for i in 4...15 { #expect(abs(b[i] - a[i]) < same, "step \(i) untouched") }
        if v > 0 { #expect(b[0] > a[0] + 0.03, "black lifts") } else { #expect(b[2] < a[2] - 0.02, "darkest tones sink") }
    }

    @Test(arguments: [-100.0, 50.0]) func saturation(_ v: Double) async throws {
        let p = try await LookRender.render(LookRender.slider("saturation", v))
        for c in 0..<16 {
            let s0 = Chart.saturation(neutral.patch(c, 1)), s1 = Chart.saturation(p.patch(c, 1))
            if v == -100 { #expect(s1 < 0.02, "colour \(c) turns grey") } else { #expect(s1 > s0 + 0.02 || s1 > 0.97, "colour \(c) gets stronger") }
            #expect(abs(Chart.luma(p.patch(c, 1)) - Chart.luma(neutral.patch(c, 1))) < 0.03, "brightness of colour \(c) kept")
        }
        for i in 0..<16 { #expect(close(p.patch(i, 0), neutral.patch(i, 0)), "grey step \(i) untouched") }
    }

    @Test func vibrance() async throws {
        let p = try await LookRender.render(LookRender.slider("vibrance", 60))
        var weakGain = 0.0, strongGain = 0.0
        for c in 0..<8 {
            strongGain += Chart.saturation(p.patch(c, 1)) - Chart.saturation(neutral.patch(c, 1))
            weakGain += Chart.saturation(p.patch(c + 8, 1)) - Chart.saturation(neutral.patch(c + 8, 1))
        }
        #expect(weakGain > 8 * 0.05, "weak colours get stronger")
        #expect(strongGain < weakGain / 4, "strong colours change much less")
        for i in 0..<16 { #expect(close(p.patch(i, 0), neutral.patch(i, 0)), "grey step \(i) untouched") }
    }

    @Test(arguments: [60.0, -60.0]) func temperature(_ v: Double) async throws {
        let g = try await LookRender.render(LookRender.slider("temperature", v)).patch(10, 0)
        let n = neutral.patch(10, 0)
        if v > 0 { #expect(g.x > n.x + 0.02 && g.z < n.z - 0.02, "warmer: more red, less blue") }
        else { #expect(g.x < n.x - 0.02 && g.z > n.z + 0.02, "cooler: less red, more blue") }
        #expect(abs(g.y - n.y) < same, "green untouched")
    }

    @Test(arguments: [60.0, -60.0]) func tint(_ v: Double) async throws {
        let g = try await LookRender.render(LookRender.slider("tint", v)).patch(10, 0)
        let n = neutral.patch(10, 0)
        if v > 0 { #expect(g.y < n.y - 0.02, "toward magenta: less green") } else { #expect(g.y > n.y + 0.02, "toward green") }
        #expect(abs(g.x - g.z) < 0.01, "red and blue move together")
    }

    /// Every band changed alone: its own colour moves, the other seven band
    /// colours and all greys stay exactly as they were.
    @Test(arguments: HSLBand.allCases) func hslBandTouchesOnlyItsColour(_ band: HSLBand) async throws {
        for adjust in [HSLAdjust(saturation: -100), HSLAdjust(luminance: -60), HSLAdjust(hue: 60)] {
            let p = try await LookRender.render(LookRender.look { $0.hsl[band.rawValue] = adjust })
            for (c, other) in HSLBand.allCases.enumerated() {
                let a = neutral.patch(c, 1), b = p.patch(c, 1)
                if other == band {
                    if adjust.saturation < 0 { #expect(Chart.saturation(b) < 0.05, "\(band) loses its colour") }
                    if adjust.luminance < 0 { #expect(b.max() < a.max() - 0.1, "\(band) gets darker") }
                    if adjust.hue > 0 {
                        let shift = (Chart.hue(b) - Chart.hue(a) + 360).truncatingRemainder(dividingBy: 360)
                        #expect(shift > 10 && shift < 40, "\(band) hue turns forward (\(shift)°)")
                    }
                } else {
                    #expect(close(a, b), "\(adjust) on \(band) leaves \(other) alone")
                }
            }
            for i in 0..<16 { #expect(close(p.patch(i, 0), neutral.patch(i, 0)), "grey step \(i) untouched") }
        }
    }

    @Test func pickedColourTouchesOnlyThatColour() async throws {
        let hex = String(format: "#%02X%02X%02X", 0xC6, 0x8E, 0x6E)
        let p = try await LookRender.render(LookRender.look {
            $0.picked = [PickedColor(id: EntityID("pc_1"), color: hex, range: 20, adjust: HSLAdjust(saturation: -80, luminance: 40))]
        })
        let a = neutral.patch(0, 2), b = p.patch(0, 2)
        #expect(Chart.saturation(b) < Chart.saturation(a) - 0.15, "skin loses colour")
        #expect(b.max() > a.max() + 0.03, "skin gets brighter")
        for c in 2..<8 { #expect(close(neutral.patch(c, 1), p.patch(c, 1)), "band colour \(c) untouched") }
        for i in 0..<16 { #expect(close(p.patch(i, 0), neutral.patch(i, 0)), "grey step \(i) untouched") }
    }

    @Test func fade() async throws {
        let p = try await LookRender.render(LookRender.slider("fade", 100))
        let a = greys(neutral), b = greys(p)
        #expect(b[0] > a[0] + 0.05, "black lifts")
        #expect(b[15] < a[15] - 0.05, "white drops")
        for i in 1..<16 { #expect(b[i] > b[i - 1], "order of tones kept") }
        #expect(Chart.saturation(p.patch(5, 0)) < 0.01, "grey stays grey")
    }

    @Test func vignette() async throws {
        let grey = { (_: Int, _: Int) in RGB(repeating: 0.5) }
        let p = try await LookRender.render(LookRender.slider("vignette", 100), pixel: grey)
        let n = try await LookRender.render(nil, pixel: grey)
        let mid = p.at(Chart.width / 2, Chart.height / 2), corner = p.at(1, 1)
        #expect(close(mid, n.at(Chart.width / 2, Chart.height / 2)), "centre untouched")
        #expect(corner.x < 0.3, "corners darker")
        #expect(Chart.saturation(corner) < 0.01, "no colour cast")
    }

    @Test func grain() async throws {
        let p = try await LookRender.render(LookRender.slider("grain", 100))
        #expect(p.spread(3, 2) > 0.01, "flat area gets grain")
        #expect(abs(Chart.luma(p.patch(3, 2)) - 0.5) < 0.01, "average brightness kept")
        let again = try await LookRender.render(LookRender.slider("grain", 100))
        #expect(again.px == p.px, "same frame, same grain")
        let next = try await LookRender.render(LookRender.slider("grain", 100), seed: 1)
        #expect(next.px != p.px, "next frame, new grain")
    }

    @Test func sharpen() async throws {
        let p = try await LookRender.render(LookRender.slider("sharpen", 60))
        #expect(p.spread(1, 2) > neutral.spread(1, 2) * 1.3, "fine detail gets stronger")
        #expect(close(p.patch(3, 2), neutral.patch(3, 2)) && p.spread(3, 2) < 0.002, "flat area untouched")
        for i in 0..<16 { #expect(close(p.patch(i, 0), neutral.patch(i, 0)), "flat grey step \(i) untouched") }
    }

    @Test func noiseReduction() async throws {
        let p = try await LookRender.render(LookRender.slider("noiseReduction", 80))
        #expect(p.spread(1, 2) < neutral.spread(1, 2) * 0.6, "pixel-level noise is smoothed")
        #expect(close(p.patch(3, 2), neutral.patch(3, 2)) && p.spread(3, 2) < 0.002, "flat area untouched")
        for i in 0..<16 { #expect(close(p.patch(i, 0), neutral.patch(i, 0)), "flat grey step \(i) untouched") }
    }

    @Test(arguments: [60.0, -60.0]) func clarity(_ v: Double) async throws {
        let p = try await LookRender.render(LookRender.slider("clarity", v))
        let s0 = neutral.spread(2, 2), s1 = p.spread(2, 2)
        #expect(v > 0 ? s1 > s0 * 1.15 : s1 < s0 * 0.85, "broad local contrast moves")
        #expect(close(p.patch(3, 2), neutral.patch(3, 2)) && p.spread(3, 2) < 0.002, "flat area untouched")
        for i in 0..<16 { #expect(close(p.patch(i, 0), neutral.patch(i, 0)), "flat grey step \(i) untouched") }
    }
}
