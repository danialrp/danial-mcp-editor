import AVFoundation
import CoreVideo
import Metal
import simd

/// A custom AVFoundation compositor that renders every frame with a Metal kernel,
/// the way the editor's render graph will. It converts the decoded frame to RGBA
/// half float and applies a gain, which stands in for a look.
final class MetalCompositor: NSObject, AVVideoCompositing {
    enum Input: String { case native, half, bgra, raw }

    // Configuration is set once before the composition is used.
    nonisolated(unsafe) static var input: Input = .native
    nonisolated(unsafe) static var matrix: simd_float3x3 = YUV.rec709
    nonisolated(unsafe) static var gain: Float = 1.0
    nonisolated(unsafe) static var outputAttachments: [CFString: CFString] = [:]
    static let timings = Timings()
    static let formats = FormatSet()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var cache: CVMetalTextureCache?
    private let yuvPipeline: MTLComputePipelineState
    private let copyPipeline: MTLComputePipelineState

    override init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: kernels, options: nil)
        yuvPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "yuv2rgb")!)
        copyPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "copyrgb")!)
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        if Self.input == .raw {
            // A list: the decoder picks the first format it can produce without converting, if any.
            let order = ProcessInfo.processInfo.environment["FORMATS"]?.split(separator: ",").map(String.init)
                ?? ["x420", "420v", "y416", "BGRA", "RGhA"]
            let codes: [OSType] = order.map { $0.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
            return [kCVPixelBufferPixelFormatTypeKey as String: codes,
                    kCVPixelBufferMetalCompatibilityKey as String: true]
        }
        let fmt: OSType
        switch Self.input {
        case .raw: return nil
        case .native: fmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .half: fmt = kCVPixelFormatType_64RGBAHalf
        case .bgra: fmt = kCVPixelFormatType_32BGRA
        }
        return [kCVPixelBufferPixelFormatTypeKey as String: fmt,
                kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var supportsHDRSourceFrames: Bool { true }
    var supportsWideColorSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let dst = request.renderContext.newPixelBuffer(), let cache else {
            request.finish(with: NSError(domain: "probe", code: 1))
            return
        }
        // A time with no source picture (a gap, or a file whose first frame starts
        // late) must still produce a frame, or playback stops. Render black.
        guard let id = request.sourceTrackIDs.first?.int32Value,
              let src = request.sourceFrame(byTrackID: id) else {
            CVPixelBufferLockBaseAddress(dst, [])
            memset(CVPixelBufferGetBaseAddress(dst), 0, CVPixelBufferGetDataSize(dst))
            CVPixelBufferUnlockBaseAddress(dst, [])
            request.finish(withComposedVideoFrame: dst)
            return
        }
        if Self.input == .raw {
            let f = CVPixelBufferGetPixelFormatType(src)
            let code = String(bytes: [24, 16, 8, 0].map { UInt8((f >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "?"
            Self.formats.add(code)
            CVPixelBufferLockBaseAddress(dst, [])
            memset(CVPixelBufferGetBaseAddress(dst), 0, CVPixelBufferGetDataSize(dst))
            CVPixelBufferUnlockBaseAddress(dst, [])
            request.finish(withComposedVideoFrame: dst)
            return
        }
        for (k, v) in Self.outputAttachments {
            CVBufferSetAttachment(dst, k, v, .shouldPropagate)
        }
        let w = CVPixelBufferGetWidth(dst), h = CVPixelBufferGetHeight(dst)
        guard let out = texture(dst, plane: 0, format: .rgba16Float, w: w, h: h, cache: cache),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            request.finish(with: NSError(domain: "probe", code: 2))
            return
        }
        var gain = Self.gain
        var keep: [CVMetalTexture] = [out]
        switch Self.input {
        case .native:
            guard let y = texture(src, plane: 0, format: .r16Unorm,
                                  w: CVPixelBufferGetWidthOfPlane(src, 0), h: CVPixelBufferGetHeightOfPlane(src, 0), cache: cache),
                  let uv = texture(src, plane: 1, format: .rg16Unorm,
                                   w: CVPixelBufferGetWidthOfPlane(src, 1), h: CVPixelBufferGetHeightOfPlane(src, 1), cache: cache) else {
                enc.endEncoding()
                request.finish(with: NSError(domain: "probe", code: 3))
                return
            }
            keep += [y, uv]
            var m = Self.matrix
            enc.setComputePipelineState(yuvPipeline)
            enc.setTexture(CVMetalTextureGetTexture(y), index: 0)
            enc.setTexture(CVMetalTextureGetTexture(uv), index: 1)
            enc.setTexture(CVMetalTextureGetTexture(out), index: 2)
            enc.setBytes(&m, length: MemoryLayout<simd_float3x3>.stride, index: 0)
        case .raw:
            enc.endEncoding()
            return
        case .half, .bgra:
            let fmt: MTLPixelFormat = Self.input == .half ? .rgba16Float : .bgra8Unorm
            guard let s = texture(src, plane: 0, format: fmt,
                                  w: CVPixelBufferGetWidth(src), h: CVPixelBufferGetHeight(src), cache: cache) else {
                enc.endEncoding()
                request.finish(with: NSError(domain: "probe", code: 4))
                return
            }
            keep.append(s)
            enc.setComputePipelineState(copyPipeline)
            enc.setTexture(CVMetalTextureGetTexture(s), index: 0)
            enc.setTexture(CVMetalTextureGetTexture(out), index: 2)
        }
        enc.setBytes(&gain, length: 4, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.addCompletedHandler { _ in
            _ = keep
            Self.timings.add(DispatchTime.now().uptimeNanoseconds - t0)
            request.finish(withComposedVideoFrame: dst)
        }
        cmd.commit()
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         w: Int, h: Int, cache: CVMetalTextureCache) -> CVMetalTexture? {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &t)
        return t
    }
}

enum YUV {
    // rgb = M * (Y, Cb, Cr); columns are the Y, Cb and Cr contributions.
    static let rec709 = simd_float3x3(columns: (
        SIMD3(1, 1, 1), SIMD3(0, -0.1873, 1.8556), SIMD3(1.5748, -0.4681, 0)))
    static let rec2020 = simd_float3x3(columns: (
        SIMD3(1, 1, 1), SIMD3(0, -0.16455, 1.8814), SIMD3(1.4746, -0.57135, 0)))
}

private let kernels = """
#include <metal_stdlib>
using namespace metal;

// 10-bit video range in a 16-bit container: Y 64..940, C 64..960.
kernel void yuv2rgb(texture2d<float, access::read> y [[texture(0)]],
                    texture2d<float, access::read> uv [[texture(1)]],
                    texture2d<half, access::write> out [[texture(2)]],
                    constant float3x3 &m [[buffer(0)]],
                    constant float &gain [[buffer(1)]],
                    uint2 g [[thread_position_in_grid]]) {
    if (g.x >= out.get_width() || g.y >= out.get_height()) return;
    float Y = (y.read(g).r - 64.0/1023.0) * (1023.0/876.0);
    float2 c = (uv.read(g / 2).rg - 512.0/1023.0) * (1023.0/896.0);
    float3 rgb = m * float3(Y, c.x, c.y);
    out.write(half4(half3(rgb * gain), 1.0h), g);
}

kernel void copyrgb(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<half, access::write> out [[texture(2)]],
                    constant float &gain [[buffer(1)]],
                    uint2 g [[thread_position_in_grid]]) {
    if (g.x >= out.get_width() || g.y >= out.get_height()) return;
    out.write(half4(half3(src.read(g).rgb * gain), 1.0h), g);
}
"""

/// Thread-safe collection of per-frame render times.
final class Timings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []
    func add(_ ns: UInt64) { lock.lock(); values.append(ns); lock.unlock() }
    func reset() { lock.lock(); values.removeAll(); lock.unlock() }
    func snapshot() -> [UInt64] { lock.lock(); defer { lock.unlock() }; return values }
}

final class FormatSet: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<String>()
    func add(_ s: String) { lock.lock(); set.insert(s); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return set.sorted() }
}
