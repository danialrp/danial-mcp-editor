import AVFoundation
import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing
import CoreGraphics
import ImageIO

/// The matte maths: time repair and signed distances.
@Suite struct MatteMathTests {
    func disc(_ w: Int, _ h: Int, cx: Double, cy: Double, r: Double) -> BitMask {
        var m = BitMask(width: w, height: h)
        for y in 0..<h { for x in 0..<w where (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy) <= r * r { m[x, y] = true } }
        return m
    }

    @Test func distancesAreExact() {
        let m = disc(70, 50, cx: 30, cy: 22, r: 13)
        var codes = [UInt8](repeating: 0, count: 70 * 50)
        codes.withUnsafeMutableBufferPointer { MatteMath.signedDistance(m, into: $0.baseAddress!, bytesPerRow: 70) }
        var worst: Float = 0
        for y in 0..<50 {
            for x in 0..<70 {
                // Brute force: nearest pixel of the other kind.
                var best = Float.infinity
                for yy in 0..<50 { for xx in 0..<70 where m[xx, yy] != m[x, y] {
                    best = min(best, Float((xx - x) * (xx - x) + (yy - y) * (yy - y)).squareRoot())
                } }
                let want = max(-MatteMath.maxDistance, min(MatteMath.maxDistance, m[x, y] ? best - 0.5 : -(best - 0.5)))
                worst = max(worst, abs(MatteMath.distance(code: codes[y * 70 + x]) - want))
            }
        }
        #expect(worst <= 0.125 + 1e-4, "largest error \(worst) px; codes are a quarter pixel apart")
    }

    /// A long sequence with dropouts and a moving disc.
    func sequence() -> [BitMask] {
        (0..<60).map { i in
            var m = disc(64, 48, cx: 20 + Double(i) * 0.4, cy: 24, r: 10)
            if [17, 18, 40].contains(i) { m = BitMask(width: 64, height: 48) }        // the tracker lost him
            if (25...27).contains(i) { for y in 10..<20 { for x in 40..<50 { m[x, y] = true } } }   // a hand for three frames
            return m
        }
    }

