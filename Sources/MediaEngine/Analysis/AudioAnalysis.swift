import AVFoundation
import Accelerate
import CryptoKit
import EditorCore
import Foundation

/// Streams sound as 48 kHz interleaved float samples (at most two channels),
/// so long files are measured without holding them in memory.
enum AudioReader {
    static let rate = 48_000.0

    static func stream(_ asset: AVAsset, range: CMTimeRange? = nil, audioMix: AVAudioMix? = nil,
                       _ body: (UnsafeBufferPointer<Float>, Int) throws -> Void) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return }
        var channels = 1
        for t in tracks {
            for f in try await t.load(.formatDescriptions) {
                if let d = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                    channels = max(channels, min(2, Int(d.mChannelsPerFrame)))
                }
            }
        }
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false])
        out.audioMix = audioMix
        out.audioTimePitchAlgorithm = .spectral
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? EditorError(.io, "cannot read sound") }
        var buf = [Float]()
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            try Task.checkCancellation()
            let n = CMBlockBufferGetDataLength(bb) / 4
            if buf.count < n { buf = [Float](repeating: 0, count: n) }
            try buf.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: raw.baseAddress!)
                try body(UnsafeBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: Float.self), count: n), channels)
            }
        }
        if reader.status == .failed { throw reader.error ?? EditorError(.io, "cannot read sound") }
    }
}

/// Short-term level of a file's sound: RMS and peak per 10 ms, in dBFS.
/// Computed once per file and cached on disk by the file's fingerprint.
public struct LevelEnvelope: Sendable {
    public static let hop = 0.01
    public var rmsDB: [Float]
    public var peakDB: [Float]

    public var duration: Double { Double(rmsDB.count) * Self.hop }

    /// Level of loud speech: the 95th percentile of hops that carry any sound.
    public var speechLevelDB: Float {
        let s = rmsDB.filter { $0 > -60 }.sorted()
        guard !s.isEmpty else { return -20 }
        return s[Int(Double(s.count - 1) * 0.95)]
    }

    static func compute(_ asset: AVAsset) async throws -> LevelEnvelope {
        let hopFrames = Int(AudioReader.rate * hop)
        var rms: [Float] = [], peak: [Float] = []
        var sumSq: Float = 0, pk: Float = 0, frames = 0
        try await AudioReader.stream(asset) { s, ch in
            var i = 0
            while i < s.count {
                let v = s[i]
                sumSq += v * v
                pk = max(pk, abs(v))
                i += 1
                if i % ch == 0 {
                    frames += 1
                    if frames == hopFrames {
                        let ms = sumSq / Float(hopFrames * ch)
                        rms.append(ms > 1e-12 ? 10 * log10(ms) : -120)
                        peak.append(pk > 1e-6 ? 20 * log10(pk) : -120)
                        sumSq = 0; pk = 0; frames = 0
                    }
                }
            }
        }
        return LevelEnvelope(rmsDB: rms, peakDB: peak)
    }
}

/// Integrated loudness and peaks to ITU-R BS.1770-4 / EBU R128.
public struct Loudness: Codable, Sendable {
    public var integratedLUFS: Double
    public var shortTermMaxLUFS: Double
    /// Highest sample. True peak (between samples) can be up to about 0.5 dB higher.
    public var samplePeakDBFS: Double
    public var seconds: Double

    static func measure(_ asset: AVAsset, range: CMTimeRange? = nil, audioMix: AVAudioMix? = nil) async throws -> Loudness {
        // K-weighting at 48 kHz: high shelf, then high pass; state per channel.
        struct Biquad {
            var b: (Double, Double, Double), a: (Double, Double)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            mutating func run(_ x: Double) -> Double {
                let y = b.0 * x + b.1 * x1 + b.2 * x2 - a.0 * y1 - a.1 * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                return y
            }
        }
        let shelf = Biquad(b: (1.53512485958697, -2.69169618940638, 1.19839281085285), a: (-1.69065929318241, 0.73248077421585))
        let pass = Biquad(b: (1, -2, 1), a: (-1.99004745483398, 0.99007225036621))
        var filters: [(Biquad, Biquad)] = []
        let step = Int(AudioReader.rate * 0.1)
        var stepMS: [Double] = []
        var acc = 0.0, frames = 0, peak: Float = 0, total = 0
        try await AudioReader.stream(asset, range: range, audioMix: audioMix) { s, ch in
            if filters.isEmpty { filters = Array(repeating: (shelf, pass), count: ch) }
            var i = 0
            while i < s.count {
                for c in 0..<ch {
                    let v = s[i + c]
                    peak = max(peak, abs(v))
                    let w = filters[c].1.run(filters[c].0.run(Double(v)))
                    acc += w * w
                }
                i += ch
                frames += 1
                total += 1
                if frames == step { stepMS.append(acc / Double(step)); acc = 0; frames = 0 }
            }
        }
        func lufs(_ ms: Double) -> Double { ms > 0 ? -0.691 + 10 * log10(ms) : -120 }
        func blocks(_ n: Int) -> [Double] {
            guard stepMS.count >= n else { return [] }
            return (0...(stepMS.count - n)).map { i in stepMS[i..<(i + n)].reduce(0, +) / Double(n) }
        }
        let momentary = blocks(4).filter { lufs($0) > -70 }   // 400 ms blocks, 75% overlap, absolute gate
        var integrated = -70.0
        if !momentary.isEmpty {
            let relative = lufs(momentary.reduce(0, +) / Double(momentary.count)) - 10
            let gated = momentary.filter { lufs($0) > relative }
            if !gated.isEmpty { integrated = lufs(gated.reduce(0, +) / Double(gated.count)) }
        }
        let shortTerm = blocks(30).map(lufs).max() ?? integrated
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return Loudness(integratedLUFS: r1(integrated), shortTermMaxLUFS: r1(max(shortTerm, -70)),
                        samplePeakDBFS: peak > 0 ? r1(Double(20 * log10(peak))) : -120,
                        seconds: Double(total) / AudioReader.rate)
    }
}

/// Level envelopes per media file, kept in memory and in the user cache folder.
public actor LevelCache {
    private var memory: [String: LevelEnvelope] = [:]
    private let folder: URL

    public init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DanialMCPEditor/levels", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func envelope(for a: MediaAsset) async throws -> LevelEnvelope {
        let key = Self.key(a)
        if let e = memory[key] { return e }
        let file = folder.appendingPathComponent(key + ".levels")
        if let d = try? Data(contentsOf: file), d.count % 8 == 0, !d.isEmpty {
            let floats = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let n = floats.count / 2
            let e = LevelEnvelope(rmsDB: Array(floats[0..<n]), peakDB: Array(floats[n...]))
            memory[key] = e
            return e
        }
        guard a.info.audio != nil else { throw EditorError.invalid("media \(a.id) has no sound") }
        let e = try await LevelEnvelope.compute(AVURLAsset(url: URL(fileURLWithPath: a.path)))
        var raw = e.rmsDB + e.peakDB
        try? Data(bytes: &raw, count: raw.count * 4).write(to: file, options: .atomic)
        memory[key] = e
        return e
    }

    static func key(_ a: MediaAsset) -> String {
        SHA256.hash(data: Data("\(a.path)|\(a.fingerprint)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
