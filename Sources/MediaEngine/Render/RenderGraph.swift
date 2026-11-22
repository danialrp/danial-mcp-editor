import AVFoundation
import CoreMedia
import CoreGraphics
import CoreVideo
import EditorCore
import Foundation
import Metal
import simd

/// One picture to draw: a decoded frame and where it goes.
public struct RenderLayer: Sendable {
    public var transform: Transform
    public var opacity: Double
    /// Rotation stored in the source file (phones often store portrait video
    /// on its side with a 90° rotation), in degrees clockwise.
    public var sourceRotation: Int
    public var look: LookUniforms
    /// Effects to run on this layer this frame, first to last.
    public var effects: [ActiveEffect]
    /// Set for a depth composition: the frame holds a back pass on top and
    /// a front pass below, and the back pass goes behind the person.
    public var depth: DepthLayer?
    /// The colour space of the file the frame comes from, when the shader
    /// converts it (see `FrameSpace`). nil reads the frame's tags: buffers
    /// made here (stills) and spaces left to AVFoundation.
    var sourceSpace: FrameSpace?

    public init(transform: Transform, opacity: Double, sourceRotation: Int, look: LookUniforms = .none,
                effects: [ActiveEffect] = [], depth: DepthLayer? = nil) {
        self.transform = transform
        self.opacity = opacity
        self.sourceRotation = sourceRotation
        self.look = look
        self.effects = effects
        self.depth = depth
    }
}

/// How a depth composition meets the person this frame.
public struct DepthLayer: Sendable, Equatable {
    /// Strength of the lit outline, 0 when it is off.
    public var edgeStrength: Double = 0
    /// How far the outline reaches past the wide matte, in pixels of a frame
    /// `referenceWidth` wide.
    public var edgeRadius: Double = 0
    public var edgeColor: SIMD3<Float> = [1, 1, 1]
    public var referenceWidth: Double = 1080
    public var softness: Double = 1.1
    public var cutInset: Double = 1
    public var cutSoftness: Double = 1
    /// Cut by the wide matte instead of the tight one.
    public var cutWide = false
    public var profileFullTo: Double = 1
    public var profileZeroAt: Double = 1
    /// The shadow the composition's elements cast on the wall behind the
    /// person: never on the person. 0 is off.
    public var shadowOpacity: Double = 0
    public var shadowColor: SIMD3<Float> = [0, 0, 0]
    /// Offset and blur radius, in pixels of a frame `referenceWidth` wide.
    public var shadowOffset: SIMD2<Double> = [0, 0]
    public var shadowBlur: Double = 0
    /// Which pass casts it: the elements behind the person, the ones in front, or both.
    public var shadowFromBack = true
    public var shadowFromFront = true

    public init() {}
}

/// The colour space of a layer's picture: one the shader converts itself.
///
/// For a composition track it comes from the file's format description. Left
/// alone, AVFoundation converts a custom compositor's source frames to the
/// composition's colour space, except the first frame of each decode
/// session, and tags both kinds alike (measured for playback, stills and
/// export). So tracks in these spaces are retagged in the composition
/// (`retag`): nothing converts them on the way and the shader converts every
/// frame. Other spaces (PQ, Display P3) are left to AVFoundation.
enum FrameSpace: Sendable {
    case sdr      // Rec.709 (also assumed when untagged)
    case hlg      // Rec.2100 HLG

    /// Of a file's video format; nil for a space the shader does not convert.
    init?(format: CMFormatDescription) {
        func tag(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        let transfer = tag(kCMFormatDescriptionExtension_TransferFunction)
        let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries)
        if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
           primaries == nil || primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String {
            self = .hlg
        } else if transfer == nil || transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String
                    || transfer == kCVImageBufferTransferFunction_sRGB as String,
                  primaries == nil || primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String
                    || primaries == kCVImageBufferColorPrimaries_SMPTE_C as String {
            self = .sdr
        } else {
            return nil
        }
    }

    private static let dolbyVisionBoxes: Set<String> = ["dvcC", "dvvC", "dvwC"]