    @Test func repairFillsDropoutsAndKeepsRealMovement() {
        let raw = sequence()
        let (tight, wide) = MatteMath.repair(raw, r: 3, g: 1, range: 0..<raw.count)
        // Frames 17, 18 and 40 are filled back in from both sides.
        for i in [17, 18, 40] { #expect(tight[i].count > raw[16].count * 9 / 10, "frame \(i) not filled") }
        // A frame the tracker got right is not smaller after repair.
        for i in [5, 30, 50] { #expect(MatteMath.iou(tight[i], raw[i]) > 0.95) }
        // Wide is never smaller than tight.
        for i in raw.indices {
            for k in tight[i].words.indices { #expect(tight[i].words[k] & ~wide[i].words[k] == 0) }
        }
        // The hand present for only three frames, with nothing on either side, is not invented elsewhere.
        #expect(!tight[35][45, 15] && !tight[20][45, 15])
    }

    /// A body (left half) whose mask misses a moving finger to its right;
    /// the wall the finger just left must not be taken, nor a moving thing
    /// out of reach, nor still texture.
    @Test func motionFillGivesBackMovingFingersOnly() {
        let w = 80, h = 40, step = 2
        func frame(fingerAt fx: Int, far: Int) -> MatteMath.Luma {
            var v = [UInt8](repeating: 120, count: (w / step) * (h / step))
            for y in 0..<(h / step) { for x in 0..<(w / step) {
                if x < 20 / step { v[y * (w / step) + x] = UInt8(60 + (x * 7 + y * 13) % 9) }                // body, textured, still
                if (fx / step)..<(fx / step + 3) ~= x, (16 / step)..<(24 / step) ~= y { v[y * (w / step) + x] = 30 }  // finger
                if (far / step)..<(far / step + 2) ~= x, (2 / step)..<(6 / step) ~= y { v[y * (w / step) + x] = 250 } // something moving far away
            } }
            return MatteMath.Luma(width: w / step, height: h / step, step: step, values: v)
        }
        var body = BitMask(width: w, height: h)
        for y in 0..<h { for x in 0..<20 { body[x, y] = true } }
        // The finger sweeps right: 14, 20, 26; in the middle frame it touches the body.
        let lumas = [frame(fingerAt: 14, far: 64), frame(fingerAt: 20, far: 70), frame(fingerAt: 26, far: 76)]
        let filled = MatteMath.motionFill([body, body, body], lumas, threshold: 16, reach: 16)
        let m = filled[1]
        #expect(m[22, 20], "the finger touching the body is given back")
        #expect(!m[28, 20], "the wall where it was before and goes next is not")
        #expect(!m[72, 4], "a moving thing out of reach is not")
        #expect(m.count == body.count + 6 * 8, "only the finger is added: \(m.count - body.count) pixels")
        #expect(filled[0] == body && filled[2] == body, "the ends are left as they are")
    }

    @Test func chunksGiveWhatOnePassGives() {
        let raw = sequence()
        let (r, g) = (3, 1)
        let whole = MatteMath.repair(raw, r: r, g: g, range: 0..<raw.count)
        let pad = 2 * r + g
        for (a, b) in [(0, 20), (20, 41), (41, 60)] {
            let lo = max(0, a - pad), hi = min(raw.count, b + pad)
            let part = MatteMath.repair(Array(raw[lo..<hi]), r: r, g: g, range: (a - lo)..<(b - lo))
            #expect(part.tight == Array(whole.tight[a..<b]) && part.wide == Array(whole.wide[a..<b]), "chunk \(a)-\(b)")
        }
    }
}

/// Vision mattes on real footage. Runs only when DME_MATTE_FOOTAGE holds the
/// path of a talking-head video (footage stays out of the repository).
@Suite("Vision matte on footage", .serialized, .enabled(if: ProcessInfo.processInfo.environment["DME_MATTE_FOOTAGE"] != nil))
struct VisionMatteTests {
    @Test func makesAStableMatteAndStoresItFaithfully() async throws {
        let path = ProcessInfo.processInfo.environment["DME_MATTE_FOOTAGE"]!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-matte-\(UUID().uuidString)")
        let store = try UserSettingsStore(directory: dir)
        let info = try await AVMediaProber().probe(URL(fileURLWithPath: path))
        let a = MediaAsset(id: "footage", path: path, name: "footage", fingerprint: "test-\(UUID().uuidString)", info: info, matte: .vision)
        let matte = MatteStore(settings: store)
        let chunks = try await matte.chunks(a, package: nil)
        let t0 = Date()
        let made = try await matte.generate(a, package: nil, only: [0]) { _, _, _ in }
        let seconds = Date().timeIntervalSince(t0)
        #expect(made == [0])
        let c = try #require(try await matte.chunks(a, package: nil).first)
        let url = try #require(c.current)
        let qa = try #require(MatteStore.qa(url))
        let sorted = qa.iou.sorted()
        print("matte chunk 0 (\(chunks[0].end - chunks[0].start) s, \(qa.times.count) frames) made in \(String(format: "%.1f", seconds)) s; "
              + "IoU min \(sorted.first!) median \(sorted[sorted.count / 2]); file \(try FileManager.default.attributesOfItem(atPath: url.path)[.size]!) bytes")
        #expect(sorted[sorted.count / 2] > 0.98)
        #expect(qa.coverage.allSatisfy { $0 > 0.05 }, "a person is in every frame")

        // Stored distances against freshly computed ones, at a middle frame.
        let k = qa.times.count / 2
        let back = try await MatteStore.readFrame(url, at: qa.times[k] - c.start)
        #expect(back.tight.count == back.width * back.height)
        // The outline is where the distance code crosses 128; inside is > 128.
        let inside = back.tight.filter { $0 > 128 }.count
        #expect(abs(Double(inside) / Double(back.tight.count) - qa.coverage[k]) < 0.01,
                "stored matte covers \(Double(inside) / Double(back.tight.count)), made \(qa.coverage[k])")
        try? FileManager.default.trashItem(at: MatteStore.cacheFolder(a), resultingItemURL: nil)
    }
}

/// The depth layer drawn by the render graph: what sits behind the person
/// is cut by the tight matte, the lit outline fills the band out to the
/// grown wide matte, the front pass covers everything.
@Suite struct DepthRenderTests {
    static let w = 240, h = 240

    static func buffer(_ w: Int, _ h: Int, _ format: OSType) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        return pb!
    }

    /// BGRA filled by a function of (x, y) giving straight RGBA bytes.
    static func bgra(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        let pb = buffer(w, h, kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b, a) = f(x, y)
            let p = base + y * bpr + x * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = a
        } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// A stored matte: discs of radius `tight` and `wide` round the centre.
    static func matte(tight: Double, wide: Double) -> CVPixelBuffer {
        func disc(_ r: Double) -> BitMask {
            var m = BitMask(width: w, height: h)
            for y in 0..<h { for x in 0..<w where hypot(Double(x) + 0.5 - Double(w) / 2, Double(y) + 0.5 - Double(h) / 2) <= r { m[x, y] = true } }
            return m
        }
        let pb = buffer(w, 2 * h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        MatteMath.signedDistance(disc(tight), into: y, bytesPerRow: bpr)
        MatteMath.signedDistance(disc(wide), into: y + h * bpr, bytesPerRow: bpr)
        memset(CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Back pass: opaque red. Front pass: a blue square in the top-left corner.
    static func fullBack(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        y < h ? (255, 0, 0, 255) : (x < 30 && y - h < 30 ? (0, 0, 255, 255) : (0, 0, 0, 0))
    }

    func render(edge: Double, radius: Double, withMatte: Bool = true, effects: [ActiveEffect] = [],
                slice pixels: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = DepthRenderTests.fullBack,
                setUp: (inout DepthLayer) -> Void = { _ in }) async throws -> (Int, Int) -> SIMD4<Float> {
        let footage = Self.bgra(Self.w, Self.h) { _, _ in (0, 160, 0, 255) }                     // the person and his room: green
        let slice = Self.bgra(Self.w, 2 * Self.h, pixels)
        var d = DepthLayer()
        d.edgeStrength = edge
        d.edgeRadius = radius
        d.referenceWidth = Double(Self.w)
        setUp(&d)
        let layers: [(CVPixelBuffer, RenderLayer)] = [
            (footage, RenderLayer(transform: .identity, opacity: 1, sourceRotation: 0)),
            (slice, RenderLayer(transform: .identity, opacity: 1, sourceRotation: 0, effects: effects, depth: d)),
        ]
        let out = Self.buffer(Self.w, Self.h, kCVPixelFormatType_64RGBAHalf)
        let mattes = withMatte ? [0: Self.matte(tight: 60, wide: 66)] : [:]
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            RenderGraph.shared.render(layers, mattes: mattes, into: out, hdr: false) { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        }
        CVPixelBufferLockBaseAddress(out, .readOnly)
        let base = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: Float16.self), bpr = CVPixelBufferGetBytesPerRow(out) / 2
        var px = [SIMD4<Float>](repeating: .zero, count: Self.w * Self.h)
        for y in 0..<Self.h { for x in 0..<Self.w { let p = base + y * bpr + x * 4; px[y * Self.w + x] = [Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3])] } }
        CVPixelBufferUnlockBaseAddress(out, .readOnly)
        return { x, y in px[y * Self.w + x] }
    }

    @Test func backIsCutByThePersonAndTheEdgeFillsTheBand() async throws {
        let at = try await render(edge: 1, radius: 8)
        let c = Self.w / 2
        func near(_ v: SIMD4<Float>, _ want: SIMD3<Float>, _ tol: Float = 0.03) -> Bool { abs(v.x - want.x) < tol && abs(v.y - want.y) < tol && abs(v.z - want.z) < tol }
        let green = SIMD3<Float>(0, 160.0 / 255, 0)
        #expect(near(at(c, c), green), "the person shows through: \(at(c, c))")
        #expect(near(at(c + 56, c), green), "4 px inside his outline he still shows: \(at(c + 56, c))")
        #expect(near(at(c + 70, c), [1, 1, 1]), "in the band past his outline the edge is lit: \(at(c + 70, c))")
        #expect(near(at(c + 84, c), [1, 0, 0]), "past wide + radius the back pass shows: \(at(c + 84, c))")
        #expect(near(at(5, 200), [1, 0, 0]), "far from him: back pass")
        #expect(near(at(5, 5), [0, 0, 1]), "the front pass covers everything")
    }

    @Test func noEdgeOutsideItsWindowAndNoCutWithoutAMatte() async throws {
        let off = try await render(edge: 0, radius: 8)
        #expect(abs(off(Self.w / 2 + 70, Self.h / 2).x - 1) < 0.03 && off(Self.w / 2 + 70, Self.h / 2).y < 0.03, "edge off: back pass in the band")
        // The cut sits 1 px inside his outline (radius 60): pixel centres 0.5 and
        // 1.5 px inside are cut by phi(-0.5) and phi(0.5), so red shows 69% and 31%.
        let c = Self.w / 2
        #expect(abs(off(c + 59, c).x - 0.69) < 0.06 && abs(off(c + 58, c).x - 0.31) < 0.06,
                "cut 1 px inside: \(off(c + 59, c).x), \(off(c + 58, c).x)")
        let none = try await render(edge: 1, radius: 8, withMatte: false)
        #expect(abs(none(Self.w / 2, Self.h / 2).x - 1) < 0.03, "without a matte nothing is cut and no edge is drawn")
    }

