import EditorCore
import Foundation
import Metal

/// Shader code every effect plug-in is compiled with: a full-frame vertex
/// function, the context struct, the `EFFECT(name)` signature and helpers.
/// A plug-in's `effect.metal` only writes fragment functions with `EFFECT`.
let effectShaderHeader = """
#include <metal_stdlib>
using namespace metal;

struct FXVertexOut { float4 position [[position]]; float2 uv; };

vertex FXVertexOut fxVertex(uint vid [[vertex_id]]) {
    const float2 p[4] = {float2(-1, 1), float2(1, 1), float2(-1, -1), float2(1, -1)};
    FXVertexOut o;
    o.position = float4(p[vid], 0.0, 1.0);
    o.uv = float2(p[vid].x * 0.5 + 0.5, 0.5 - p[vid].y * 0.5);
    return o;
}

struct FXContext {
    float2 size;      // picture size in pixels
    float2 texel;     // one pixel in texture units
    float progress;   // in and out effects: 0 to 1 over their duration; filters: position in the clip
    float time;       // seconds since the clip start
    float scale;      // short side of the picture / 1080: multiply sizes given in pixels by this
    float seed;       // changes every frame
    int pass;         // index of this pass among the effect's passes
    int hasMatte;     // 1 when `matte` holds the person matte (later phase)
    float2 pad;
};

// src: the clip's picture so far, premultiplied RGBA. params: the manifest's
// parameters in manifest order (booleans 0 or 1, choices as their index).
#define EFFECT(name) fragment float4 name(FXVertexOut in [[stage_in]], \\
    texture2d<float> src [[texture(0)]], texture2d<float> matte [[texture(1)]], \\
    sampler smp [[sampler(0)]], constant FXContext &ctx [[buffer(0)]], constant float *params [[buffer(1)]])

inline float fxEase(float t) { t = clamp(t, 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }

/// One direction of a Gaussian blur; `radius` in pixels of this picture.
/// At most 6 taps each side; a wide blur reads a smaller mipmap level so
/// each tap already averages the pixels between taps (no aliasing, fixed
/// cost at any radius). Needs `"mipmaps": true` in the manifest.
inline float4 fxGaussian(texture2d<float> src, sampler smp, float2 uv, float2 texel, float2 dir, float radius) {
    if (radius < 0.5) return src.sample(smp, uv, level(0.0));
    int taps = int(min(ceil(radius), 6.0));
    float stepPx = radius / float(taps);
    float lod = log2(max(stepPx, 1.0));
    float sigma = max(radius / 2.0, 0.5);
    float4 sum = src.sample(smp, uv, level(lod));
    float total = 1.0;
    for (int i = 1; i <= taps; i++) {
        float x = float(i) * stepPx;
        float w = exp(-x * x / (2.0 * sigma * sigma));
        float2 o = dir * texel * x;
        sum += w * (src.sample(smp, uv + o, level(lod)) + src.sample(smp, uv - o, level(lod)));
        total += 2.0 * w;
    }
    return sum / total;
}

"""

/// Installed effect plug-ins (architecture section 7): folders with a
/// `manifest.json` and an `effect.metal`, built in or dropped into the user's
/// effects folder. Compiled once on load; `reload` rescans.
public final class EffectCatalog: @unchecked Sendable {
    public static let shared = EffectCatalog()

    public struct Entry: @unchecked Sendable {
        public var manifest: EffectManifest
        public var folder: URL
        public var builtIn: Bool
        var pipelines: [MTLRenderPipelineState]
    }

    public struct Problem: Sendable {
        public var folder: String
        public var message: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var problems: [Problem] = []
    private var userFolder: URL?
    private var loaded = false

    /// Built-in effects: in the app bundle, or in the source tree when run
    /// from a build folder (dme, tests).
    static var builtInFolder: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Effects"), FileManager.default.fileExists(atPath: r.path) { return r }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Effects")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    /// Sets the user's effects folder and loads everything.
    public func configure(userFolder: URL) {
        lock.withLock { self.userFolder = userFolder }
        reload()
    }

    public var userEffectsFolder: URL? { lock.withLock { userFolder } }

