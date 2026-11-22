import AVFoundation
import CryptoKit
import EditorCore
import EditorKit
import Foundation
import VideoToolbox

/// Exports a project (architecture section 14).
///
/// The timeline is cut into segments of a few seconds. Each segment is
/// rendered through the same compositor as the player, encoded on its own
/// (so it starts with a keyframe) and kept in a cache under a hash of
/// everything that affects its frames. Segments already in the cache are not
/// rendered again: an interrupted export continues where it stopped (R-3) and
/// after an edit only changed segments are rendered (R-4). The audio is
/// rendered in one pass, and the segments and the audio are joined into the
/// output without re-encoding.
public enum ExportEngine {
    public struct Report: Codable, Sendable {
        public var path: String
        public var preset: ExportPreset
        public var width: Int
        public var height: Int
        public var frameRate: Int
        public var dynamicRange: String
        public var duration: Double
        public var frames: Int
        public var segments: Int
        public var rendered: Int
        public var reused: Int
        public var renderSeconds: Double
        public var totalSeconds: Double
        public var projectRevision: Int
    }

    struct Segment: Sendable {
        var index: Int
        var start: Time
        var end: Time
        var frames: Int
        var hash: String
        var url: URL
    }

    /// Where segments of a project are kept.
    public static func cacheFolder(project: EntityID) -> URL {
        cacheRoot.appendingPathComponent(project.raw, isDirectory: true)
    }