    @Test func effectsRunOnBothPasses() async throws {
        let half = try await render(edge: 0, radius: 0, effects: [try EffectRenderTests().fx("fade.out", progress: 0.5, ["easing": 0])])
        let g: Float = 160.0 / 255
        let back = half(5, 200), front = half(5, 5)
        #expect(abs(back.x - 0.5) < 0.04 && abs(back.y - g * 0.5) < 0.04, "the back pass fades by half over the room: \(back)")
        // Half blue over (half red over green).
        #expect(abs(front.z - 0.5) < 0.04 && abs(front.x - 0.25) < 0.04 && abs(front.y - g * 0.25) < 0.04, "so does the front pass: \(front)")
        let c = Self.w / 2
        #expect(abs(half(c, c).y - g) < 0.03, "the person still shows: \(half(c, c))")
    }

    @Test func elementsCastAShadowOnTheWallNotOnThePerson() async throws {
        // One element behind the person, left of him (x 20-50); the person is the disc of radius 60 round the centre (x 60-180).
        let element: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { x, y in
            y < Self.h && (20..<50).contains(x) && (100..<140).contains(y) ? (255, 0, 0, 255) : (0, 0, 0, 0)
        }
        let g: Float = 160.0 / 255
        let lit = try await render(edge: 0, radius: 0, slice: element) { d in
            d.shadowOpacity = 0.5
            d.shadowOffset = [24, 0]
            d.shadowBlur = 4
        }
        #expect(lit(55, 120).y < g * 0.65, "the wall right of the element is in its shadow: \(lit(55, 120))")
        #expect(abs(lit(70, 120).y - g) < 0.03, "the person is not: \(lit(70, 120))")
        #expect(abs(lit(55, 30).y - g) < 0.03, "nor is the wall away from it: \(lit(55, 30))")
        #expect(abs(lit(35, 120).x - 1) < 0.03, "the element itself sits on top of its shadow: \(lit(35, 120))")
        let frontOnly = try await render(edge: 0, radius: 0, slice: element) { d in
            d.shadowOpacity = 0.5
            d.shadowOffset = [24, 0]
            d.shadowBlur = 4
            d.shadowFromBack = false
        }
        #expect(abs(frontOnly(55, 120).y - g) < 0.03, "elements of the back pass cast none when only the front casts: \(frontOnly(55, 120))")
    }
}