    /// Declares the composition tracks' pictures to be in the composition's
    /// own transfer and primaries, so AVFoundation hands them over with the
    /// values as stored. The Y'CbCr matrix stays the file's.
    static func retag(_ comp: AVMutableComposition, hdr: Bool) {
        for track in comp.tracks(withMediaType: .video) {
            for case let old as CMFormatDescription in track.formatDescriptions where FrameSpace(format: old) != nil {
                var ext = CMFormatDescriptionGetExtensions(old) as? [String: Any] ?? [:]
                ext[kCMFormatDescriptionExtension_ColorPrimaries as String] =
                    hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
                ext[kCMFormatDescriptionExtension_TransferFunction as String] =
                    hdr ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2
                // A Dolby Vision box (iPhone and VideoToolbox HLG files carry
                // one) has AVFoundation tone-map whatever the tags say; the
                // HLG picture under it is complete without it.
                let atoms = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
                if let boxes = ext[atoms] as? [String: Any] {
                    ext[atoms] = boxes.filter { !dolbyVisionBoxes.contains($0.key) }
                }
                let size = CMVideoFormatDescriptionGetDimensions(old)
                var new: CMFormatDescription?
                CMVideoFormatDescriptionCreate(allocator: nil, codecType: CMFormatDescriptionGetMediaSubType(old),
                                               width: size.width, height: size.height,
                                               extensions: ext as CFDictionary, formatDescriptionOut: &new)
                if let new { track.replaceFormatDescription(old, with: new) }
            }
        }
    }

    init(_ pb: CVPixelBuffer) {
        let transfer = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) as? String
        self = transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) ? .hlg : .sdr
    }
}

/// Draws layers into an output frame with Metal. One instance is shared by
/// every compositor in the process; it is safe to use from several threads.
public final class RenderGraph: @unchecked Sendable {
    public static let shared = RenderGraph()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private var cache: CVMetalTextureCache?
    private let biplanar: MTLRenderPipelineState
    private let ayuv: MTLRenderPipelineState
    private let rgb: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private let sdrView: MTLRenderPipelineState
    private let depthPipeline: MTLRenderPipelineState
    private let shadowAlphaPipeline: MTLRenderPipelineState
    private let shadowBlurPipeline: MTLRenderPipelineState
    private let mattePipeline: MTLRenderPipelineState
    /// Matte of a frame with no person: everything far outside.
    private let noPerson: MTLTexture
    private let sampler: MTLSamplerState
    /// For effect passes: also blends between mipmap levels.
    private let effectSampler: MTLSamplerState
    /// Stand-in for the person matte (X-3) until it exists: one white pixel.
    private let noMatte: MTLTexture
    /// Shadow of a composition that casts none: one clear pixel.
    private let noShadow: MTLTexture
    private let pool = TexturePool()

