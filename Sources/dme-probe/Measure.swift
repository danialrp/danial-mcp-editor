import AVFoundation
import Accelerate

/// Measures picture-to-sound offset in a file made from the sync source:
/// each white flash should start together with a 1 kHz beep.
func runSync(file: URL) async throws {
    let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let flashes = try await flashStarts(asset)
    let beeps = try await beepOnsets(asset)
    print("flashes: \(flashes.count), beeps: \(beeps.count)")
    var offsets: [Double] = []
    for f in flashes {
        if let b = beeps.min(by: { abs($0 - f) < abs($1 - f) }), abs(b - f) < 0.2 {
            offsets.append((b - f) * 1000)
        }
    }
    let s = offsets.sorted()
    print(String(format: "beep minus flash, ms: min %.1f, median %.1f, max %.1f (%d pairs)",
                 s.first ?? .nan, pct(s, 0.5), s.last ?? .nan, s.count))
    // The flash can only start on a frame, the beep starts exactly at the mark.
    // So the beep may lead the first white frame by up to one frame (16.7 ms).
    let bad = s.filter { $0 > 2 || $0 < -18.7 }
    print("pairs outside the one-frame window (-18.7 to +2 ms): \(bad.count)")
}

private func flashStarts(_ asset: AVAsset) async throws -> [Double] {
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    out.alwaysCopiesSampleData = false
    reader.add(out)
    reader.startReading()
    var starts: [Double] = []
    var wasWhite = false
    while let sb = out.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pb)!
        let row = CVPixelBufferGetBytesPerRow(pb)
        let x = CVPixelBufferGetWidth(pb) / 2, y = CVPixelBufferGetHeight(pb) / 2
        let p = (base + y * row + x * 4).assumingMemoryBound(to: UInt8.self)
        let white = p[0] > 230 && p[1] > 230 && p[2] > 230
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        if white && !wasWhite { starts.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
        wasWhite = white
    }
    return starts
}

func readMono(_ asset: AVAsset, algorithm: AVAudioTimePitchAlgorithm? = nil) async throws -> [Float] {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false])
    if let algorithm { out.audioTimePitchAlgorithm = algorithm }
    reader.add(out)
    reader.startReading()
    var samples: [Float] = []
    while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
        let len = CMBlockBufferGetDataLength(bb)
        var chunk = [Float](repeating: 0, count: len / 4)
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        samples += chunk
    }
    if reader.status == .failed { throw reader.error! }
    return samples
}

private func beepOnsets(_ asset: AVAsset) async throws -> [Double] {
    let s = try await readMono(asset)
    var onsets: [Double] = []
    var quiet = 0
    for (i, v) in s.enumerated() {
        if abs(v) > 0.05 {
            if quiet > 480 { onsets.append(Double(i) / 48_000) }  // after 10 ms of silence
            quiet = 0
        } else {
            quiet += 1
        }
    }
    return onsets
}

/// Test 3: compares what the editor shows for the source (compositor output)
/// with what it shows for the exported file, frame by frame.
func runCompare(source: URL, exported: URL, hdr: Bool) async throws {
    let a = try await buildCutComposition(source: source, cuts: 0, speed: 1)
    let b = try await buildCutComposition(source: exported, cuts: 0, speed: 1)
    let fa = try await sampleFrames(a, every: 30)
    let fb = try await sampleFrames(b, every: 30)
    let n = min(fa.count, fb.count)
    print("frames compared: \(n) (source \(fa.count), export \(fb.count) sampled)")
    var meanAbs: [Double] = [], meanSigned: [Double] = [], p999: [Double] = []
    for i in 0..<n {
        let (x, y) = (fa[i], fb[i])
        guard x.count == y.count else { print("size differs at frame \(i)"); return }
        var d = [Float](repeating: 0, count: x.count)
        vDSP_vsub(y, 1, x, 1, &d, 1, vDSP_Length(x.count))  // x - y
        var m: Float = 0; vDSP_meanv(d, 1, &m, vDSP_Length(d.count))
        var ad = [Float](repeating: 0, count: d.count); vDSP_vabs(d, 1, &ad, 1, vDSP_Length(d.count))
        var ma: Float = 0; vDSP_meanv(ad, 1, &ma, vDSP_Length(ad.count))
        let sorted = ad.sorted()
        meanAbs.append(Double(ma)); meanSigned.append(Double(m)); p999.append(Double(sorted[Int(Double(sorted.count - 1) * 0.999)]))
    }
    func avg(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(1, v.count)) }
    // Values are 0..1 signal levels; 1/1023 is one 10-bit code value.
    print(String(format: "mean |difference|: %.5f (%.2f 10-bit code values)", avg(meanAbs), avg(meanAbs) * 1023))
    print(String(format: "mean signed difference: %+.5f (%.2f code values; non-zero means a shift)", avg(meanSigned), avg(meanSigned) * 1023))
    print(String(format: "99.9th percentile |difference|: %.4f worst frame, %.4f average", p999.max() ?? 0, avg(p999)))
}

/// RGB values (no alpha) of every `every`-th output frame, downscaled 4x for speed.
private func sampleFrames(_ cc: CutComposition, every: Int) async throws -> [[Float]] {
    let reader = try AVAssetReader(asset: cc.composition)
    let tracks = try await cc.composition.loadTracks(withMediaType: .video)
    let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
    out.videoComposition = cc.videoComposition
    reader.add(out)
    reader.startReading()
    var frames: [[Float]] = []
    var i = 0
    while let sb = out.copyNextSampleBuffer() {
        defer { i += 1 }
        guard i % every == 0, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pb)!
        let row = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var v: [Float] = []
        v.reserveCapacity((w / 4) * (h / 4) * 3)
        for y in stride(from: 0, to: h, by: 4) {
            let p = (base + y * row).assumingMemoryBound(to: Float16.self)
            for x in stride(from: 0, to: w, by: 4) {
                v.append(Float(p[x * 4])); v.append(Float(p[x * 4 + 1])); v.append(Float(p[x * 4 + 2]))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        frames.append(v)
    }
    if reader.status == .failed { throw reader.error! }
    return frames
}
