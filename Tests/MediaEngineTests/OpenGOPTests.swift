import AVFoundation
import EditorCore
import Foundation
@testable import MediaEngine
import Testing

/// Cuts on the leading frames of open-GOP video must not lose frames
/// (N-6). The fixture is open-GOP HEVC, 30 fps, keyframes every 32 frames
/// (1.067 s, 2.133 s, ...), each preceded by three leading frames; frame N
/// has luma 20 + (N mod 100) * 2, so every output frame can be identified.
@Suite("Open-GOP cuts", .serialized)
struct OpenGOPTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/opengop_numbered.mov")

    /// Frames at 30 fps as time.
    func f(_ n: Int) -> Time { Time(ticks: Int64(n) * 8000) }

    func project() async throws -> Project {
        var p = Project(id: "project_g", name: "g", settings: ProjectSettings(width: 320, height: 240, frameRate: .fps30, dynamicRange: .sdr))
        let info = try await AVMediaProber().probe(Self.fixture)
        p.media = [MediaAsset(id: "src", path: Self.fixture.path, name: "src", fingerprint: "fixture", info: info)]
        var main = Track(id: "main", kind: .main, name: "Main")
        func clip(_ id: String, at start: Int, source: Int, frames: Int, speed: Int = 1) -> Clip {
            Clip(id: EntityID(id), asset: "src", start: f(start), duration: f(frames), sourceStart: f(source), sourceDuration: f(frames * speed))
        }
        main.clips = [
            clip("a", at: 0, source: 75, frames: 15),             // mid-group start: fine on its own
            clip("b", at: 15, source: 30, frames: 15),            // first frame is a leading frame of the keyframe at 32
            clip("c", at: 30, source: 94, frames: 8, speed: 2),   // leading frame of the keyframe at 96, double speed
            clip("d", at: 38, source: 62, frames: 15),            // leading frame of the keyframe at 64
        ]
        p.tracks = [main]
        return p
    }

    static func frameNumber(_ gray: Double) -> Int {
        let y = gray * 219 + 16
        return Int(((y - 20) / 2).rounded())
    }

    @Test func detectsLeadingFrames() async throws {
        let asset = AVURLAsset(url: Self.fixture, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let segs = try await v.load(.segments)
        func early(_ n: Int) -> Time? { DecodeStart.earlierStart(v, segments: segs, at: cm(f(n))).map { time($0) } }
        #expect(early(30) == f(0), "leading frame: decode from the keyframe before")
        #expect(early(31) == f(0))
        #expect(early(32) == nil, "a keyframe decodes on its own")
        #expect(early(29) == f(0), "the third leading frame")
        #expect(early(28) == nil, "an ordinary frame: AVFoundation starts right")
        #expect(early(75) == nil)
    }

    @Test func everyFrameComesOutStraightThrough() async throws {
        let p = try await project()
        let built = try await CompositionBuilder().build(p)
        let reader = try AVAssetReader(asset: built.composition)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video),
                                                      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = built.videoComposition
        reader.add(out)
        #expect(reader.startReading())
        var seen: [Int: Int] = [:]
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = time(sb.presentationTimeStamp)
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let px = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)[CVPixelBufferGetBytesPerRow(pb) * 120 + 160 * 4 + 1]
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            seen[Int((t.seconds * 30).rounded())] = Self.frameNumber(Double(px) / 255)
        }
        #expect(reader.status == .completed)
        let clips = p.tracks[0].clips
        for frame in 0..<53 {
            let t = f(frame)
            let c = try #require(clips.first { $0.start <= t && t < $0.end })
            let want = Int((c.sourceTime(at: t).seconds * 30).rounded()) % 100
            #expect(seen[frame] == want, "timeline frame \(frame) (clip \(c.id)) shows \(seen[frame].map(String.init) ?? "nothing"), wants source frame \(want)")
        }
    }

    /// Frame capture jumps straight to a frame; on leading frames that gives
    /// another frame of the file unless it decodes in order. Captures go
    /// through colour management, so frames are checked by their steps: one
    /// frame of the fixture is one even step of brightness.
    @Test func frameCaptureGetsLeadingFrames() async throws {
        let p = try await project()
        let built = try await CompositionBuilder().build(p)
        func gray(_ frame: Int) async throws -> Double {
            ColorTools.Pixels(try await FrameCapture.timelineFrame(built, at: f(frame), maxWidth: nil)).rgb(160, 120).1
        }
        // Clip b starts on two leading frames (15, 16); clip d on 38, 39.
        for frames in [Array(15...19), Array(38...42)] {
            var g: [Double] = []
            for fr in frames { g.append(try await gray(fr)) }
            let steps = zip(g, g.dropFirst()).map { $1 - $0 }
            for (i, d) in steps.enumerated() {
                #expect(d > 0.004 && d < 0.016, "frames \(frames[i]) to \(frames[i] + 1): step \(d), one frame is about 0.008")
            }
        }
        // Clip c (double speed) starts on a leading frame: two source frames per step.
        var c: [Double] = []
        for fr in 30...32 { c.append(try await gray(fr)) }   // source 94, 96, 98 (brightness wraps at 100)
        for (a, b) in zip(c, c.dropFirst()) { #expect(b - a > 0.011 && b - a < 0.025, "double-speed step \(b - a)") }
        #expect(built.inOrderOnly.count == 3, "b, c and d need in-order decoding")
    }

    @Test(.timeLimit(.minutes(1))) func frameCaptureGetsTheFirstFramesOfAClipAtZero() async throws {
        var p = try await project()
        p.tracks[0].clips[0].sourceStart = f(29)   // the timeline starts on a leading frame
        let built = try await CompositionBuilder().build(p)
        #expect(built.preroll != nil, "the clip at 0 s has no room for its lead-in")
        var g: [Double] = []
        for fr in 0...4 { g.append(ColorTools.Pixels(try await FrameCapture.timelineFrame(built, at: f(fr), maxWidth: nil)).rgb(160, 120).1) }
        for (i, d) in zip(g, g.dropFirst()).map({ $1 - $0 }).enumerated() {
            #expect(d > 0.004 && d < 0.016, "frames \(i) to \(i + 1): step \(d), one frame is about 0.008")
        }
    }

    @Test func sourceFramesOnLeadingFramesDecode() async throws {
        var g: [Double] = []
        for fr in 28...33 {   // 29, 30, 31 lead into the keyframe at 32
            g.append(ColorTools.Pixels(try await FrameCapture.sourceFrame(path: Self.fixture.path, at: f(fr), maxWidth: nil)).rgb(160, 120).1)
        }
        for (i, d) in zip(g, g.dropFirst()).map({ $1 - $0 }).enumerated() {
            #expect(d > 0.004 && d < 0.016, "source frames \(28 + i) to \(29 + i): step \(d)")
        }
    }

    @Test func readersNeverStartInsideAnInOrderStretch() async throws {
        let built = try await CompositionBuilder().build(try await project())
        for r in built.inOrderOnly {
            let s = built.safeStart(r.start)
            #expect(!built.inOrderOnly.contains { $0.start <= s && s < $0.end }, "start \(s.seconds) for stretch at \(r.start.seconds)")
            #expect(s <= r.start)
        }
        #expect(built.safeStart(f(10)) == f(10), "outside the stretches nothing moves")
    }
}
