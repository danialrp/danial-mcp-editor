import ImageIO
import Accelerate
import AVFoundation
import EditorCore
import EditorKit
import Foundation

/// A project turned into what AVFoundation plays and exports: the composition
/// (which frames and samples come from where), the video composition (how
/// layers are drawn) and the audio mix (gains and fades).
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition?
    public let audioMix: AVAudioMix?
    public let duration: Time
    public let frameRate: FrameRate
    public let hdr: Bool
    /// An HLG project handed over as SDR, for preview only.
    public let sdrPreview: Bool
    /// How its SDR frames are read on screen; only the preview differs from `video`.
    public let gamma: UserSettings.PreviewSettings.Gamma
    public let buildSeconds: Double
    /// The looks the compositor reads at every frame (see `LookTable`).
    public let looks: LookTable
    /// Stretches whose frames come out right only when decoded in order from
    /// `from` (the first frames of clips with a lead-in; see `DecodeStart`).
    /// Jumping straight into them can give another frame of the file.
    public var inOrderOnly: [(start: Time, end: Time, from: Time)] = []
    /// Composition tracks carrying person mattes, by timeline track.
    public var matteTracks: [EntityID: CMPersistentTrackID] = [:]
    /// Set when a clip at 0 s must be decoded from an earlier keyframe and
    /// has no room for its lead-in: the same timeline built `shift` later,
    /// where it has. Frames in `stretches` are read from there.
    public var preroll: Preroll?

    public final class Preroll: @unchecked Sendable {
        public let shift: Time
        public let stretches: [(start: Time, end: Time)]
        public let built: BuiltComposition
        init(shift: Time, stretches: [(start: Time, end: Time)], built: BuiltComposition) {
            self.shift = shift
            self.stretches = stretches
            self.built = built
        }
    }

    /// Puts new slider values into this composition's looks (and its
    /// pre-roll twin), for the frames drawn from now on.
    public func setLooks(_ looks: [Look]) {
        self.looks.set(looks)
        preroll?.built.setLooks(looks)
    }

    /// Where the frame at `t` must be read from, when this composition cannot give it.
    public func prerolled(at t: Time) -> (built: BuiltComposition, time: Time)? {
        guard let p = preroll, p.stretches.contains(where: { $0.start <= t && t < $0.end }) else { return nil }
        return (p.built, t + p.shift)
    }

    /// Where to start decoding in order so the frame at `t` is right, if a
    /// plain seek is not enough.
    public func inOrderStart(at t: Time) -> Time? {
        inOrderOnly.first { $0.start <= t && t < $0.end }.map { safeStart($0.from) }
    }

    /// `t`, or an earlier time where reading can start: never inside an
    /// in-order stretch. A reader that starts inside one waits forever for a
    /// frame the decoder cannot give (measured), so it starts at the lead-in
    /// instead, and earlier again if that lies inside another stretch.
    public func safeStart(_ t: Time) -> Time {
        var s = t
        for _ in 0..<64 {
            guard let r = inOrderOnly.first(where: { $0.start <= s && s < $0.end }) else { return s }
            s = r.from
        }
        return .zero
    }
}

public enum BuildError: Error, CustomStringConvertible {
    case missingFile(EntityID, String)
    case unreadable(EntityID, String)

    public var description: String {
        switch self {
        case .missingFile(let id, let path): "media \(id) is missing: \(path); relink it with media.relink"
        case .unreadable(let id, let why): "media \(id) cannot be read: \(why)"
        }
    }
}