    @discardableResult
    public func reload() -> (effects: [Entry], problems: [Problem]) {
        let device = RenderGraph.shared.device
        var found: [String: Entry] = [:], bad: [Problem] = []
        let folders: [(URL, Bool)] = [(Self.builtInFolder, true), (lock.withLock { userFolder }, false)].compactMap { u, b in u.map { ($0, b) } }
        for (root, builtIn) in folders {
            let subs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for dir in subs {
                do {
                    let e = try Self.load(dir, builtIn: builtIn, device: device)
                    found[e.manifest.id] = e   // a user plug-in with a built-in's id replaces it
                } catch {
                    bad.append(Problem(folder: dir.path, message: "\(error)"))
                }
            }
        }
        lock.withLock {
            entries = found
            problems = bad
            loaded = true
        }
        return (found.values.sorted { $0.manifest.id < $1.manifest.id }, bad)
    }

    struct LoadError: Error, CustomStringConvertible {
        var description: String
    }

    static func load(_ dir: URL, builtIn: Bool, device: MTLDevice) throws -> Entry {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = FileManager.default.contents(atPath: manifestURL.path) else { throw LoadError(description: "no manifest.json") }
        let m: EffectManifest
        do { m = try JSONDecoder().decode(EffectManifest.self, from: data) } catch {
            throw LoadError(description: "manifest.json does not decode: \(error)")
        }
        let issues = m.problems()
        guard issues.isEmpty else { throw LoadError(description: issues.joined(separator: "; ")) }
        guard let src = try? String(contentsOf: dir.appendingPathComponent("effect.metal"), encoding: .utf8) else {
            throw LoadError(description: "no effect.metal")
        }
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: effectShaderHeader + src, options: nil) } catch {
            throw LoadError(description: "effect.metal does not compile: \(error.localizedDescription)")
        }
        var pipes: [MTLRenderPipelineState] = []
        for name in m.passes {
            guard let f = lib.makeFunction(name: name) else { throw LoadError(description: "effect.metal has no EFFECT(\(name))") }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fxVertex")
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = .rgba16Float
            pipes.append(try device.makeRenderPipelineState(descriptor: d))
        }
        return Entry(manifest: m, folder: dir, builtIn: builtIn, pipelines: pipes)
    }

    private func ensureLoaded() {
        if !lock.withLock({ loaded }) { reload() }
    }

    public var all: [Entry] {
        ensureLoaded()
        return lock.withLock { entries.values.sorted { $0.manifest.id < $1.manifest.id } }
    }

    public var currentProblems: [Problem] {
        ensureLoaded()
        return lock.withLock { problems }
    }

    public func entry(_ id: String) -> Entry? {
        ensureLoaded()
        return lock.withLock { entries[id] }
    }

    /// The effect as the render graph runs it at one frame, or nil when it
    /// is off, not running at this moment, or not installed.
    func active(_ fx: EffectInstance, offset: Time, clipDuration: Time) -> ActiveEffect? {
        guard fx.enabled, let progress = fx.progress(at: offset, clipDuration: clipDuration), let e = entry(fx.effect) else { return nil }
        var params = [Float](repeating: 0, count: 16)
        for (i, p) in e.manifest.parameters.prefix(16).enumerated() { params[i] = Float(fx.params[p.name] ?? p.defaultValue) }
        return ActiveEffect(pipelines: Unchecked(e.pipelines), params: params, progress: Float(progress), time: Float(offset.seconds),
                            mipmaps: e.manifest.mipmaps ?? false)
    }
}

/// One effect to run on a layer this frame.
public struct ActiveEffect: Sendable {
    var pipelines: Unchecked<[MTLRenderPipelineState]>
    var params: [Float]
    var progress: Float
    var time: Float
    /// The input of each pass gets mipmaps first (see `fxGaussian`).
    var mipmaps = false
}

/// Must match `FXContext` in `effectShaderHeader`.
struct FXContext {
    var size: SIMD2<Float>
    var texel: SIMD2<Float>
    var progress: Float
    var time: Float
    var scale: Float
    var seed: Float
    var pass: Int32
    var hasMatte: Int32 = 0
    var pad: SIMD2<Float> = .zero
}
