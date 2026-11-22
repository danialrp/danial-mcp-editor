import AVFoundation
import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing

/// Sound as it comes out of the built composition (the same mix the player
/// and the export use), measured sample by sample: gain is the right number
/// of decibels, mute is silence, fades rise and fall smoothly, a cut does not
/// click or drop, and the length matches the timeline.
@Suite("Sound, rendered", .serialized)
struct AudioRenderTests {
    static let rate = 48_000.0

    /// A steady 440 Hz tone at half scale, made once per run.
    static let tone: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("dme-tone-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let f = try! AVAudioFile(forWriting: u, settings: fmt.settings)
        let n = AVAudioFrameCount(rate * 20)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        b.frameLength = n
        for i in 0..<Int(n) {
            let v = Float(0.5 * sin(2 * .pi * 440 * Double(i) / rate))
            b.floatChannelData![0][i] = v
            b.floatChannelData![1][i] = v
        }
        try! f.write(from: b)
        return u
    }()

    func project(_ edit: (inout Track) -> Void) async throws -> Project {
        let info = try await AVMediaProber().probe(Self.tone)
        var p = Project(id: "p", name: "sound", settings: ProjectSettings(width: 320, height: 240, frameRate: .fps60, dynamicRange: .sdr))
        p.media = [MediaAsset(id: "tone", path: Self.tone.path, name: "tone", fingerprint: "t", info: info)]
        var t = Track(id: "music", kind: .audio, name: "Music")
        edit(&t)
        p.tracks = [Track(id: "main", kind: .main, name: "Main"), t]
        return p
    }

    func clip(_ id: String, at start: Double, from: Double, _ length: Double) -> Clip {
        Clip(id: EntityID(id), asset: "tone", start: Time(seconds: start), duration: Time(seconds: length),
             sourceStart: Time(seconds: from), sourceDuration: Time(seconds: length))
    }

    /// RMS of the left channel in 10 ms blocks.
    func levels(_ p: Project) async throws -> [Double] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-a-\(UUID().uuidString)")
        let media = MediaContext(editor: Editor(settings: try UserSettingsStore(directory: dir), prober: AVMediaProber()))
        let built = try await media.composition(for: p)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        let r = try AVAssetReader(asset: built.composition)
        let o = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2,
        ])
        o.audioMix = built.audioMix
        r.add(o)
        r.startReading()
        var left: [Float] = []
        while let sb = o.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            let f = UnsafeRawPointer(ptr!).assumingMemoryBound(to: Float.self)
            for i in stride(from: 0, to: len / 4, by: 2) { left.append(f[i]) }
        }
        let w = Int(Self.rate / 100)
        return stride(from: 0, to: left.count - w + 1, by: w).map { s in
            (left[s..<(s + w)].reduce(0.0) { $0 + Double($1 * $1) } / Double(w)).squareRoot()
        }
    }

    static let full = 0.5 / 2.0.squareRoot()   // RMS of the tone

    @Test(arguments: [-24.0, -12.0, -6.0, 0.0, 6.0, 12.0])
    func gainIsThatManyDecibels(_ db: Double) async throws {
        let l = try await levels(try await project { t in var c = clip("a", at: 0, from: 1, 4); c.gainDB = db; t.clips = [c] })
        let mid = l[100..<300].reduce(0, +) / 200
        #expect(abs(20 * log10(mid / Self.full) - db) < 0.3, "gain \(db) dB measured \(20 * log10(mid / Self.full)) dB")
    }

    @Test func muteIsSilence() async throws {
        let l = try await levels(try await project { t in var c = clip("a", at: 0, from: 1, 3); c.muted = true; t.clips = [c] })
        #expect(l.max() ?? 1 < 1e-4)
    }

    @Test func fadesRiseAndFallSmoothly() async throws {
        let l = try await levels(try await project { t in
            var c = clip("a", at: 0, from: 1, 5); c.fadeIn = Time(seconds: 1); c.fadeOut = Time(seconds: 1.5); t.clips = [c]
        })
        #expect(l[0] < Self.full * 0.05, "starts silent")
        for i in 1..<100 { #expect(l[i] >= l[i - 1] - 0.002, "fade-in never dips (block \(i))") }
        #expect(abs(l[150] - Self.full) < 0.01, "full level between the fades")
        for i in 351..<499 { #expect(l[i] <= l[i - 1] + 0.002, "fade-out never rises (block \(i))") }
        #expect(l[498] < Self.full * 0.05, "ends silent")
    }

    /// A cut in continuous sound (split, nothing removed) keeps it steady
    /// apart from the short join fade (E-9), and the fade-in and fade-out
    /// of the whole clip stay at its two ends only.
    @Test func aCutInContinuousSoundOnlyDipsForTheJoinFade() async throws {
        let l = try await levels(try await project { t in
            var a = clip("a", at: 0, from: 1, 2), b = clip("b", at: 2, from: 3, 2)
            a.fadeIn = Time(seconds: 0.5); b.fadeOut = Time(seconds: 0.5)
            t.clips = [a, b]
            t.joinFade = Time(seconds: 0.05)
        })
        for i in 60..<190 { #expect(abs(l[i] - Self.full) < 0.01, "steady before the cut (block \(i))") }
        for i in 210..<340 { #expect(abs(l[i] - Self.full) < 0.01, "steady after the cut (block \(i))") }
        #expect(l[194..<206].filter { $0 < Self.full * 0.5 }.count <= 6, "the dip lasts no longer than the join fade")
    }

    /// Without a join fade, a cut of continuous sound is seamless.
    @Test func aCutWithoutJoinFadeIsSeamless() async throws {
        let l = try await levels(try await project { t in t.clips = [clip("a", at: 0, from: 1, 2), clip("b", at: 2, from: 3, 2)] })
        for i in 5..<395 { #expect(abs(l[i] - Self.full) < 0.005, "steady through the cut (block \(i))") }
    }

    @Test func soundLastsAsLongAsTheTimeline() async throws {
        let l = try await levels(try await project { t in t.clips = [clip("a", at: 0.5, from: 1, 2), clip("b", at: 3, from: 6, 1.5)] })
        #expect(abs(Double(l.count) / 100 - 4.5) < 0.05, "sound length \(Double(l.count) / 100) s for a 4.5 s timeline")
        #expect(l[10..<45].allSatisfy { $0 < 1e-4 }, "silence before the first clip")
        #expect(l[260..<295].allSatisfy { $0 < 1e-4 }, "silence in the gap")
        #expect(abs(l[350] - Self.full) < 0.01, "the second clip plays")
    }

    /// A clip with a fade-in and a fade-out, cut in the middle: the sound at
    /// the cut stays steady (the fades stay at the clip's two ends).
    @Test func cuttingAFadedClipKeepsTheSoundSteady() async throws {
        let l = try await levels(try await project { t in
            var c = clip("a", at: 0, from: 1, 4)
            c.fadeIn = Time(seconds: 0.5); c.fadeOut = Time(seconds: 0.5)
            t.clips = [c]
            var ids = IDGenerator(seed: "cut")
            _ = t.split(at: Time(seconds: 2), ids: &ids)
            _ = t.split(at: Time(seconds: 3), ids: &ids)
        })
        for i in 60..<340 { #expect(abs(l[i] - Self.full) < 0.005, "steady at and around the cuts (block \(i))") }
        #expect(l[0] < Self.full * 0.1 && l[399] < Self.full * 0.1, "the fades are still at the two ends")
    }
}