/// The matte follows the source frames through cuts, speed changes and
/// chunk boundaries. Imported masks encode the source frame as the width of
/// a bar, which the time repair keeps (the bar only grows).
@Suite("Matte on the timeline", .serialized)
struct MatteTimelineTests {
    @Test func matteFramesMatchTheFootageFrames() async throws {
        var p = try await OpenGOPTests().project()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-mt-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("p.dme")
        let masks = MatteStore.importFolder(package: package, asset: "src")
        try FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
        for n in 0..<130 {
            let ctx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 100, width: 2 + 2 * n, height: 40))
            let url = masks.appendingPathComponent("\(Int((Double(n) * 1000 / 30).rounded())).png")
            let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(d)
        }
        p.media[0].matte = .imported
        p.media[0].fingerprint = "fixture-\(UUID().uuidString)"
        let settings = try UserSettingsStore(directory: dir.appendingPathComponent("home"))
        try settings.update { $0.matte.chunkSeconds = 0.5 }
        let store = MatteStore(settings: settings)
        let needed = MatteStore.needed(p, asset: "src", chunkSeconds: 0.5)
        _ = try await store.generate(p.media[0], package: package, only: needed) { _, _, _ in }
        let built = try await CompositionBuilder().build(p, package: package, mattes: store, matteSettings: settings.current.matte)
        let id = try #require(built.matteTracks["main"])
        let track = try #require(try await built.composition.loadTrack(withTrackID: id))
        let reader = try AVAssetReader(asset: built.composition)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        reader.add(out)
        #expect(reader.startReading())
        var checked = 0
        let clips = p.tracks[0].clips
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let frame = Int((t * 30).rounded())
            // A double-speed clip carries two samples per frame; the compositor asks for whole frames only.
            guard abs(t * 30 - Double(frame)) < 0.01 else { continue }
            let at = Time(ticks: Int64(frame) * 8000)
            guard let c = clips.first(where: { $0.start <= at && at < $0.end }) else { continue }
            let want = Int((c.sourceTime(at: at).seconds * 30).rounded())
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let row = 120   // middle of the bar (CG draws bottom-up: rows 100-140 from the bottom)
            var width = 0
            for x in 0..<320 where y[row * bpr + x] > 128 { width += 1 }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            #expect(width == 2 + 2 * want, "timeline frame \(frame): matte of source frame \((width - 2) / 2), wants \(want)")
            checked += 1
        }
        #expect(checked >= 50, "checked \(checked) frames")
        try? FileManager.default.trashItem(at: MatteStore.cacheFolder(p.media[0]), resultingItemURL: nil)
    }
}
