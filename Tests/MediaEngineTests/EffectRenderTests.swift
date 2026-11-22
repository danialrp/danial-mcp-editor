import EditorCore
import CoreVideo
import Foundation
@testable import MediaEngine
import Testing

/// Built-in effects and the plug-in loader, rendered through the real GPU
/// path. Each effect must do its job and leave the rest alone.
@Suite("Effects, rendered", .serialized)
struct EffectRenderTests {
    let neutral: Picture

    init() async throws { neutral = try await LookRender.render(nil) }

    func fx(_ id: String, progress: Double, _ params: [String: Double] = [:], in catalog: EffectCatalog = .shared) throws -> ActiveEffect {
        let e = try #require(catalog.entry(id), "\(id) is installed")
        let resolved = try e.manifest.resolve(params)
        return ActiveEffect(pipelines: Unchecked(e.pipelines),
                            params: e.manifest.parameters.map { Float(resolved[$0.name]!) } + Array(repeating: 0, count: 16 - e.manifest.parameters.count),
                            progress: Float(progress), time: 0, mipmaps: e.manifest.mipmaps ?? false)
    }

    func render(_ effects: [ActiveEffect]) async throws -> Picture {
        try await LookRender.render(nil, effects: effects)
    }

    @Test func builtInsLoadWithoutProblems() {
        let ids = Set(EffectCatalog.shared.all.map(\.manifest.id))
        #expect(ids.isSuperset(of: ["fade.in", "fade.out", "blur.in", "blur.gaussian"]))
        #expect(EffectCatalog.shared.currentProblems.filter { $0.folder.contains("/Effects/") }.isEmpty)
    }

