import Accelerate
import AVFoundation
import CoreVideo
import EditorCore
import EditorKit
import Foundation

/// A depth composition on the timeline: when its outline is lit and how.
struct DepthInfo {
    var clip: Clip
    var edges: [ClosedRange<Double>]
    var settings: UserSettings.MatteSettings
    /// Half an output frame: the edge is timed at the middle of each frame.
    var halfFrame: Time

    func layer(at t: Time) -> DepthLayer {
        let e = settings.edge
        var d = DepthLayer()
        d.edgeColor = Self.color(e.color)
        d.referenceWidth = e.referenceWidth
        d.softness = e.softness
        d.cutInset = settings.cutInset
        d.cutSoftness = settings.cutSoftness
        d.cutWide = settings.cutWith == "wide"
        d.profileFullTo = e.profileFullTo
        d.profileZeroAt = e.profileZeroAt
        let sh = settings.shadow
        if sh.enabled {
            d.shadowOpacity = max(0, min(1, sh.opacity))
            d.shadowColor = Self.color(sh.color)
            d.shadowOffset = [sh.offsetX, sh.offsetY]
            d.shadowBlur = max(0, sh.blur)
            d.shadowFromBack = sh.from != "front"
            d.shadowFromFront = sh.from != "back"
        }
        let now = clip.sourceTime(at: t + halfFrame).seconds
        guard let w = edges.first(where: { $0.lowerBound <= now && now < $0.upperBound }) else { return d }
        let tau = now - w.lowerBound
        d.edgeRadius = tau < e.riseSeconds ? e.peakRadius * tau / max(e.riseSeconds, 1e-6)
            : tau < e.riseSeconds + e.settleSeconds ? e.peakRadius - (e.peakRadius - e.restRadius) * (tau - e.riseSeconds) / max(e.settleSeconds, 1e-6)
            : e.restRadius
        let n = Int(tau * e.blinkFps)
        let fade = e.fadeOutSeconds > 0 ? min(1, max(0, (w.upperBound - now) / e.fadeOutSeconds)) : 1
        d.edgeStrength = fade * (n < e.blink.count ? e.blink[n] : 1)
        return d
    }

    /// "#RRGGBB" as 0-1 RGB; white if it cannot be read.
    static func color(_ hex: String) -> SIMD3<Float> {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return [1, 1, 1] }
        return [Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255]
    }
}

/// What to draw during one stretch of the timeline: the visible clips, bottom
/// to top, each with the composition track that carries its frames.
final class LayerInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    struct Entry {
        var trackID: CMPersistentTrackID
        var layer: RenderLayer
        /// Set when the clip has keyframes or effects, which change frame by frame.
        var animated: Clip? = nil
        /// False for a track that is only decoding ahead of its clip.
        var draw = true
        /// The track carrying this clip's person matte, if it has one.
        var matteTrackID: CMPersistentTrackID? = nil
        /// Set for a depth composition.
        var depth: DepthInfo? = nil
        /// A still picture's frame, drawn instead of the track's.
        var still: CVPixelBuffer? = nil
        /// The clip's look, read from the composition's table at each frame.
        var lookID: EntityID? = nil

        /// The layer at timeline time `t`.
        func layer(at t: Time, looks: LookTable) -> RenderLayer {
            var l = layer
            if let lookID { l.look = looks.uniforms(lookID) }
            if let depth { l.depth = depth.layer(at: t) }
            guard let c = animated else { return l }
            (l.transform, l.opacity) = c.animated(at: t)
            let offset = t - c.start
            l.effects = c.effects.compactMap { EffectCatalog.shared.active($0, offset: offset, clipDuration: c.duration) }
            return l
        }
    }

    let timeRange: CMTimeRange
    let entries: [Entry]
    let hdr: Bool
    /// An HLG frame handed over as SDR, for preview.
    let sdrPreview: Bool
    /// How SDR output is to be read on screen.
    let gamma: UserSettings.PreviewSettings.Gamma
    let looks: LookTable

    let enablePostProcessing = false
    /// True: every output frame is rendered, even when no source frame
    /// changes. Needed when the output frame rate is above a source's (a
    /// 30 fps file in a 60 fps project or export) and for effects and
    /// keyframes, which change every frame (measured: false gave 61 of 120
    /// frames in a 60 fps export of 30 fps footage).
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]? {
        var ids: [CMPersistentTrackID] = []
        for e in entries {
            if !ids.contains(e.trackID) { ids.append(e.trackID) }
            if let m = e.matteTrackID, !ids.contains(m) { ids.append(m) }
        }
        return ids.map { NSNumber(value: $0) }
    }

    init(timeRange: CMTimeRange, entries: [Entry], hdr: Bool, sdrPreview: Bool,
         gamma: UserSettings.PreviewSettings.Gamma, looks: LookTable) {
        self.timeRange = timeRange
        self.entries = entries
        self.hdr = hdr
        self.sdrPreview = sdrPreview
        self.gamma = gamma
        self.looks = looks
    }
}