    public static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DanialMCPEditor/export", isDirectory: true)
    }

    /// Changes whenever the way frames are rendered or encoded changes, so
    /// old cached segments are not reused.
    static let engineVersion = "export-4"

    public static func run(project source: Project, revision: Int, preset: ExportPreset, options: ExportOptions,
                           to output: URL, media: MediaContext, cacheFolder: URL? = nil,
                           progress: @escaping @Sendable (_ done: Int, _ total: Int, _ message: String) async throws -> Void) async throws -> Report {
        let t0 = Date()
        let issues = preset.problems()
        guard issues.isEmpty else { throw EditorError.invalid("export settings: " + issues.joined(separator: "; ")) }
        var p = source
        p.settings = preset.settings(for: source.settings)
        guard p.duration.ticks > 0 else { throw EditorError.invalid("the timeline is empty") }
        // HyperFrames compositions in use: render what is missing first, and
        // let their slice hashes stand for their content in the segment hashes.
        var hfDigest: [EntityID: String] = [:]
        let used = Set(p.tracks.flatMap { $0.clips.map(\.asset) })
        for a in p.media where a.isHyperFrames && used.contains(a.id) {
            guard let package = await media.editor.session?.url else { break }
            let c = try HyperFramesHost.composition(a, package: package)
            _ = try await media.hyperframes.render(c, project: p.id) { done, total, _ in
                try await progress(0, 1, "HyperFrames \(a.name): slice \(done) of \(total) rendered")
            }
            hfDigest[a.id] = try await media.hyperframes.slices(c, project: p.id).map(\.hash).joined(separator: ",")
        }
        // Person mattes of footage in use: make the chunks the timeline shows,
        // and let their hashes stand for them in the segment hashes.
        var matteDigest: [EntityID: [(start: Double, end: Double, hash: String)]] = [:]
        let matteSettings = media.editor.settings.current.matte
        for a in p.media where a.matte != nil && used.contains(a.id) {
            let package = await media.editor.session?.url
            let needed = MatteStore.needed(p, asset: a.id, chunkSeconds: matteSettings.chunkSeconds)
            _ = try await media.mattes.generate(a, package: package, only: needed) { done, total, _ in
                try await progress(0, 1, "matte of \(a.name): chunk \(done) of \(total) made")
            }
            matteDigest[a.id] = try await media.mattes.chunks(a, package: package).map { ($0.start, $0.end, $0.hash) }
        }
        let built = try await media.composition(for: p)
        let fps = p.settings.frameRate
        let frame = fps.frameDuration
        // A clip at 0 s with no room for its lead-in: the picture comes from
        // the timeline built later, where it has. The sound needs none.
        let picture = built.preroll?.built ?? built
        let preroll = built.preroll?.shift ?? .zero
        let totalFrames = Int((Double(p.duration.ticks) / Double(frame.ticks)).rounded())
        let segFrames = max(1, Int((options.segmentSeconds * Double(fps.fps)).rounded()))
        let folder = cacheFolder ?? Self.cacheFolder(project: p.id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("tmp"), withIntermediateDirectories: true)

        // Plan: segments with their hashes.
        var hasher = SegmentHasher(project: p, preset: preset, hyperframes: hfDigest)
        if options.speedOverQuality { hasher.encoder = Data("speedOverQuality".utf8) }
        hasher.mattes = matteDigest
        if !matteDigest.isEmpty || !hfDigest.isEmpty, let d = try? JSONEncoder().encode(matteSettings) { hasher.matteSettings = d }
        var segments: [Segment] = []
        var first = 0
        while first < totalFrames {
            let n = min(segFrames, totalFrames - first)
            let start = Time(ticks: frame.ticks * Int64(first)), end = Time(ticks: frame.ticks * Int64(first + n))
            let h = hasher.hash(start: start, end: end)
            segments.append(Segment(index: segments.count, start: start, end: end, frames: n, hash: h,
                                    url: folder.appendingPathComponent(h + ".mov")))
            first += n
        }
        let missing = segments.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        let reused = segments.count - missing.count
        try await progress(reused, segments.count, "\(reused) of \(segments.count) segments already rendered")

        // Render what is missing, a few at a time.
        let renderStart = Date()
        let settings = Unchecked(videoSettings(preset, p.settings, speedOverQuality: options.speedOverQuality))
        let parallel = max(1, options.parallelSegments)
        let counter = Counter(reused)
        let total = segments.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() {
                let s = missing[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let tmp = folder.appendingPathComponent("tmp/\(UUID().uuidString).mov")
                    let n = try await renderSegmentWithRetry(picture, s, offset: preroll, settings: settings.value, to: tmp)
                    guard n == s.frames else {
                        throw EditorError(.io, "segment \(s.index) gave \(n) frames instead of \(s.frames)")
                    }
                    try FileManager.default.moveItem(at: tmp, to: s.url)
                    let done = await counter.add()
                    try await progress(done, total, "segment \(s.index + 1) of \(total) rendered")
                }
            }
            for _ in 0..<min(parallel, missing.count) { launch() }
            while try await group.next() != nil {
                if next < missing.count { launch() }
            }
        }
        let renderSeconds = Date().timeIntervalSince(renderStart)
        try Task.checkCancellation()

        // Audio in one pass, then the join.
        try await progress(segments.count, segments.count, "rendering the sound")
        let audioURL: URL? = try await renderAudio(built, preset, to: folder.appendingPathComponent("tmp/\(UUID().uuidString).\(preset.audioCodec == .pcm ? "caf" : "m4a")"))
        try await progress(segments.count, segments.count, "joining")
        try await join(segments.map(\.url), audio: audioURL, duration: Time(ticks: frame.ticks * Int64(totalFrames)),
                       container: preset.container, to: output)

        return Report(path: output.path, preset: preset, width: p.settings.width, height: p.settings.height,
                      frameRate: fps.fps, dynamicRange: p.settings.dynamicRange.rawValue,
                      duration: Double(totalFrames) / Double(fps.fps), frames: totalFrames,
                      segments: segments.count, rendered: missing.count, reused: reused,
                      renderSeconds: renderSeconds, totalSeconds: Date().timeIntervalSince(t0), projectRevision: revision)
    }

    private actor Counter {
        var value: Int
        init(_ v: Int) { value = v }
        func add() -> Int { value += 1; return value }
    }

    // MARK: encoding settings

    static func colour(_ range: DynamicRange) -> [String: Any] {
        range == .hlg ? [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ] : [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }

    static func videoSettings(_ preset: ExportPreset, _ s: ProjectSettings, speedOverQuality: Bool = false) -> [String: Any] {
        var out: [String: Any] = [
            AVVideoWidthKey: s.width, AVVideoHeightKey: s.height,
            AVVideoColorPropertiesKey: colour(s.dynamicRange),
        ]
        let bitrate = Int((preset.videoBitrateMbps ?? 20) * 1_000_000)
        switch preset.videoCodec {
        case .hevc:
            out[AVVideoCodecKey] = AVVideoCodecType.hevc
            out[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: s.frameRate.fps,
                AVVideoMaxKeyFrameIntervalKey: s.frameRate.fps,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: speedOverQuality,
            ] as [String: Any]
        case .h264:
            out[AVVideoCodecKey] = AVVideoCodecType.h264
            out[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: s.frameRate.fps,
                AVVideoMaxKeyFrameIntervalKey: s.frameRate.fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: speedOverQuality,
            ] as [String: Any]
        case .prores422hq:
            out[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        case .prores4444:
            out[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        }
        return out
    }

    // MARK: video

    /// Renders and encodes one segment from a composition whose timeline
    /// is `offset` later than the project's. Reading starts where in-order
    /// decoding is safe (see DecodeStart) and frames before the segment are
    /// dropped. Returns the number of frames written.
    /// A segment whose reader got no frame for this long is read again from
    /// earlier. AVFoundation can wait forever for a frame it cannot decode
    /// from where reading started (open-GOP video in a strongly slowed clip,
    /// measured); reading from a few seconds before gets past it.
    static let stallSeconds = 20.0

    struct Stalled: Error {}

    /// Renders a segment; if reading stalls, again from 4 s earlier, then
    /// from the start of the timeline.
    static func renderSegmentWithRetry(_ built: BuiltComposition, _ s: Segment, offset: Time = .zero,
                                       settings: [String: Any], to url: URL) async throws -> Int {
        let starts: [Time?] = [nil, Time.max(.zero, s.start + offset - Time(seconds: 4)), .zero]
        for (i, from) in starts.enumerated() {
            do {
                if i > 0 { try? FileManager.default.removeItem(at: url) }
                return try await renderSegment(built, s, offset: offset, settings: settings, to: url, readFrom: from)
            } catch is Stalled where i < starts.count - 1 {
                continue
            }
        }
        throw EditorError(.io, "segment \(s.index) could not be read")
    }

    static func renderSegment(_ built: BuiltComposition, _ s: Segment, offset: Time = .zero, settings: [String: Any], to url: URL,
                              readFrom earlier: Time? = nil) async throws -> Int {
        let reader = try AVAssetReader(asset: built.composition)
        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
        out.videoComposition = built.videoComposition
        out.alwaysCopiesSampleData = false
        reader.add(out)
        let readFrom = built.safeStart(earlier ?? (s.start + offset))
        reader.timeRange = CMTimeRange(start: cm(readFrom), end: cm(s.end + offset))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard reader.startReading() else { throw EditorError(.io, "cannot read the timeline: \(reader.error?.localizedDescription ?? "")") }
        guard writer.startWriting() else { throw EditorError(.io, "cannot write a segment: \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: cm(s.start))

        let state = Unchecked(SegmentState())
        let box = Unchecked((reader, out, input, adaptor))
        let startTime = cm(s.start + offset), endTime = cm(s.end + offset), shift = cm(offset)
        let half = CMTime(value: 1, timescale: 240_000 / max(1, Int32(built.frameRate.frameDuration.ticks / 2)))
        // The watchdog: no frame for `stallSeconds` stops this read.
        let watchdog = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if state.value.idleSeconds > stallSeconds {
                    state.value.stalled = true
                    box.value.0.cancelReading()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        do {
            try await Self.pumpVideo(box, state: state, from: startTime, to: endTime, half: half, shift: shift)
        } catch {
            if state.value.stalled { writer.cancelWriting(); throw Stalled() }
            throw error
        }
        if state.value.stalled { writer.cancelWriting(); throw Stalled() }
        writer.endSession(atSourceTime: endTime)
        await writer.finishWriting()
        guard writer.status == .completed else { throw EditorError(.io, "segment not written: \(writer.error?.localizedDescription ?? "")") }
        return state.value.frames
    }

    typealias VideoPipe = Unchecked<(AVAssetReader, AVAssetReaderVideoCompositionOutput, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)>

    /// Feeds a segment's frames to the encoder: a plain loop that waits a
    /// moment whenever the encoder is full. AVFoundation's callback
    /// (requestMediaDataWhenReady) is not used: in a release build Swift
    /// treats that closure as main-actor code and traps when AVFoundation
    /// runs it on its own queue (found exporting from the app and dme).
    static func pumpVideo(_ box: VideoPipe, state: Unchecked<SegmentState>, from startTime: CMTime, to endTime: CMTime,
                          half: CMTime, shift: CMTime) async throws {
        let (reader, out, input, adaptor) = box.value
        while true {
            try Task.checkCancellation()
            guard input.isReadyForMoreMediaData else { try await Task.sleep(nanoseconds: 500_000); continue }
            let next = out.copyNextSampleBuffer()
            state.value.touch()
            guard let sb = next, let pb = CMSampleBufferGetImageBuffer(sb) else {
                input.markAsFinished()
                if reader.status == .failed { throw reader.error ?? EditorError(.io, "reading failed") }
                return
            }
            let t = CMSampleBufferGetPresentationTimeStamp(sb)
            // Frames before the segment come from the in-order lead; skip them.
            if t < startTime - half || t >= endTime - half { continue }
            guard adaptor.append(pb, withPresentationTime: t - shift) else {
                reader.cancelReading()
                throw EditorError(.io, "the encoder refused a frame")
            }
            state.value.frames += 1
        }
    }

    /// The sound's counterpart of `pumpVideo`.
    static func pumpAudio(_ box: Unchecked<(AVAssetReader, AVAssetReaderAudioMixOutput, AVAssetWriterInput)>,
                          state: Unchecked<SegmentState>) async throws {
        let (reader, out, input) = box.value
        while true {
            try Task.checkCancellation()
            guard input.isReadyForMoreMediaData else { try await Task.sleep(nanoseconds: 500_000); continue }
            guard let sb = out.copyNextSampleBuffer() else {
                input.markAsFinished()
                if reader.status == .failed { throw reader.error ?? EditorError(.io, "reading sound failed") }
                return
            }
            input.append(sb)
        }
    }

    final class SegmentState: @unchecked Sendable {
        var frames = 0
        var finished = false
        private let lock = NSLock()
        private var last = Date()
        private var _stalled = false
        var stalled: Bool {
            get { lock.withLock { _stalled } }
            set { lock.withLock { _stalled = newValue } }
        }
        /// A frame came from the reader (or reading ended).
        func touch() { lock.withLock { last = Date() } }
        var idleSeconds: Double { lock.withLock { Date().timeIntervalSince(last) } }
    }

    // MARK: audio

    /// The whole timeline's sound in one pass, with gains, fades and speed
    /// as in the player. Nil when the timeline has no sound.
    static func renderAudio(_ built: BuiltComposition, _ preset: ExportPreset, to url: URL) async throws -> URL? {
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: built.composition)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false])
        out.audioMix = built.audioMix
        out.audioTimePitchAlgorithm = .spectral
        reader.add(out)
        let settings: [String: Any] = preset.audioCodec == .pcm ? [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ] : [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: preset.audioBitrateKbps * 1000,
        ]
        let writer = try AVAssetWriter(outputURL: url, fileType: preset.audioCodec == .pcm ? .caf : .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading() else { throw EditorError(.io, "cannot read the sound: \(reader.error?.localizedDescription ?? "")") }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let box = Unchecked((reader, out, input))
        let state = Unchecked(SegmentState())
        try await Self.pumpAudio(box, state: state)
        await writer.finishWriting()
        guard writer.status == .completed else { throw EditorError(.io, "sound not written: \(writer.error?.localizedDescription ?? "")") }
        return url
    }

    // MARK: join

    /// Copies the segments and the sound into one file, without re-encoding.
    static func join(_ parts: [URL], audio: URL?, duration: Time, container: ExportPreset.Container, to output: URL) async throws {
        let joined = AVMutableComposition()
        let video = joined.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        var cursor = CMTime.zero
        for url in parts {
            let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let t = try await a.loadTracks(withMediaType: .video).first else { throw EditorError(.io, "segment \(url.lastPathComponent) has no picture") }
            let r = try await t.load(.timeRange)
            try video.insertTimeRange(r, of: t, at: cursor)
            cursor = cursor + r.duration
        }
        if let audio {
            let a = AVURLAsset(url: audio, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            if let t = try await a.loadTracks(withMediaType: .audio).first {
                let track = joined.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                let r = try await t.load(.timeRange)
                try track.insertTimeRange(CMTimeRange(start: r.start, duration: CMTimeMinimum(r.duration, cm(duration))), of: t, at: .zero)
            }
        }
        let tmp = output.deletingLastPathComponent().appendingPathComponent(".dme-export-\(UUID().uuidString).\(container.rawValue)")
        guard let session = AVAssetExportSession(asset: joined, presetName: AVAssetExportPresetPassthrough) else {
            throw EditorError(.io, "cannot join the segments")
        }
        try await session.export(to: tmp, as: container == .mp4 ? .mp4 : .mov)
        try FileManager.default.moveItem(at: tmp, to: output)
    }
}

/// The hash of everything that affects the frames of one stretch of the
/// timeline: output format, and every clip seen in it with its file, look,
/// effects (plug-in code included) and keyframes.
struct SegmentHasher {
    let project: Project
    let preset: ExportPreset
    let base: Data
    let visual: [(track: Track, look: Look?)]
    var effectCode: [String: String] = [:]
    let hyperframes: [EntityID: String]
    /// Matte chunks per footage file (source range and hash).
    var mattes: [EntityID: [(start: Double, end: Double, hash: String)]] = [:]
    /// How mattes are drawn (cut, edge), when any are in use.
    var matteSettings = Data()
    /// Encoder options that change the frames.
    var encoder = Data()

    init(project p: Project, preset: ExportPreset, hyperframes: [EntityID: String] = [:]) {
        project = p
        self.preset = preset
        self.hyperframes = hyperframes
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        var b = Data(ExportEngine.engineVersion.utf8)
        b += (try? enc.encode(p.settings)) ?? Data()
        b += Data("\(preset.videoCodec.rawValue)|\(preset.videoBitrateMbps ?? 0)".utf8)
        base = b
        visual = p.tracks.filter { $0.kind != .audio && !$0.hidden }
            .map { t in (t, t.look.flatMap { id in p.looks.first { $0.id == id } }) }
        for t in p.tracks {
            for c in t.clips {
                for e in c.effects where effectCode[e.effect] == nil {
                    effectCode[e.effect] = Self.code(e.effect)
                }
            }
        }
    }

    static func code(_ id: String) -> String {
        guard let e = EffectCatalog.shared.entry(id) else { return "missing" }
        var d = Data()
        for f in ["manifest.json", "effect.metal"] {
            d += FileManager.default.contents(atPath: e.folder.appendingPathComponent(f).path) ?? Data()
        }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    func hash(start: Time, end: Time) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        var d = base
        d += Data("|\(start.ticks)-\(end.ticks)".utf8)
        d += matteSettings
        d += encoder
        let range = TimeRange(start: start, duration: end - start)
        for (i, v) in visual.enumerated() {
            d += Data("|track\(i)".utf8)
            if let l = v.look { d += (try? enc.encode(l)) ?? Data() }
            for c in v.track.overlapping(range) {
                d += (try? enc.encode(c)) ?? Data()
                if let h = hyperframes[c.asset] { d += Data("hf:\(h)".utf8) }
                else if let a = project.media.first(where: { $0.id == c.asset }) { d += Data("\(a.fingerprint)|\(a.path)".utf8) }
                if let chunks = mattes[c.asset] {
                    // Only the chunks this stretch shows, in source time.
                    let s0 = c.sourceTime(at: Time.max(start, c.start)).seconds, s1 = c.sourceTime(at: Time.min(end, c.end)).seconds
                    for k in chunks where k.start <= s1 && k.end >= s0 { d += Data("matte:\(k.hash)".utf8) }
                }
                if let id = c.look, let l = project.looks.first(where: { $0.id == id }) { d += (try? enc.encode(l)) ?? Data() }
                for e in c.effects { d += Data((effectCode[e.effect] ?? "").utf8) }
            }
        }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}