    @Test func offscreenPathAloneChangesNothing() async throws {
        // A fade in at its end is a pass that copies the picture.
        let p = try await render([try fx("fade.in", progress: 1)])
        for i in stride(from: 0, to: p.px.count, by: 97) { #expect(close(p.px[i], neutral.px[i], 0.002), "pixel \(i)") }
    }

    @Test func fadeIn() async throws {
        let start = try await render([try fx("fade.in", progress: 0)])
        #expect(start.px.allSatisfy { $0.max() < 0.001 }, "first frame is fully transparent over black")
        let half = try await render([try fx("fade.in", progress: 0.5, ["easing": 0])])
        for c in [3, 8, 15] { #expect(close(half.patch(c, 0), neutral.patch(c, 0) * 0.5, 0.004), "linear halfway is half") }
        #expect(abs(Chart.hue(half.patch(1, 1)) - Chart.hue(neutral.patch(1, 1))) < 2, "colour kept")
    }

    @Test func fadeOut() async throws {
        let end = try await render([try fx("fade.out", progress: 1)])
        #expect(end.px.allSatisfy { $0.max() < 0.001 }, "last frame is black")
        let start = try await render([try fx("fade.out", progress: 0)])
        #expect(close(start.patch(10, 0), neutral.patch(10, 0), 0.002), "starts untouched")
    }

    @Test func gaussianBlur() async throws {
        // A checker over the whole frame, so nothing else bleeds in.
        let checker = { (x: Int, y: Int) in RGB(repeating: ((x / 6) + (y / 6)) % 2 == 0 ? 0.4 : 0.6) }
        let base = try await LookRender.render(nil, pixel: checker)
        let p = try await LookRender.render(nil, effects: [try fx("blur.gaussian", progress: 0, ["radius": 150])], pixel: checker)
        #expect(p.spread(8, 1) < base.spread(8, 1) * 0.3, "detail is blurred away")
        #expect(abs(Chart.luma(p.patch(8, 1)) - Chart.luma(base.patch(8, 1))) < 0.01, "average brightness kept")
        let less = try await LookRender.render(nil, effects: [try fx("blur.gaussian", progress: 0, ["radius": 50])], pixel: checker)
        #expect(less.spread(8, 1) > p.spread(8, 1) && less.spread(8, 1) < base.spread(8, 1), "more radius, more blur")
        let none = try await render([try fx("blur.gaussian", progress: 0, ["radius": 0])])
        #expect(close(none.patch(2, 2), neutral.patch(2, 2), 0.002) && abs(none.spread(2, 2) - neutral.spread(2, 2)) < 0.002, "radius 0 does nothing")
        let flat = try await LookRender.render(nil, effects: [try fx("blur.gaussian", progress: 0, ["radius": 150])]) { _, _ in RGB(repeating: 0.5) }
        #expect(close(flat.at(Chart.width / 2, Chart.height / 2), RGB(repeating: 0.5), 0.003), "flat picture untouched")
    }

    @Test func blurIn() async throws {
        let start = try await render([try fx("blur.in", progress: 0)])
        #expect(start.spread(2, 2) < neutral.spread(2, 2) * 0.3, "starts blurred")
        let end = try await render([try fx("blur.in", progress: 1)])
        #expect(close(end.patch(2, 2), neutral.patch(2, 2), 0.002) && abs(end.spread(2, 2) - neutral.spread(2, 2)) < 0.002, "ends sharp")
        let faded = try await render([try fx("blur.in", progress: 0, ["fade": 1])])
        #expect(faded.px.allSatisfy { $0.max() < 0.001 }, "with fade, starts transparent")
    }

    @Test func effectsChainInOrder() async throws {
        let p = try await render([try fx("blur.gaussian", progress: 0, ["radius": 150]), try fx("fade.out", progress: 0.5, ["easing": 0])])
        let blurred = try await render([try fx("blur.gaussian", progress: 0, ["radius": 150])])
        #expect(close(p.patch(12, 0), blurred.patch(12, 0) * 0.5, 0.004))
    }

    @Test func effectStaysInsideItsLayer() async throws {
        // A half-size layer: the blur must not spread the picture outside it.
        var t = Transform()
        t.scale = 0.5
        let p = try await LookRender.render(nil, effects: [try fx("blur.gaussian", progress: 0, ["radius": 150])], transform: t)
        #expect(p.at(2, 2).max() < 0.001 && p.at(Chart.width - 3, Chart.height - 3).max() < 0.001, "outside the layer stays black")
    }

    /// The phase 5 exit check: a new effect appears by dropping a folder in
    /// place, and a broken one is reported instead of crashing.
    @Test func droppedInFolderBecomesAnEffect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dme-fx-\(UUID().uuidString)")
        let good = root.appendingPathComponent("test.invert"), bad = root.appendingPathComponent("test.broken")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try #"{"id": "test.invert", "name": "Invert", "kind": "filter", "passes": ["invert"], "parameters": [{"name": "amount", "type": "number", "min": 0, "max": 1, "default": 1}]}"#
            .write(to: good.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "EFFECT(invert) { float4 c = src.sample(smp, in.uv); return float4(mix(c.rgb, c.a - c.rgb, params[0]), c.a); }"
            .write(to: good.appendingPathComponent("effect.metal"), atomically: true, encoding: .utf8)
        try #"{"id": "test.broken", "kind": "filter", "passes": ["nope"]}"#.write(to: bad.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "EFFECT(nope) { return undefinedThing; }".write(to: bad.appendingPathComponent("effect.metal"), atomically: true, encoding: .utf8)

        let catalog = EffectCatalog()
        catalog.configure(userFolder: root)

        #expect(catalog.entry("test.invert") != nil)
        #expect(catalog.entry("blur.gaussian") != nil, "built-ins still there")
        #expect(catalog.entry("test.broken") == nil)
        #expect(catalog.currentProblems.contains { $0.folder.hasSuffix("test.broken") && $0.message.contains("compile") })
        let p = try await render([try fx("test.invert", progress: 0, in: catalog)])
        #expect(close(p.patch(12, 0), RGB(repeating: 1) - neutral.patch(12, 0), 0.004), "the new effect runs")
    }
}

/// Architecture section 16: effects must hold 4K at 60 fps on the GPU.
/// `timed` in a test's name: it runs on its own (see scripts/swift.sh).
@Suite("Effect performance", .serialized)
struct EffectPerformanceTests {
    /// Milliseconds per 4K frame, rendered one after another.
    func measure(_ effects: [ActiveEffect]) async throws -> Double {
        let (w, h) = (3840, 2160)
        let pair = Unchecked((LookRender.buffer(w, h, kCVPixelFormatType_32BGRA), LookRender.buffer(w, h, kCVPixelFormatType_64RGBAHalf)))
        let layer = RenderLayer(transform: .identity, opacity: 1, sourceRotation: 0, effects: effects)
        func once() async throws {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                RenderGraph.shared.render([(pair.value.0, layer)], into: pair.value.1, hdr: false) { e in
                    if let e { k.resume(throwing: e) } else { k.resume() }
                }
            }
        }
        try await once()   // warm up: textures, pipelines
        let n = 30
        let t0 = Date()
        for _ in 0..<n { try await once() }
        return Date().timeIntervalSince(t0) / Double(n) * 1000
    }

    func blur(_ r: Float) throws -> ActiveEffect {
        let e = try #require(EffectCatalog.shared.entry("blur.gaussian"))
        return ActiveEffect(pipelines: Unchecked(e.pipelines), params: [r] + Array(repeating: 0, count: 15), progress: 0, time: 0, mipmaps: true)
    }

    @Test func timedEffectsAt4KFitAFrame() async throws {
        let fade = try #require(EffectCatalog.shared.entry("fade.in"))
        let copy = ActiveEffect(pipelines: Unchecked(fade.pipelines), params: [1] + Array(repeating: 0, count: 15), progress: 1, time: 0)
        let plain = try await measure([])
        let offscreen = try await measure([copy])
        let typical = try await measure([try blur(20)])
        let widest = try await measure([try blur(200)])
        print(String(format: "[perf] 4K frame: plain %.2f ms, one simple effect %.2f ms, blur 20 %.2f ms, blur 200 %.2f ms",
                     plain, offscreen, typical, widest))
        #expect(widest < 16.6, "one 4K frame with the widest blur must fit in a 60 fps frame")
    }
}