/// The custom compositor AVFoundation calls for every frame, in preview,
/// frame capture and export alike, so all three show the same picture
/// (an SDR preview of an HLG project is that picture, converted last).
final class LayerCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: RenderGraph.sourcePixelFormats.map { NSNumber(value: $0) },
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    var supportsHDRSourceFrames: Bool { true }
    var supportsWideColorSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? LayerInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "dme.render", code: 1))
            return
        }
        tag(output, hdr: instruction.hdr && !instruction.sdrPreview, gamma: instruction.gamma)
        // A track with no picture at this moment (a gap) is simply skipped;
        // with nothing at all the frame is black.
        var layers: [(CVPixelBuffer, RenderLayer)] = []
        var mattes: [Int: CVPixelBuffer] = [:]
        let now = time(request.compositionTime)
        for e in instruction.entries where e.draw {
            if let pb = e.still ?? request.sourceFrame(byTrackID: e.trackID) {
                layers.append((pb, e.layer(at: now, looks: instruction.looks)))
                if let m = e.matteTrackID, let mp = request.sourceFrame(byTrackID: m) { mattes[layers.count - 1] = mp }
            } else {
                MissedFrames.record(request.compositionTime)
            }
            if debugRender, request.sourceFrame(byTrackID: e.trackID) == nil {
                FileHandle.standardError.write(Data("[render] no frame from track \(e.trackID) at \(request.compositionTime.seconds)\n".utf8))
            }
        }
        let out = Unchecked(output)
        let seed = Float(request.compositionTime.seconds.truncatingRemainder(dividingBy: 1000))
        RenderGraph.shared.render(layers, mattes: mattes, into: output, hdr: instruction.hdr, sdrPreview: instruction.sdrPreview, seed: seed) { error in
            if let error { request.finish(with: error) } else { request.finish(withComposedVideoFrame: out.value) }
        }
    }

    private func tag(_ pb: CVPixelBuffer, hdr: Bool, gamma: UserSettings.PreviewSettings.Gamma) {
        let tags: [(CFString, CFString)] = hdr ? [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020),
        ] : [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (k, v) in tags { CVBufferSetAttachment(pb, k, v, .shouldPropagate) }
        if !hdr, let space = gamma == .edits ? Self.cameraSpace : Self.videoSpace {
            CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(pb, kCVImageBufferCGColorSpaceKey)
        }
    }

    /// Rec.709 with the camera curve of BT.709, as Edits shows an SDR project
    /// (preview gamma `edits`). Spelled out, because neither shortcut gives
    /// it: `CGColorSpace.itur_709` is gamma 2.4 (128 as 121, Edits 141), and
    /// the tags alone mean this curve to the player but 1.961 to the image
    /// generators that make the stills drawn over it (measured). The
    /// constants are the precise ones: with the rounded 1.099 and 0.018
    /// macOS puts `itur_709` in its place (measured).
    private static let cameraSpace: CGColorSpace? = {
        var primaries = vImageRGBPrimaries(red_x: 0.640, green_x: 0.300, blue_x: 0.150, white_x: 0.3127,
                                           red_y: 0.330, green_y: 0.600, blue_y: 0.060, white_y: 0.3290)
        var curve = vImageTransferFunction(c0: 1.0992968, c1: 1, c2: 0, c3: -0.0992968, gamma: 0.45, cutoff: 0.018054, c4: 4.5, c5: 0)
        var error = vImage_Error(kvImageNoError)
        return vImageCreateRGBColorSpaceWithPrimariesAndTransferFunction(&primaries, &curve, .defaultIntent, vImage_Flags(kvImageNoFlags), &error)?.takeRetainedValue()
    }()

    /// Rec.709 as macOS shows video files in it (gamma 1.961). It has to be
    /// attached: from the three tags alone the player reads a compositor's
    /// frames with the camera curve (grey 8 showed as 20 where a plain player
    /// and CapCut show 4 to 7, measured on screen).
    private static let videoSpace: CGColorSpace? = CVImageBufferCreateColorSpaceFromAttachments([
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
    ] as CFDictionary)?.takeRetainedValue()
}
