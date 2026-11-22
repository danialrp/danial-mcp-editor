import AVFoundation

/// Test 4: speeds audio up and checks that the pitch stays where it was.
/// With a voice file it also writes listening samples for each algorithm.
func runPitch(tone: URL, voice: URL?, outDir: URL, speed: Double) async throws {
    let algorithms: [(String, AVAudioTimePitchAlgorithm)] = [
        ("spectral", .spectral), ("timeDomain", .timeDomain), ("varispeed", .varispeed)]

    let toneAsset = AVURLAsset(url: tone)
    let original = try await readMono(toneAsset)
    let f0 = pitch(original)
    print(String(format: "tone: %.1f Hz, %.2f s", f0, Double(original.count) / 48_000))
    for (name, alg) in algorithms {
        let comp = try await sped(toneAsset, start: 0, seconds: nil, speed: speed)
        let s = try await readMono(comp, algorithm: alg)
        print(String(format: "  %-10@ %.1f Hz, %.3f s (expected %.3f s)", name as NSString, pitch(s),
                     Double(s.count) / 48_000, Double(original.count) / 48_000 / speed))
    }

    guard let voice else { return }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let va = AVURLAsset(url: voice)
    let start = 120.0, length = 30.0
    for (name, alg) in algorithms.prefix(2) {
        let comp = try await sped(va, start: start, seconds: length, speed: speed)
        let s = try await readMono(comp, algorithm: alg)
        let url = outDir.appendingPathComponent("voice_\(name)_\(speed).wav")
        try writeWav(s, to: url)
        print("wrote \(url.path)")
    }
    let ref = try await sped(va, start: start, seconds: length, speed: 1)
    let url = outDir.appendingPathComponent("voice_original.wav")
    try writeWav(try await readMono(ref), to: url)
    print("wrote \(url.path)")
}

private func sped(_ asset: AVAsset, start: Double, seconds: Double?, speed: Double) async throws -> AVComposition {
    let src = try await asset.loadTracks(withMediaType: .audio).first!
    let dur = try await asset.load(.duration).seconds
    let len = seconds ?? (dur - start)
    let comp = AVMutableComposition()
    let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let r = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                        duration: CMTime(seconds: len, preferredTimescale: 48_000))
    try t.insertTimeRange(r, of: src, at: .zero)
    if speed != 1 {
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: r.duration),
                            toDuration: CMTime(seconds: len / speed, preferredTimescale: 48_000))
    }
    return comp
}

/// Fundamental frequency of the middle second, by autocorrelation.
private func pitch(_ s: [Float]) -> Double {
    let n = 48_000
    guard s.count > n else { return .nan }
    let mid = Array(s[(s.count - n) / 2 ..< (s.count + n) / 2])
    var best = 0, bestV: Float = -.infinity
    for lag in 48_000 / 1000 ... 48_000 / 60 {  // 60 Hz to 1 kHz
        var v: Float = 0
        for i in 0 ..< (n - lag) { v += mid[i] * mid[i + lag] }
        if v > bestV { bestV = v; best = lag }
    }
    return 48_000 / Double(best)
}

private func writeWav(_ s: [Float], to url: URL) throws {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false])
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
    buf.frameLength = AVAudioFrameCount(s.count)
    s.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
    try file.write(from: buf)
}