/// Builds compositions from projects. Opened media files are kept between
/// builds, so rebuilding after an edit does not reopen them.
public actor CompositionBuilder {
    private struct Source {
        var fingerprint: String
        var asset: AVURLAsset
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        var rotation: Int
        var space: FrameSpace?
        var segments: [AVAssetTrackSegment] = []
    }

    private var sources: [EntityID: Source] = [:]
    /// Earlier decode starts by asset fingerprint and source start (see `DecodeStart`).
    private var decodeStarts: [String: (start: Time, keyframe: Time)?] = [:]

    /// A timeline track's video: the main composition track, spare tracks
    /// for clips that must be decoded from an earlier keyframe, and the
    /// stretches where a spare track decodes without being drawn.
    struct VisualTrack {
        var track: Track
        var main: CMPersistentTrackID
        var placement: [EntityID: CMPersistentTrackID]
        var leadIns: [(id: CMPersistentTrackID, from: Time, to: Time)]
        var inOrderOnly: [(start: Time, end: Time, from: Time)]
        var matte: CMPersistentTrackID? = nil
        /// First frames of clips at 0 s that need a lead-in and have no room.
        var unreachable: [(start: Time, end: Time)] = []
    }

    /// Rendered slices of each HyperFrames composition in use: composition
    /// time range and the slice's picture (nil where nothing is rendered yet).
    private var hfSlices: [EntityID: [(start: Double, end: Double, track: AVAssetTrack?)]] = [:]
    /// Slice files by path. The asset is kept with its track: a track whose
    /// asset is released cannot be inserted (error -12780, measured).
    private var sliceTracks: [String: (asset: AVURLAsset, track: AVAssetTrack)] = [:]
    /// Depth compositions in use and when their outline is lit.
    private var hfDepth: [EntityID: [ClosedRange<Double>]] = [:]
    /// Still pictures in use, decoded once: the frame the compositor draws.
    private var stills: [EntityID: (key: String, buffer: CVPixelBuffer)] = [:]
    /// Person matte chunks of footage in use: source time range and file.
    private var matteChunks: [EntityID: [(start: Double, end: Double, track: AVAssetTrack?)]] = [:]

    public init() {}

    /// `package` and `hyperframes` are needed only for projects with
    /// HyperFrames compositions. `sdrPreview` makes an HLG project come out
    /// in SDR for a display without HDR; it has no effect on an SDR project.
    /// `gamma` is for preview only: how SDR frames are read on screen.
    public func build(_ p: Project, package: URL? = nil, hyperframes: HyperFramesHost? = nil,
                      mattes: MatteStore? = nil, matteSettings: UserSettings.MatteSettings = .init(),
                      sdrPreview: Bool = false, gamma: UserSettings.PreviewSettings.Gamma = .video) async throws -> BuiltComposition {
        let t0 = Date()
        let used = Set(p.tracks.flatMap { $0.clips.map(\.asset) })
        hfSlices = [:]
        hfDepth = [:]
        matteChunks = [:]
        for a in p.media where used.contains(a.id) {
            if a.isHyperFrames { try await loadSlices(a, project: p.id, package: package, host: hyperframes) }
            else if a.isImage { try loadStill(a) }
            else { try await load(a) }
            if a.matte != nil, let mattes { await loadMattes(a, package: package, store: mattes) }
        }
        sources = sources.filter { used.contains($0.key) }
        stills = stills.filter { used.contains($0.key) }

        let comp = AVMutableComposition()
        let fps = p.settings.frameRate
        let hdr = p.settings.dynamicRange == .hlg
        let sdrPreview = hdr && sdrPreview
        // What AVFoundation is told; the shader still works in the project's range.
        let hdrOut = hdr && !sdrPreview
        var visual: [VisualTrack] = []
        var mixInputs: [AVMutableAudioMixInputParameters] = []

        for track in p.tracks {
            if track.kind != .audio, !track.hidden, track.clips.contains(where: { sources[$0.asset]?.video != nil || hfSlices[$0.asset] != nil || stills[$0.asset] != nil }) {
                let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                var v = try layVideo(track, main: ct, in: comp)
                if track.clips.contains(where: { matteChunks[$0.asset]?.contains { $0.track != nil } == true }) {
                    let mt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                    try insertMattes(track.clips, into: mt)
                    v.matte = mt.trackID
                }
                visual.append(v)
            }
            if !track.muted, track.clips.contains(where: { sources[$0.asset]?.audio != nil }) {
                let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try insert(track.clips, into: ct) { sources[$0]?.audio }
                mixInputs.append(mixParameters(track, trackID: ct.trackID))
            }
        }

        let duration = p.duration
        // The composition ends with its last real media; stills, HyperFrames
        // layers or empty space after that would cut playback short.
        if duration.ticks > 0, comp.duration < cm(duration) {
            let filler = try await Filler.track()
            let ft = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let one = CMTimeRange(start: .zero, duration: CMTime(seconds: Filler.seconds, preferredTimescale: 600))
            try withExtendedLifetime(filler.asset) { try ft.insertTimeRange(one, of: filler.track, at: .zero) }
            ft.scaleTimeRange(CMTimeRange(start: .zero, duration: one.duration), toDuration: cm(duration))
        }
        FrameSpace.retag(comp, hdr: hdrOut)
        let lookTable = LookTable(p.looks)
        var videoComposition: AVMutableVideoComposition?
        if !visual.isEmpty, duration.ticks > 0 {
            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = LayerCompositor.self
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.fps))
            vc.renderSize = CGSize(width: p.settings.width, height: p.settings.height)
            vc.colorPrimaries = hdrOut ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
            vc.colorTransferFunction = hdrOut ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
            vc.colorYCbCrMatrix = hdrOut ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
            vc.instructions = instructions(visual, duration: duration, hdr: hdr, sdrPreview: sdrPreview, gamma: gamma, looks: lookTable, matte: matteSettings,
                                           halfFrame: Time(ticks: fps.frameDuration.ticks / 2))
            videoComposition = vc
        }
        var audioMix: AVMutableAudioMix?
        if !mixInputs.isEmpty {
            audioMix = AVMutableAudioMix()
            audioMix!.inputParameters = mixInputs
        }
        var built = BuiltComposition(composition: comp.copy() as! AVComposition, videoComposition: videoComposition,
                                     audioMix: audioMix, duration: duration, frameRate: fps, hdr: hdr, sdrPreview: sdrPreview, gamma: gamma,
                                     buildSeconds: Date().timeIntervalSince(t0), looks: lookTable)
        built.inOrderOnly = visual.flatMap(\.inOrderOnly).sorted { $0.start < $1.start }
        for v in visual { if let m = v.matte { built.matteTracks[v.track.id] = m } }
        let unreachable = visual.flatMap(\.unreachable)
        if !unreachable.isEmpty {
            // One second later every clip has room for its lead-in.
            let shift = Time(ticks: fps.frameDuration.ticks * Int64(fps.fps))
            var later = p
            for t in later.tracks.indices {
                for c in later.tracks[t].clips.indices { later.tracks[t].clips[c].start = later.tracks[t].clips[c].start + shift }
            }
            let other = try await build(later, package: package, hyperframes: hyperframes, mattes: mattes,
                                        matteSettings: matteSettings, sdrPreview: sdrPreview, gamma: gamma)
            built.preroll = .init(shift: shift, stretches: unreachable, built: other)
        }
        return built
    }

    // MARK: private

    private func load(_ a: MediaAsset) async throws {
        if let s = sources[a.id], s.fingerprint == a.fingerprint, s.asset.url.path == a.path { return }
        guard FileManager.default.fileExists(atPath: a.path) else { throw BuildError.missingFile(a.id, a.path) }
        let asset = AVURLAsset(url: URL(fileURLWithPath: a.path), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let v = try await asset.loadTracks(withMediaType: .video).first
            let au = try await asset.loadTracks(withMediaType: .audio).first
            var rotation = 0
            var space: FrameSpace?
            if let v {
                space = try await v.load(.formatDescriptions).first.flatMap { FrameSpace(format: $0) }
                let t = try await v.load(.preferredTransform)
                rotation = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
            }
            let segments = try await v?.load(.segments) ?? []
            sources[a.id] = Source(fingerprint: a.fingerprint, asset: asset, video: v, audio: au, rotation: rotation, space: space, segments: segments)
        } catch {
            throw BuildError.unreadable(a.id, error.localizedDescription)
        }
    }

    /// Decodes a still picture once, upright and at most `maxStill` pixels
    /// on its longest side, into a BGRA buffer with straight alpha (what the
    /// render graph's RGB path expects).
    private func loadStill(_ a: MediaAsset) throws {
        let key = "\(a.fingerprint)|\(a.path)"
        if stills[a.id]?.key == key { return }
        let url = URL(fileURLWithPath: a.path)
        guard FileManager.default.fileExists(atPath: a.path) else { throw BuildError.missingFile(a.id, a.path) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maxStill, kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw BuildError.unreadable(a.id, "not a picture") }
        let w = img.width, h = img.height
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        guard let pb else { throw BuildError.unreadable(a.id, "out of memory for the picture") }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw BuildError.unreadable(a.id, "cannot draw the picture")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var buf = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        vImageUnpremultiplyData_RGBA8888(&buf, &buf, vImage_Flags(kvImageNoFlags))   // B G R A in memory: alpha last
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        stills[a.id] = (key, pb)
    }

    /// Longest side of a still as decoded: enough for a 4K frame.
    static let maxStill = 4096

    /// Lays a timeline track's clips onto composition tracks. Most go on the
    /// main one. A clip whose first frame cannot be decoded from where
    /// AVFoundation would start goes on a spare track, starting earlier at a
    /// keyframe, so its first frames come out when played or exported
    /// straight through. Spare tracks are reused when free.
    private func layVideo(_ track: Track, main: AVMutableCompositionTrack, in comp: AVMutableComposition) throws -> VisualTrack {
        var placement: [EntityID: CMPersistentTrackID] = [:]
        var leadIns: [(id: CMPersistentTrackID, from: Time, to: Time)] = []
        var lanes: [(track: AVMutableCompositionTrack, end: Time)] = []
        var onMain: [Clip] = []
        var inOrder: [(start: Time, end: Time, from: Time)] = []
        var unreachable: [(start: Time, end: Time)] = []
        for c in track.clips {
            guard let src = sources[c.asset], let v = src.video, let (early, keyframe) = decodeStart(c, src),
                  c.sourceDuration.ticks > 0 else {
                onMain.append(c)
                placement[c.id] = main.trackID
                continue
            }
            let leadSource = c.sourceStart - early
            // The lead-in plays at the clip's speed when there is room before
            // the clip; otherwise it is squeezed into the room there is (the
            // frames are decoded, not shown, so their timing does not matter;
            // measured down to 4 ms). A clip at 0 s has no room at all.
            let natural = Time(ticks: Int64((Double(leadSource.ticks) * Double(c.duration.ticks) / Double(c.sourceDuration.ticks)).rounded()))
            let from = Time.max(.zero, c.start - natural)
            let lead = c.start - from
            guard leadSource.ticks > 0, lead.ticks > 0 else {
                if leadSource.ticks > 0 {
                    let led = Time(ticks: Int64((Double((keyframe - c.sourceStart).ticks) * Double(c.duration.ticks) / Double(c.sourceDuration.ticks)).rounded()))
                    unreachable.append((c.start, Time.min(c.end, c.start + led)))
                }
                onMain.append(c)
                placement[c.id] = main.trackID
                continue
            }
            let lane: Int
            if let free = lanes.firstIndex(where: { $0.end <= from }) {
                lane = free
            } else {
                lanes.append((comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!, .zero))
                lane = lanes.count - 1
            }
            let ct = lanes[lane].track
            if from > lanes[lane].end {
                ct.insertEmptyTimeRange(CMTimeRange(start: cm(lanes[lane].end), duration: cm(from - lanes[lane].end)))
            }
            try ct.insertTimeRange(CMTimeRange(start: cm(early), duration: cm(c.sourceDuration + leadSource)), of: v, at: cm(from))
            if lead != leadSource {
                ct.scaleTimeRange(CMTimeRange(start: cm(from), duration: cm(leadSource)), toDuration: cm(lead))
            }
            if c.sourceDuration != c.duration {
                ct.scaleTimeRange(CMTimeRange(start: cm(c.start), duration: cm(c.sourceDuration)), toDuration: cm(c.duration))
            }
            lanes[lane].end = c.end
            placement[c.id] = ct.trackID
            leadIns.append((ct.trackID, from, c.start))
            let led = Time(ticks: Int64((Double((keyframe - c.sourceStart).ticks) * Double(c.duration.ticks) / Double(c.sourceDuration.ticks)).rounded()))
            inOrder.append((c.start, Time.min(c.end, c.start + led), from))
        }
        try insert(onMain, into: main) { sources[$0]?.video }
        return VisualTrack(track: track, main: main.trackID, placement: placement, leadIns: leadIns, inOrderOnly: inOrder,
                           unreachable: unreachable)
    }

    /// The earlier source time to decode a clip from, if it needs one.
    private func decodeStart(_ c: Clip, _ src: Source) -> (start: Time, keyframe: Time)? {
        let key = "\(src.fingerprint)@\(c.sourceStart.ticks)"
        if let known = decodeStarts[key] { return known }
        let t = src.video.flatMap { DecodeStart.leadIn($0, segments: src.segments, at: cm(c.sourceStart)) }.map { (time($0.start), time($0.keyframe)) }
        if decodeStarts.count > 20_000 { decodeStarts.removeAll() }
        decodeStarts[key] = t
        return t
    }

    /// Lays clips onto one composition track: empty space for gaps, the
    /// source range for each clip, scaled to the clip's length for speed.
    private func insert(_ clips: [Clip], into ct: AVMutableCompositionTrack,
                        source: (EntityID) -> AVAssetTrack?) throws {
        var cursor = Time.zero
        for c in clips {
            if c.start > cursor { ct.insertEmptyTimeRange(CMTimeRange(start: cm(cursor), duration: cm(c.start - cursor))) }
            if let slices = hfSlices[c.asset], source(c.asset) == nil, ct.mediaType == .video {
                try insertSlices(c, slices, into: ct)
            } else if let src = source(c.asset) {
                try ct.insertTimeRange(CMTimeRange(start: cm(c.sourceStart), duration: cm(c.sourceDuration)), of: src, at: cm(c.start))
                if c.sourceDuration != c.duration {
                    ct.scaleTimeRange(CMTimeRange(start: cm(c.start), duration: cm(c.sourceDuration)), toDuration: cm(c.duration))
                }
            } else {
                ct.insertEmptyTimeRange(CMTimeRange(start: cm(c.start), duration: cm(c.duration)))
            }
            cursor = c.end
        }
    }

    /// A track's person mattes: each clip's source range from the chunks of
    /// its file's matte; empty where a clip has none.
    private func insertMattes(_ clips: [Clip], into ct: AVMutableCompositionTrack) throws {
        var cursor = Time.zero
        for c in clips {
            if c.start > cursor { ct.insertEmptyTimeRange(CMTimeRange(start: cm(cursor), duration: cm(c.start - cursor))) }
            if let chunks = matteChunks[c.asset] {
                try insertSlices(c, chunks, into: ct)
            } else {
                ct.insertEmptyTimeRange(CMTimeRange(start: cm(c.start), duration: cm(c.duration)))
            }
            cursor = c.end
        }
    }

    /// Finds the matte chunks of a file: the current one, or an older one
    /// while it is being remade. A file whose matte cannot be listed (for
    /// example imported masks not yet copied in) simply has none.
    private func loadMattes(_ a: MediaAsset, package: URL?, store: MatteStore) async {
        guard let chunks = try? await store.chunks(a, package: package) else { return }
        var out: [(start: Double, end: Double, track: AVAssetTrack?)] = []
        for c in chunks {
            var track: AVAssetTrack?
            if let url = c.current ?? c.stale {
                if let t = sliceTracks[url.path] { track = t.track } else {
                    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    track = try? await asset.loadTracks(withMediaType: .video).first
                    if let track { sliceTracks[url.path] = (asset, track) }
                }
            }
            out.append((c.start, c.end, track))
        }
        matteChunks[a.id] = out
    }

    /// A HyperFrames clip: its composition time range taken from the slices
    /// that cover it, back to back; empty where a slice is not rendered.
    private func insertSlices(_ c: Clip, _ slices: [(start: Double, end: Double, track: AVAssetTrack?)],
                              into ct: AVMutableCompositionTrack) throws {
        var at = c.start
        let from = c.sourceStart, to = c.sourceEnd
        for s in slices {
            let s0 = Time(seconds: s.start), s1 = Time(seconds: s.end)
            let a = Time.max(from, s0), b = Time.min(to, s1)
            guard b > a else { continue }
            if let t = s.track {
                try ct.insertTimeRange(CMTimeRange(start: cm(a - s0), duration: cm(b - a)), of: t, at: cm(at))
            } else {
                ct.insertEmptyTimeRange(CMTimeRange(start: cm(at), duration: cm(b - a)))
            }
            at = at + (b - a)
        }
        if at < c.start + c.sourceDuration {
            ct.insertEmptyTimeRange(CMTimeRange(start: cm(at), duration: cm(c.start + c.sourceDuration - at)))
        }
        if c.sourceDuration != c.duration {
            ct.scaleTimeRange(CMTimeRange(start: cm(c.start), duration: cm(c.sourceDuration)), toDuration: cm(c.duration))
        }
    }

    /// Finds the slices of a composition: the current render of each, or an
    /// older one while it is stale.
    private func loadSlices(_ a: MediaAsset, project: EntityID, package: URL?, host: HyperFramesHost?) async throws {
        guard let package, let host else { hfSlices[a.id] = []; return }
        let c = try HyperFramesHost.composition(a, package: package)
        if c.depth { hfDepth[a.id] = c.edges }
        var out: [(start: Double, end: Double, track: AVAssetTrack?)] = []
        for s in try await host.slices(c, project: project) {
            var track: AVAssetTrack?
            if let url = s.current ?? s.stale {
                if let t = sliceTracks[url.path] { track = t.track } else {
                    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    track = try await asset.loadTracks(withMediaType: .video).first
                    if let track { sliceTracks[url.path] = (asset, track) }
                }
            }
            out.append((s.start, s.end, track))
        }
        hfSlices[a.id] = out
    }

    /// One instruction per stretch of time in which the set of visible clips
    /// does not change.
    private func instructions(_ visual: [VisualTrack], duration: Time, hdr: Bool, sdrPreview: Bool, gamma: UserSettings.PreviewSettings.Gamma, looks: LookTable,
                              matte: UserSettings.MatteSettings, halfFrame: Time) -> [LayerInstruction] {
        var cuts = Set<Int64>([0, duration.ticks])
        for v in visual {
            for c in v.track.clips { cuts.insert(c.start.ticks); cuts.insert(c.end.ticks) }
            for l in v.leadIns { cuts.insert(l.from.ticks) }
        }
        let times = cuts.filter { $0 <= duration.ticks }.sorted()
        var out: [LayerInstruction] = []
        for (a, b) in zip(times, times.dropFirst()) where b > a {
            let at = Time(ticks: a)
            var entries: [LayerInstruction.Entry] = []
            for v in visual {
                // Spare tracks decoding ahead of their clip: needed, not drawn.
                for l in v.leadIns where l.from <= at && at < l.to {
                    entries.append(.init(trackID: l.id, layer: RenderLayer(transform: .identity, opacity: 0, sourceRotation: 0), draw: false))
                }
                let t = v.track
                guard let i = t.clipIndex(containing: at) else { continue }
                let c = t.clips[i]
                let isHF = hfSlices[c.asset] != nil
                let still = stills[c.asset]?.buffer
                guard isHF || still != nil || sources[c.asset]?.video != nil else { continue }
                // Looks are for footage; graphics pass through untouched (C-3).
                let lookID = isHF ? nil : c.look ?? t.look
                var e = LayerInstruction.Entry(trackID: v.placement[c.id] ?? v.main, layer: RenderLayer(transform: c.transform, opacity: c.opacity,
                                                                     sourceRotation: sources[c.asset]?.rotation ?? 0),
                                               animated: c.keyframes.isEmpty && c.effects.isEmpty ? nil : c)
                e.lookID = lookID
                // HyperFrames renders are Rec.709; a still's buffer carries its own tags.
                if still == nil { e.layer.sourceSpace = isHF ? .sdr : sources[c.asset]?.space }
                e.still = still
                if !isHF, matteChunks[c.asset] != nil { e.matteTrackID = v.matte }
                if let edges = hfDepth[c.asset] {
                    e.depth = DepthInfo(clip: c, edges: edges, settings: matte, halfFrame: halfFrame)
                }
                entries.append(e)
            }
            out.append(LayerInstruction(timeRange: CMTimeRange(start: cm(Time(ticks: a)), duration: cm(Time(ticks: b - a))),
                                        entries: entries, hdr: hdr, sdrPreview: sdrPreview, gamma: gamma, looks: looks))
        }
        return out
    }

    /// Gains, fades and the short fades at joins, as volume ramps.
    private func mixParameters(_ track: Track, trackID: CMPersistentTrackID) -> AVMutableAudioMixInputParameters {
        let mp = AVMutableAudioMixInputParameters()
        mp.trackID = trackID
        mp.audioTimePitchAlgorithm = .spectral
        // Gains above 0 dB: ramps are scaled by the largest gain and a tap
        // multiplies the track back up (see GainTap).
        let boost = Float(max(1, track.clips.filter { !$0.muted }.map { pow(10, $0.gainDB / 20) }.max() ?? 1))
        if boost > 1.0001 { mp.audioTapProcessor = GainTap.make(gain: boost) }
        for (i, c) in track.clips.enumerated() {
            guard sources[c.asset]?.audio != nil else { continue }
            let gain = c.muted ? 0 : Float(pow(10, c.gainDB / 20)) / boost
            let touchesPrev = i > 0 && track.clips[i - 1].end == c.start
            let touchesNext = i + 1 < track.clips.count && track.clips[i + 1].start == c.end
            let half = Time(ticks: c.duration.ticks / 2)
            let fin = Time.min(half, Time.max(c.fadeIn, touchesPrev ? track.joinFade : .zero))
            let fout = Time.min(half, Time.max(c.fadeOut, touchesNext ? track.joinFade : .zero))
            if fin.ticks > 0 {
                mp.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain, timeRange: CMTimeRange(start: cm(c.start), duration: cm(fin)))
            } else {
                mp.setVolume(gain, at: cm(c.start))
            }
            if fout.ticks > 0 {
                mp.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0, timeRange: CMTimeRange(start: cm(c.end - fout), duration: cm(fout)))
            }
        }
        return mp
    }
}

func cm(_ t: Time) -> CMTime { CMTime(value: t.ticks, timescale: CMTimeScale(Time.ticksPerSecond)) }
func time(_ t: CMTime) -> Time { t.isNumeric ? Time(seconds: t.seconds) : .zero }