    private init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: renderShaderSource, options: nil)
        func pipeline(_ fragment: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "layerVertex")
            d.fragmentFunction = lib.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = .rgba16Float
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! device.makeRenderPipelineState(descriptor: d)
        }
        biplanar = pipeline("biplanarFragment")
        ayuv = pipeline("ayuvFragment")
        rgb = pipeline("rgbFragment")
        composite = pipeline("compositeFragment")
        sdrView = pipeline("sdrViewFragment")
        depthPipeline = pipeline("depthFragment")
        shadowAlphaPipeline = pipeline("shadowAlphaFragment")
        shadowBlurPipeline = pipeline("shadowBlurFragment")
        let md0 = MTLRenderPipelineDescriptor()
        md0.vertexFunction = lib.makeFunction(name: "layerVertex")
        md0.fragmentFunction = lib.makeFunction(name: "matteFragment")
        md0.colorAttachments[0].pixelFormat = .rgba16Float
        mattePipeline = try! device.makeRenderPipelineState(descriptor: md0)
        let nd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        noPerson = device.makeTexture(descriptor: nd)!
        let far: [Float16] = [-64, -64, 0, 1]
        noPerson.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: far, bytesPerRow: 8)
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        noMatte = device.makeTexture(descriptor: md)!
        noMatte.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
        noShadow = device.makeTexture(descriptor: md)!
        noShadow.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
        sd.mipFilter = .linear
        effectSampler = device.makeSamplerState(descriptor: sd)!
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// Pixel formats the compositor accepts. Each decoder picks a format it
    /// produces natively, so nothing is converted: 10-bit HEVC gives x420,
    /// 8-bit gives 420v. The alpha format comes first because an HEVC file
    /// with alpha can also produce x420 natively, which would drop its alpha
    /// (measured; see docs/phase0.md).
    public static let sourcePixelFormats: [OSType] = [
        kCVPixelFormatType_4444AYpCbCr16,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_32BGRA,
    ]

    /// Renders layers bottom to top into `output` (RGBA half float) and calls
    /// `done` when the GPU has finished. A layer with effects is first drawn
    /// at its own size into an offscreen texture, the effect passes run on it
    /// there, and the result is placed like any other layer. Everything runs
    /// on the GPU in one command buffer.
    /// `mattes` holds the person matte of layers that have one, by layer
    /// index; a depth layer is cut by the matte of the nearest layer below it
    /// that has one. `sdrPreview` draws an HLG frame exactly as it is
    /// exported and only then turns it into SDR.
    public func render(_ layers: [(CVPixelBuffer, RenderLayer)], mattes: [Int: CVPixelBuffer] = [:], into output: CVPixelBuffer,
                       hdr: Bool, sdrPreview: Bool = false, seed: Float = 0, done: @escaping @Sendable (Error?) -> Void) {
        guard cache != nil,
              let target = texture(output, plane: 0, format: .rgba16Float),
              let outputTexture = CVMetalTextureGetTexture(target),
              let cmd = queue.makeCommandBuffer() else {
            done(RenderError.setup)
            return
        }
        let width = Double(CVPixelBufferGetWidth(output)), height = Double(CVPixelBufferGetHeight(output))
        var keep: [CVMetalTexture] = [target]
        var pooled: [MTLTexture] = []

        // Looks, effects and blending happen in the project's space either way.
        var canvas = outputTexture
        // Raw or graded SDR footage alone needs no way through HLG and back,
        // which in half float lifts the empty channels of pure colours.
        let alone = hdr && sdrPreview && Self.needsNoHLG(layers)
        let hdr = hdr && !alone
        let toSDR = hdr && sdrPreview
        if toSDR {
            canvas = pool.take(device, Int(width), Int(height), mipmaps: false)
            pooled.append(canvas)
        }

        // Offscreen work for layers with effects.
        var processed: [Int: MTLTexture] = [:]
        // Person mattes in screen space, for depth layers.
        var screenMatte: [Int: MTLTexture] = [:]
        var subjectOf: [Int: Int] = [:]
        for (i, (_, layer)) in layers.enumerated() where layer.depth != nil && layer.opacity > 0 {
            guard let j = (0..<i).reversed().first(where: { mattes[$0] != nil && layers[$0].1.opacity > 0 }), let mpb = mattes[j] else { continue }
            subjectOf[i] = j
            guard screenMatte[j] == nil else { continue }
            let t = pool.take(device, Int(width), Int(height), mipmaps: false)
            pooled.append(t)
            let tenBit = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
                .contains(CVPixelBufferGetPixelFormatType(mpb))
            guard let y = texture(mpb, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: Self.pass(t, clear: .init(red: -64, green: -64, blue: 0, alpha: 1))) else { continue }
            keep.append(y)
            var sub = layers[j].1
            sub.sourceRotation = 0   // mattes are stored upright
            let mw = Double(CVPixelBufferGetWidth(mpb)), mh = Double(CVPixelBufferGetHeight(mpb)) / 2
            var quad = Self.quad(sub, sourceWidth: mw, sourceHeight: mh, canvasWidth: width, canvasHeight: height)
            let r = Self.range(mpb)
            var params: SIMD4<Float> = [r.x, r.y, Float(Self.pixelScale(sub, sourceWidth: mw, sourceHeight: mh, canvasWidth: width, canvasHeight: height)), 0]
            enc.setRenderPipelineState(mattePipeline)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.setVertexBytes(&quad, length: MemoryLayout<QuadVertex>.stride * 4, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            screenMatte[j] = t
        }

        for (i, (pb, layer)) in layers.enumerated() where layer.opacity > 0 && !layer.effects.isEmpty && layer.depth == nil {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            if let t = drawAlone(cmd, pb, layer, quad: Self.fullFrame, width: w, height: h, hdr: hdr, seed: seed, keep: &keep, pooled: &pooled) {
                processed[i] = t
            }
        }

        // A depth composition: each pass (back on top of the frame, front
        // below) is drawn alone and runs through the clip's effects; the
        // shadow its elements cast is made from their alpha.
        var depthPasses: [Int: (back: MTLTexture, front: MTLTexture, shadow: MTLTexture)] = [:]
        for (i, (pb, layer)) in layers.enumerated() where layer.opacity > 0 {
            guard let d = layer.depth else { continue }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb) / 2
            guard let back = drawAlone(cmd, pb, layer, quad: Self.halfFrame(0), width: w, height: h, hdr: hdr, seed: seed, keep: &keep, pooled: &pooled),
                  let front = drawAlone(cmd, pb, layer, quad: Self.halfFrame(1), width: w, height: h, hdr: hdr, seed: seed, keep: &keep, pooled: &pooled) else { continue }
            var shadow = noShadow
            if d.shadowOpacity > 0, d.shadowFromBack || d.shadowFromFront {
                let scale = Self.pixelScale(layer, sourceWidth: Double(w), sourceHeight: Double(h), canvasWidth: width, canvasHeight: height)
                let sigma = d.shadowBlur * width / max(1, d.referenceWidth) / max(scale, 1e-6) / Double(Self.shadowDownscale) / 2
                if let t = makeShadow(cmd, back: back, front: front, d, sigma: sigma, pooled: &pooled) { shadow = t }
            }
            depthPasses[i] = (back, front, shadow)
        }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: Self.pass(canvas, clear: .init(red: 0, green: 0, blue: 0, alpha: 1))) else {
            done(RenderError.setup)
            return
        }
        enc.setFragmentSamplerState(sampler, index: 0)
        for (i, (pb, layer)) in layers.enumerated() {
            guard layer.opacity > 0 else { continue }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            if let d = layer.depth {
                let matte = subjectOf[i].flatMap { screenMatte[$0] } ?? noPerson
                if let passes = depthPasses[i] {
                    encodeDepth(enc, passes, layer, d, sourceWidth: Double(w), sourceHeight: Double(h) / 2,
                                matte: matte, hdr: hdr, width: width, height: height)
                }
                continue
            }
            var quad = Self.quad(layer, sourceWidth: Double(w), sourceHeight: Double(h), canvasWidth: width, canvasHeight: height)
            if let tex = processed[i] {
                var opacity = Float(layer.opacity)
                enc.setRenderPipelineState(composite)
                enc.setFragmentTexture(tex, index: 0)
                enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
                enc.setVertexBytes(&quad, length: MemoryLayout<QuadVertex>.stride * 4, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            } else if let held = encodeSource(enc, pb, layer, hdr: hdr, seed: seed, quad: &quad) {
                keep += held
            }
        }
        enc.endEncoding()
        if toSDR {
            guard let view = cmd.makeRenderCommandEncoder(descriptor: Self.pass(outputTexture, clear: .init(red: 0, green: 0, blue: 0, alpha: 1))) else {
                done(RenderError.setup)
                return
            }
            var rollOff: Float = layers.contains { ($0.1.sourceSpace ?? FrameSpace($0.0)) == .hlg } ? 1 : 0
            var full = Self.fullFrame
            view.setRenderPipelineState(sdrView)
            view.setFragmentSamplerState(sampler, index: 0)
            view.setFragmentTexture(canvas, index: 0)
            view.setFragmentBytes(&rollOff, length: MemoryLayout<Float>.stride, index: 0)
            view.setVertexBytes(&full, length: MemoryLayout<QuadVertex>.stride * 4, index: 0)
            view.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            view.endEncoding()
        }
        let held = Unchecked((keep, pooled, pool))   // textures must live until the GPU is done
        cmd.addCompletedHandler { cb in
            held.value.2.give(held.value.1)
            _ = held.value.0
            done(cb.error)
        }
        cmd.commit()
    }

    /// Draws one decoded frame with its look into the current pass. Returns
    /// the textures that must live until the GPU is done, or nil when the
    /// frame cannot be read.
    private func encodeSource(_ enc: MTLRenderCommandEncoder, _ pb: CVPixelBuffer, _ layer: RenderLayer,
                              hdr: Bool, seed: Float, quad: inout [QuadVertex]) -> [CVMetalTexture]? {
        let src = layer.sourceSpace ?? FrameSpace(pb)
        var params = LayerParams(matrix: Self.matrix(pb), range: Self.range(pb), opacity: Float(layer.opacity),
                                 mode: hdr ? (src == .sdr ? 1 : 0) : (src == .hlg ? 2 : 0), alpha: 0)
        let format = CVPixelBufferGetPixelFormatType(pb)
        if debugRender {
            let code = String(bytes: [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "?"
            FileHandle.standardError.write(Data("[render] layer format \(code) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) opacity \(layer.opacity) effects \(layer.effects.count)\n".utf8))
        }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var held: [CVMetalTexture] = []
        switch format {
        case kCVPixelFormatType_4444AYpCbCr16:
            guard let t = texture(pb, plane: 0, format: .rgba16Unorm) else { return nil }
            held.append(t)
            enc.setRenderPipelineState(ayuv)
            enc.setFragmentTexture(CVMetalTextureGetTexture(t), index: 0)
            params.alpha = 1
        case kCVPixelFormatType_32BGRA:
            guard let t = texture(pb, plane: 0, format: .bgra8Unorm) else { return nil }
            held.append(t)
            enc.setRenderPipelineState(rgb)
            enc.setFragmentTexture(CVMetalTextureGetTexture(t), index: 0)
            params.alpha = 1
        default:
            let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            guard let y = texture(pb, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm),
                  let c = texture(pb, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm) else { return nil }
            held += [y, c]
            enc.setRenderPipelineState(biplanar)
            enc.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
            enc.setFragmentTexture(CVMetalTextureGetTexture(c), index: 1)
        }
        var look = layer.look.values
        if look[4].y > 0.5 {
            look[4].z = seed
            // Clarity's radius follows the picture, not its pixels: the
            // same frame in preview and in a 4K export gets the same look.
            look[5] = [1 / Float(w), 1 / Float(h), max(2, 0.008 * Float(max(w, h))), 0]
        }
        enc.setFragmentBytes(&look, length: MemoryLayout<SIMD4<Float>>.stride * look.count, index: 1)
        enc.setVertexBytes(&quad, length: MemoryLayout<QuadVertex>.stride * 4, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<LayerParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return held
    }

    /// Draws a layer alone at its own size, from the part of its frame that
    /// `quad` reads, and runs its effects on it. The result is premultiplied
    /// RGBA in the output's colour space, at full opacity.
    private func drawAlone(_ cmd: MTLCommandBuffer, _ pb: CVPixelBuffer, _ layer: RenderLayer, quad: [QuadVertex],
                           width w: Int, height h: Int, hdr: Bool, seed: Float,
                           keep: inout [CVMetalTexture], pooled: inout [MTLTexture]) -> MTLTexture? {
        let mips = layer.effects.contains { $0.mipmaps }
        var a = pool.take(device, w, h, mipmaps: mips)
        pooled.append(a)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: Self.pass(a, clear: .init(red: 0, green: 0, blue: 0, alpha: 0))) else { return nil }
        enc.setFragmentSamplerState(sampler, index: 0)
        var plain = layer
        plain.opacity = 1
        var q = quad
        guard let held = encodeSource(enc, pb, plain, hdr: hdr, seed: seed, quad: &q) else { enc.endEncoding(); return nil }
        keep += held
        enc.endEncoding()
        guard !layer.effects.isEmpty else { return a }
        var b = pool.take(device, w, h, mipmaps: mips)
        pooled.append(b)
        var ctx = FXContext(size: [Float(w), Float(h)], texel: [1 / Float(w), 1 / Float(h)], progress: 0, time: 0,
                            scale: Float(min(w, h)) / 1080, seed: seed, pass: 0)
        for fx in layer.effects {
            ctx.progress = fx.progress
            ctx.time = fx.time
            var params = fx.params
            for (n, pipe) in fx.pipelines.value.enumerated() {
                if fx.mipmaps, let blit = cmd.makeBlitCommandEncoder() {
                    blit.generateMipmaps(for: a)
                    blit.endEncoding()
                }
                guard let e = cmd.makeRenderCommandEncoder(descriptor: Self.pass(b, clear: nil)) else { continue }
                ctx.pass = Int32(n)
                e.setRenderPipelineState(pipe)
                e.setFragmentTexture(a, index: 0)
                e.setFragmentTexture(noMatte, index: 1)
                e.setFragmentSamplerState(effectSampler, index: 0)
                e.setFragmentBytes(&ctx, length: MemoryLayout<FXContext>.stride, index: 0)
                e.setFragmentBytes(&params, length: MemoryLayout<Float>.stride * params.count, index: 1)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                e.endEncoding()
                swap(&a, &b)
            }
        }
        return a
    }

    /// A frame that comes out the same drawn straight in SDR as drawn in
    /// HLG and converted back: one opaque SDR picture with no effect or
    /// depth, so nothing blends and nothing runs in HLG's values.
    private static func needsNoHLG(_ layers: [(CVPixelBuffer, RenderLayer)]) -> Bool {
        guard layers.count == 1, let (pb, layer) = layers.first else { return false }
        let withAlpha = [kCVPixelFormatType_4444AYpCbCr16, kCVPixelFormatType_32BGRA].contains(CVPixelBufferGetPixelFormatType(pb))
        return !withAlpha && layer.opacity >= 1 && layer.effects.isEmpty && layer.depth == nil
            && (layer.sourceSpace ?? FrameSpace(pb)) == .sdr
    }

    /// The shadow is made at this fraction of the layer's size.
    static let shadowDownscale = 4

    /// The blurred alpha of the passes that cast the shadow, `sigma` in
    /// shadow texels.
    private func makeShadow(_ cmd: MTLCommandBuffer, back: MTLTexture, front: MTLTexture, _ d: DepthLayer, sigma: Double,
                            pooled: inout [MTLTexture]) -> MTLTexture? {
        let sw = max(1, back.width / Self.shadowDownscale), sh = max(1, back.height / Self.shadowDownscale)
        let a = pool.take(device, sw, sh, mipmaps: false), b = pool.take(device, sw, sh, mipmaps: false)
        pooled += [a, b]
        var full = Self.fullFrame
        func run(_ target: MTLTexture, _ pipe: MTLRenderPipelineState, _ textures: [MTLTexture], _ p: SIMD4<Float>) -> Bool {
            guard let e = cmd.makeRenderCommandEncoder(descriptor: Self.pass(target, clear: .init(red: 0, green: 0, blue: 0, alpha: 0))) else { return false }
            var p = p
            e.setRenderPipelineState(pipe)
            for (k, t) in textures.enumerated() { e.setFragmentTexture(t, index: k) }
            e.setFragmentSamplerState(sampler, index: 0)
            e.setFragmentBytes(&p, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            e.setVertexBytes(&full, length: MemoryLayout<QuadVertex>.stride * 4, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e.endEncoding()
            return true
        }
        // Each shadow texel averages the 4x4 layer pixels under it.
        guard run(a, shadowAlphaPipeline, [back, front], [d.shadowFromBack ? 1 : 0, d.shadowFromFront ? 1 : 0, 1 / Float(back.width), 1 / Float(back.height)]),
              run(b, shadowBlurPipeline, [a], [1 / Float(sw), 0, Float(sigma), 0]),
              run(a, shadowBlurPipeline, [b], [0, 1 / Float(sh), Float(sigma), 0]) else { return nil }
        return a
    }

    /// Draws a depth composition: the shadow its elements cast on the wall,
    /// the back pass, both cut by the person, the lit outline, the front pass.
    private func encodeDepth(_ enc: MTLRenderCommandEncoder, _ passes: (back: MTLTexture, front: MTLTexture, shadow: MTLTexture),
                             _ layer: RenderLayer, _ d: DepthLayer, sourceWidth sw: Double, sourceHeight sh: Double,
                             matte: MTLTexture, hdr: Bool, width: Double, height: Double) {
        let px = width / max(1, d.referenceWidth)
        let scale = Self.pixelScale(layer, sourceWidth: sw, sourceHeight: sh, canvasWidth: width, canvasHeight: height)
        let shadowOn = passes.shadow !== noShadow
        var depth: [SIMD4<Float>] = [
            SIMD4(d.edgeColor, Float(d.edgeStrength)),
            [Float(d.edgeRadius * px), Float(d.softness * px), Float(d.cutInset * px), Float(d.cutSoftness * px)],
            [Float(d.profileFullTo), Float(d.profileZeroAt), Float(width), Float(height)],
            [hdr ? 1 : 0, d.cutWide ? 1 : 0, Float(layer.opacity), 0],
            SIMD4(d.shadowColor, shadowOn ? Float(d.shadowOpacity) : 0),
            [Float(d.shadowOffset.x * px / max(sw * scale, 1e-6)), Float(d.shadowOffset.y * px / max(sh * scale, 1e-6)), 0, 0],
        ]
        var quad = Self.quad(layer, sourceWidth: sw, sourceHeight: sh, canvasWidth: width, canvasHeight: height)
        enc.setRenderPipelineState(depthPipeline)
        enc.setFragmentTexture(passes.back, index: 0)
        enc.setFragmentTexture(matte, index: 1)
        enc.setFragmentTexture(passes.front, index: 2)
        enc.setFragmentTexture(passes.shadow, index: 3)
        enc.setFragmentBytes(&depth, length: MemoryLayout<SIMD4<Float>>.stride * depth.count, index: 1)
        enc.setVertexBytes(&quad, length: MemoryLayout<QuadVertex>.stride * 4, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static func pass(_ t: MTLTexture, clear: MTLClearColor?) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t
        pass.colorAttachments[0].loadAction = clear == nil ? .dontCare : .clear
        if let clear { pass.colorAttachments[0].clearColor = clear }
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// The whole target, with texture coordinates in stored-frame order.
    static let fullFrame: [QuadVertex] = [
        QuadVertex(position: [-1, 1], uv: [0, 0]), QuadVertex(position: [1, 1], uv: [1, 0]),
        QuadVertex(position: [-1, -1], uv: [0, 1]), QuadVertex(position: [1, -1], uv: [1, 1]),
    ]

    /// The whole target, reading the top (0) or bottom (1) half of the frame.
    static func halfFrame(_ half: Int) -> [QuadVertex] {
        let v0: Float = half == 0 ? 0 : 0.5, v1 = v0 + 0.5
        return [
            QuadVertex(position: [-1, 1], uv: [0, v0]), QuadVertex(position: [1, 1], uv: [1, v0]),
            QuadVertex(position: [-1, -1], uv: [0, v1]), QuadVertex(position: [1, -1], uv: [1, v1]),
        ]
    }

    enum RenderError: Error { case setup }

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache else { return nil }
        let planar = CVPixelBufferGetPlaneCount(pb) > 0
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &t)
        return t
    }

    // MARK: geometry

    struct QuadVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    /// Corners of a layer in clip space, with their source coordinates, in
    /// triangle-strip order: top-left, top-right, bottom-left, bottom-right.
    static func quad(_ l: RenderLayer, sourceWidth sw: Double, sourceHeight sh: Double,
                     canvasWidth cw: Double, canvasHeight ch: Double) -> [QuadVertex] {
        let t = l.transform
        let r = ((l.sourceRotation % 360) + 360) % 360
        // Crop is given for the picture as shown; turn it into stored-frame edges.
        let (cl, ct, cr, cb): (Double, Double, Double, Double) = switch r {
        case 90: (t.cropTop, t.cropRight, t.cropBottom, t.cropLeft)
        case 180: (t.cropRight, t.cropBottom, t.cropLeft, t.cropTop)
        case 270: (t.cropBottom, t.cropLeft, t.cropTop, t.cropRight)
        default: (t.cropLeft, t.cropTop, t.cropRight, t.cropBottom)
        }
        // Source rectangle left after cropping, in texture coordinates.
        let u0 = cl, u1 = 1 - cr, v0 = ct, v1 = 1 - cb
        var w = sw * (u1 - u0), h = sh * (v1 - v0)
        // Texture corners in on-screen order before the stored rotation.
        var corners: [SIMD2<Double>] = [[u0, v0], [u1, v0], [u0, v1], [u1, v1]]
        if r == 90 || r == 270 { swap(&w, &h) }
        // Rotating the picture clockwise means the top-left of the screen shows
        // what was the bottom-left of the stored frame (for 90°).
        switch r {
        case 90: corners = [corners[2], corners[0], corners[3], corners[1]]
        case 180: corners = [corners[3], corners[2], corners[1], corners[0]]
        case 270: corners = [corners[1], corners[3], corners[0], corners[2]]
        default: break
        }
        let base = t.fit == .fit ? min(cw / w, ch / h) : max(cw / w, ch / h)
        let hw = w * base * t.scale / 2, hh = h * base * t.scale / 2
        let cx = t.x * cw, cy = t.y * ch
        let a = t.rotation * .pi / 180
        let (ca, sa) = (cos(a), sin(a))
        let offsets: [SIMD2<Double>] = [[-hw, -hh], [hw, -hh], [-hw, hh], [hw, hh]]
        return zip(offsets, corners).map { o, uv in
            // Rotate clockwise on screen (y grows downward).
            let px = cx + o.x * ca - o.y * sa
            let py = cy + o.x * sa + o.y * ca
            return QuadVertex(position: [Float(px / cw * 2 - 1), Float(1 - py / ch * 2)], uv: [Float(uv.x), Float(uv.y)])
        }
    }

    /// Output pixels per source pixel of a layer (rotation 0).
    static func pixelScale(_ l: RenderLayer, sourceWidth sw: Double, sourceHeight sh: Double,
                           canvasWidth cw: Double, canvasHeight ch: Double) -> Double {
        let t = l.transform
        let w = sw * (1 - t.cropLeft - t.cropRight), h = sh * (1 - t.cropTop - t.cropBottom)
        let base = t.fit == .fit ? min(cw / w, ch / h) : max(cw / w, ch / h)
        return base * t.scale
    }

    // MARK: colour

    /// Y'CbCr to R'G'B' matrix for the frame's tagged matrix.
    static func matrix(_ pb: CVPixelBuffer) -> simd_float3x3 {
        let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let (kr, kb): (Float, Float)
        if m == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
            (kr, kb) = (0.2627, 0.0593)
        } else if m == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
            (kr, kb) = (0.299, 0.114)
        } else {
            (kr, kb) = (0.2126, 0.0722)
        }
        let kg = 1 - kr - kb
        return simd_float3x3(columns: (
            SIMD3(1, 1, 1),
            SIMD3(0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb)),
            SIMD3(2 * (1 - kr), -2 * kr * (1 - kr) / kg, 0)))
    }

    /// Offsets and scales that turn stored code values into 0-1 luma and
    /// -0.5 to 0.5 chroma.
    static func range(_ pb: CVPixelBuffer) -> SIMD4<Float> {
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            // 10-bit codes in the top bits of 16-bit words.
            return [64 * 64 / 65535, 65535 / (876 * 64), 512 * 64 / 65535, 65535 / (896 * 64)]
        case kCVPixelFormatType_4444AYpCbCr16:
            return [4096 / 65535, 65535 / 56064, 32768 / 65535, 65535 / 57344]
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return [16 / 255, 255 / 219, 128 / 255, 255 / 224]
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return [0, 1, 512 * 64 / 65535, 1]
        default:
            return [0, 1, 128 / 255, 1]
        }
    }
}

