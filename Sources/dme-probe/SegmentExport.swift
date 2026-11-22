import AVFoundation
import VideoToolbox

/// Test 2: renders a composition in fixed-length segments, each encoded to its
/// own file, then joins them into one file without re-encoding.
func runSegmentExport(source: URL, output: URL, cuts: Int, speed: Double,
                      segmentSeconds: Double, hdr: Bool) async throws {
    var cc = try await buildCutComposition(source: source, cuts: cuts, speed: speed)
    if let scale = Double(arg("scale", "1")), scale != 1 {
        let s = cc.videoComposition.renderSize
        cc.videoComposition.renderSize = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
    }
    let comp = cc.composition
    let fps: Int32 = 60
    let totalFrames = Int64((comp.duration.seconds * Double(fps)).rounded(.down))
    let segFrames = Int64(segmentSeconds * Double(fps))
    print(String(format: "composition: %d segments, %.2f s, %lld frames", cc.segments, comp.duration.seconds, totalFrames))

    MetalCompositor.outputAttachments = hdr ? [
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020,
    ] : [
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
    ]
    let colour: [String: Any] = hdr ? [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ] : [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
    let size = cc.videoComposition.renderSize
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
        AVVideoColorPropertiesKey: colour,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: Int(size.width * size.height * 6),  // ~50 Mb/s at 4K
            AVVideoExpectedSourceFrameRateKey: Int(fps),
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
        ] as [String: Any],
    ]

    let work = output.deletingPathExtension().appendingPathExtension("parts")
    try? FileManager.default.removeItem(at: work)  // probe scratch folder it created itself
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // Video segments.
    let renderStart = Date()
    // Segments are independent, so several render at once.
    let jobs = max(1, Int(arg("jobs", "1"))!)
    var plan: [(k: Int64, range: CMTimeRange, url: URL)] = []
    var k: Int64 = 0
    while k * segFrames < totalFrames {
        let first = k * segFrames
        let count = min(segFrames, totalFrames - first)
        plan.append((k, CMTimeRange(start: CMTime(value: first, timescale: fps),
                                    duration: CMTime(value: count, timescale: fps)),
                     work.appendingPathComponent(String(format: "v%04lld.mov", k))))
        k += 1
    }
    var counts = [Int](repeating: 0, count: plan.count)
    try await withThrowingTaskGroup(of: (Int, Int).self) { group in
        var next = 0
        func launch() {
            let i = next; next += 1
            let p = plan[i]
            group.addTask { (i, try await renderSegment(comp: comp, vc: cc.videoComposition, range: p.range,
                                                         url: p.url, settings: videoSettings)) }
        }
        for _ in 0..<min(jobs, plan.count) { launch() }
        while let (i, n) = try await group.next() {
            counts[i] = n
            if next < plan.count { launch() }
        }
    }
    let segFiles = plan.map(\.url)
    let written = counts
    let renderSeconds = Date().timeIntervalSince(renderStart)

    // Audio, one pass.
    let audioURL = work.appendingPathComponent("audio.m4a")
    let audioStart = Date()
    try await renderAudio(comp: comp, url: audioURL)
    let audioSeconds = Date().timeIntervalSince(audioStart)

    // Join without re-encoding.
    let joinStart = Date()
    let joined = AVMutableComposition()
    let jv = joined.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    var cursor = CMTime.zero
    for url in segFiles {
        let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let t = try await a.loadTracks(withMediaType: .video).first!
        let r = try await t.load(.timeRange)
        try jv.insertTimeRange(r, of: t, at: cursor)
        cursor = cursor + r.duration
    }
    let aa = AVURLAsset(url: audioURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    if let at = try await aa.loadTracks(withMediaType: .audio).first {
        let ja = joined.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let r = try await at.load(.timeRange)
        try ja.insertTimeRange(CMTimeRange(start: r.start, duration: min(r.duration, cursor)), of: at, at: .zero)
    }
    try? FileManager.default.removeItem(at: output)
    let session = AVAssetExportSession(asset: joined, presetName: AVAssetExportPresetPassthrough)!
    try await session.export(to: output, as: .mov)
    let joinSeconds = Date().timeIntervalSince(joinStart)

    let dur = comp.duration.seconds
    print("segments: \(segFiles.count) of \(segFrames) frames; frames written: \(written.reduce(0, +)) of \(totalFrames)")
    let short = written.enumerated().filter { $0.offset < written.count - 1 && $0.element != Int(segFrames) }
    if !short.isEmpty { print("segments with a wrong frame count: \(short.prefix(10))") }
    print("parallel segment jobs: \(jobs)")
    print(String(format: "video render+encode: %.1f s for %.1f s of video (%.2fx real time)", renderSeconds, dur, dur / renderSeconds))
    print(String(format: "audio: %.1f s; join: %.1f s", audioSeconds, joinSeconds))
    let r = MetalCompositor.timings.snapshot().map { Double($0) / 1e6 }.sorted()
    print(String(format: "render per frame: median %.2f ms, p99 %.2f ms; memory %.0f MB",
                 pct(r, 0.5), pct(r, 0.99), footprintMB()))
    print("output: \(output.path)")
}

private func renderSegment(comp: AVComposition, vc: AVVideoComposition, range: CMTimeRange,
                           url: URL, settings: [String: Any]) async throws -> Int {
    let reader = try AVAssetReader(asset: comp)
    let tracks = try await comp.loadTracks(withMediaType: .video)
    let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
    out.videoComposition = vc
    out.alwaysCopiesSampleData = false
    reader.add(out)
    reader.timeRange = range

    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)

    guard reader.startReading() else { throw reader.error ?? NSError(domain: "probe", code: 20) }
    writer.startWriting()
    writer.startSession(atSourceTime: range.start)

    var n = 0
    let q = DispatchQueue(label: "seg")
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        input.requestMediaDataWhenReady(on: q) {
            while input.isReadyForMoreMediaData {
                guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else {
                    input.markAsFinished()
                    if reader.status == .failed { c.resume(throwing: reader.error!) } else { c.resume() }
                    return
                }
                adaptor.append(pb, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sb))
                n += 1
            }
        }
    }
    writer.endSession(atSourceTime: range.end)
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "probe", code: 21) }
    return n
}

private func renderAudio(comp: AVComposition, url: URL) async throws {
    let reader = try AVAssetReader(asset: comp)
    let tracks = try await comp.loadTracks(withMediaType: .audio)
    let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false])
    out.audioTimePitchAlgorithm = .spectral
    reader.add(out)

    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 320_000])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "probe", code: 22) }
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let q = DispatchQueue(label: "aud")
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        input.requestMediaDataWhenReady(on: q) {
            while input.isReadyForMoreMediaData {
                guard let sb = out.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    if reader.status == .failed { c.resume(throwing: reader.error!) } else { c.resume() }
                    return
                }
                input.append(sb)
            }
        }
    }
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "probe", code: 23) }
}
