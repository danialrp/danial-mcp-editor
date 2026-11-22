import AVFoundation
import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing

/// Phase 6 exit checks: exported frames match the timeline, an interrupted
/// export resumes, and a small edit re-renders only its segments. Uses the
/// numbered open-GOP fixture, so every exported frame can be identified.
@Suite("Export", .serialized)
struct ExportTests {
    let media: MediaContext
    let cache: URL
    let out: URL
    var options = ExportOptions()
    let preset = ExportPreset(width: 320, height: 240, frameRate: .fps30, dynamicRange: .sdr,
                              videoCodec: .h264, videoBitrateMbps: 4, container: .mp4)

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-x-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        media = MediaContext(editor: Editor(settings: try UserSettingsStore(directory: dir.appendingPathComponent("home")), prober: AVMediaProber()))
        cache = dir.appendingPathComponent("cache")
        out = dir
        options.segmentSeconds = 0.5   // 15 frames: the 53-frame fixture timeline gives 4 segments
    }

    func export(_ p: Project, _ name: String, parallel: Int = 2,
                progress: @escaping @Sendable (Int, Int, String) async throws -> Void = { _, _, _ in }) async throws -> ExportEngine.Report {
        var o = options
        o.parallelSegments = parallel
        return try await ExportEngine.run(project: p, revision: 1, preset: preset, options: o,
                                   to: out.appendingPathComponent(name), media: media, cacheFolder: cache, progress: progress)
    }

    /// Source frame number shown by every frame of a file.
    func frameNumbers(_ url: URL) async throws -> [Int] {
        let a = AVURLAsset(url: url)
        let v = try #require(try await a.loadTracks(withMediaType: .video).first)
        let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        r.add(o)
        r.startReading()
        var n: [Int] = []
        while let sb = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)[CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * 120 + 160]
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            n.append(Int(((Double(y) - 20) / 2).rounded()))
        }
        return n
    }

    @Test func exportedFramesMatchTheTimeline() async throws {
        let p = try await OpenGOPTests().project()
        let r = try await export(p, "a.mp4")
        #expect(r.frames == 53 && r.segments == 4 && r.rendered == 4 && r.reused == 0)
        let got = try await frameNumbers(out.appendingPathComponent("a.mp4"))
        #expect(got.count == 53)
        let clips = p.tracks[0].clips
        for (i, n) in got.enumerated() {
            let t = Time(ticks: Int64(i) * 8000)
            let c = try #require(clips.first { $0.start <= t && t < $0.end })
            let want = Int((c.sourceTime(at: t).seconds * 30).rounded()) % 100
            #expect(abs(n - want) == 0, "exported frame \(i) shows source frame \(n), wants \(want)")
        }
        let facts = try await ExportVerify.inspect(out.appendingPathComponent("a.mp4"))
        #expect(facts["frames"]?.doubleValue == 53)
        #expect(facts["codec"]?.stringValue == "avc1")
        #expect(facts["transfer"]?.stringValue == (kCVImageBufferTransferFunction_ITU_R_709_2 as String))
    }

    @Test(.timeLimit(.minutes(1))) func aClipAtZeroStartingOnALeadingFrameKeepsItsFirstFrames() async throws {
        var p = try await OpenGOPTests().project()
        // Clip a now starts the timeline on the first of the three leading frames before the keyframe at 32.
        p.tracks[0].clips[0].sourceStart = OpenGOPTests().f(29)
        _ = try await export(p, "z.mp4")
        let got = try await frameNumbers(out.appendingPathComponent("z.mp4"))
        #expect(got.count == 53)
        let clips = p.tracks[0].clips
        for (i, n) in got.enumerated() {
            let t = Time(ticks: Int64(i) * 8000)
            let c = try #require(clips.first { $0.start <= t && t < $0.end })
            let want = Int((c.sourceTime(at: t).seconds * 30).rounded()) % 100
            #expect(n == want, "exported frame \(i) shows source frame \(n), wants \(want)")
        }
    }

    @Test func anInterruptedExportResumes() async throws {
        let p = try await OpenGOPTests().project()
        await #expect(throws: CancellationError.self) {
            _ = try await export(p, "b.mp4", parallel: 1) { done, _, message in
                if message.contains("rendered"), done >= 2 { throw CancellationError() }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("b.mp4").path), "no half file")
        let r = try await export(p, "b.mp4")
        #expect(r.reused == 2 && r.rendered == 2, "finished segments are kept: reused \(r.reused), rendered \(r.rendered)")
        #expect(try await frameNumbers(out.appendingPathComponent("b.mp4")).count == 53)
    }

    @Test func aSmallEditRendersOnlyItsSegments() async throws {
        var p = try await OpenGOPTests().project()
        _ = try await export(p, "c1.mp4")
        // Clip d covers frames 38 to 52: segments 2 (30-44) and 3 (45-52).
        p.tracks[0].clips[3].opacity = 0.5
        let r = try await export(p, "c2.mp4")
        #expect(r.rendered == 2 && r.reused == 2, "rendered \(r.rendered), reused \(r.reused)")
        // Nothing changed: everything comes from the cache.
        let again = try await export(p, "c3.mp4")
        #expect(again.rendered == 0 && again.reused == 4)
    }
}