/// Must match `LayerParams` in the shader source.
struct LayerParams {
    var yuvToRGB: simd_float3x3
    var range: SIMD4<Float>
    var opacity: Float
    var mode: Int32
    var alpha: Int32
    var pad: Int32 = 0

    init(matrix: simd_float3x3, range: SIMD4<Float>, opacity: Float, mode: Int32, alpha: Int32) {
        self.yuvToRGB = matrix
        self.range = range
        self.opacity = opacity
        self.mode = mode
        self.alpha = alpha
    }
}

/// Offscreen textures for effect passes, reused frame after frame so
/// playback allocates nothing.
final class TexturePool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [String: [MTLTexture]] = [:]

    func take(_ device: MTLDevice, _ w: Int, _ h: Int, mipmaps: Bool) -> MTLTexture {
        if let t = lock.withLock({ free[Self.key(w, h, mipmaps)]?.popLast() }) { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: mipmaps)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    static func key(_ w: Int, _ h: Int, _ m: Bool) -> String { "\(w)x\(h)\(m ? "m" : "")" }

    func give(_ ts: [MTLTexture]) {
        lock.withLock {
            for t in ts {
                let k = Self.key(t.width, t.height, t.mipmapLevelCount > 1)
                if (free[k]?.count ?? 0) < 8 { free[k, default: []].append(t) }
            }
        }
    }
}

/// Carries a value the compiler cannot prove thread-safe across a callback
/// boundary, where the code guarantees only one side touches it at a time.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Set DME_DEBUG_RENDER to log every layer's pixel format and missing frames.
let debugRender = ProcessInfo.processInfo.environment["DME_DEBUG_RENDER"] != nil
