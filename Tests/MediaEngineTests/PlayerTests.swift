import AVFoundation
import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing

/// The player of the open project, driven as the app and agents drive it:
/// seeks to random frames land exactly on them and show that frame's
/// picture (cuts, leading frames of open-GOP video, double speed); an edit
/// keeps the playhead; colour-only edits do not rebuild; the length is the
/// timeline's. Uses the numbered fixture, so every picture can be named.
@Suite("Player", .serialized)
@MainActor
struct PlayerTests {
    static let fixture = OpenGOPTests.fixture
    func f(_ n: Int) -> Time { Time(ticks: Int64(n) * 8000) }

    struct Rig {
        let editor: Editor
        let session: EditorSession
        let media: MediaContext
        let player: PlayerController
        let output: AVPlayerItemVideoOutput
    }

    /// Clips as in OpenGOPTests: a, b and d start on leading frames, c is double speed.
    static let layout: [(id: String, at: Int, source: Int, frames: Int, speed: Int)] = [
        ("a", 0, 75, 15, 1), ("b", 15, 30, 15, 1), ("c", 30, 94, 8, 2), ("d", 38, 62, 15, 1),
    ]

    /// The source frame number the timeline shows at frame `n`.
    static func expected(_ n: Int) -> Int {
        let c = layout.first { n >= $0.at && n < $0.at + $0.frames }!
        return (c.source + (n - c.at) * c.speed) % 100
    }

    func rig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-pl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let editor = Editor(settings: try UserSettingsStore(directory: dir.appendingPathComponent("home")), prober: AVMediaProber())
        let s = try await editor.createProject(at: dir.appendingPathComponent("p.dmeproj").path, name: "player",
                                               settings: ProjectSettings(width: 320, height: 240, frameRate: .fps30, dynamicRange: .sdr))
        let info = try await AVMediaProber().probe(Self.fixture)
        let main = try #require(await s.project.tracks.first { $0.kind == .main }).id
        var cmds: [any EditorCommand] = [AddMedia(assets: [MediaAsset(id: "src", path: Self.fixture.path, name: "src", fingerprint: "fixture", info: info)])]
        // At normal speed first (c then lasts 16 frames), so d goes in after c is sped up.
        for c in Self.layout where c.id != "d" {
            cmds.append(AddClip(track: main, asset: "src", start: f(c.at), sourceStart: f(c.source), sourceDuration: f(c.frames * c.speed), id: EntityID(c.id)))
        }
        try await s.apply(cmds)
        try await s.apply([SetClipSpeed(ids: ["c"], speed: 2)])
        let d = Self.layout[3]
        try await s.apply([AddClip(track: main, asset: "src", start: f(d.at), sourceStart: f(d.source), sourceDuration: f(d.frames), id: "d")])
        let media = MediaContext(editor: editor)
        let player = PlayerController(media: media)
        await player.follow()
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        player.player.currentItem?.add(out)
        return Rig(editor: editor, session: s, media: media, player: player, output: out)
    }

    /// The source frame number in the picture the player has at its playhead.
    func shown(_ r: Rig, at want: Time) async throws -> Int? {
        guard let item = r.player.player.currentItem else { return nil }
        if !item.outputs.contains(r.output) { item.add(r.output) }
        let t = item.currentTime()
        for _ in 0..<200 {
            var shownAt = CMTime.invalid
            // Only a picture made for this very frame counts, not one left from before.
            if let pb = r.output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shownAt),
               shownAt.isNumeric, abs(shownAt.seconds - want.seconds) < 0.5 / 30 {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let row = CVPixelBufferGetBytesPerRow(pb)
                let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                let x = CVPixelBufferGetWidth(pb) / 2, y = CVPixelBufferGetHeight(pb) / 2
                let g = Double(p[y * row + x * 4 + 1]) / 255   // green ≈ luma for a grey picture
                return OpenGOPTests.frameNumber(g)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    @Test func lengthIsTheTimeline() async throws {
        let r = try await rig()
        #expect(r.player.duration == f(53))
        #expect(r.player.lastError == nil)
        try await r.editor.closeProject()
    }

    @Test(.timeLimit(.minutes(2))) func randomSeeksLandOnTheirFrame() async throws {
        let r = try await rig()
        var g = SplitMix64Player(42)
        // Every cut and its neighbours, then random frames.
        var frames = [0, 1, 14, 15, 16, 17, 29, 30, 31, 37, 38, 39, 40, 52]
        for _ in 0..<40 { frames.append(Int.random(in: 0..<53, using: &g)) }
        var wrong: [String] = []
        var stills = 0
        for n in frames {
            await r.player.seek(f(n))
            if r.player.currentTime != f(n) { wrong.append("seek \(n): playhead at \(r.player.currentTime.seconds * 30)") ; continue }
            if let built = r.player.built, built.inOrderStart(at: f(n)) != nil || built.prerolled(at: f(n)) != nil {
                // A leading frame of open-GOP video: the player cannot show it
                // on its own, so the app lays the exact frame over it
                // (FrameCapture, checked frame by frame in OpenGOPTests).
                stills += 1
                continue
            }
            let got = try await shown(r, at: f(n))
            if got == nil { wrong.append("frame \(n): the player gave no picture for it") }
            if let got, got != Self.expected(n) {
                wrong.append("frame \(n): shows source \(got), should be \(Self.expected(n))")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
        #expect(stills > 0 && stills < frames.count / 2, "most frames come straight from the player")
        try await r.editor.closeProject()
    }

    /// Stepping in order can pass a target that starts a clip on a leading
    /// frame; the playhead must still stand on the cut (found in the app:
    /// one frame late with two clips and the player in a window).
    @Test func seekingToACutOnALeadingFrameLandsOnIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-cut-\(UUID().uuidString)")
        let editor = Editor(settings: try UserSettingsStore(directory: dir.appendingPathComponent("home")), prober: AVMediaProber())
        let s = try await editor.createProject(at: dir.appendingPathComponent("p.dmeproj").path, name: "cut",
                                               settings: ProjectSettings(width: 320, height: 240, frameRate: .fps30, dynamicRange: .sdr))
        let main = try #require(await s.project.tracks.first { $0.kind == .main }).id
        try await s.apply([AddMedia(assets: [MediaAsset(id: "src", path: Self.fixture.path, name: "src", fingerprint: "fixture", info: try await AVMediaProber().probe(Self.fixture))]),
                           AddClip(track: main, asset: "src", start: f(0), sourceStart: f(75), sourceDuration: f(15), id: "a"),
                           AddClip(track: main, asset: "src", start: f(15), sourceStart: f(30), sourceDuration: f(15), id: "b")])
        let player = PlayerController(media: MediaContext(editor: editor))
        let layer = AVPlayerLayer(player: player.player)
        layer.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        await player.follow()
        var wrong: [String] = []
        for n in [15, 20, 15, 16, 15, 14, 15, 0, 15] {
            await player.seek(f(n))
            try await Task.sleep(nanoseconds: 300_000_000)
            if player.currentTime != f(n) { wrong.append("seek \(n): playhead at \(player.currentTime.seconds * 30)") }
        }
        #expect(wrong.isEmpty, "\(wrong.joined(separator: ", "))")
        withExtendedLifetime(layer) {}
        try await editor.closeProject()
    }

    @Test func stepsMoveOneFrame() async throws {
        let r = try await rig()
        await r.player.seek(f(10))
        for n in 11...20 {
            await r.player.seek(r.player.currentTime + f(1))
            #expect(r.player.currentTime == f(n))
        }
        await r.player.seek(f(60))
        #expect(r.player.currentTime == f(53), "a seek past the end stops at the end")
        await r.player.seek(Time(seconds: -1))
        #expect(r.player.currentTime == .zero, "a seek before 0 stops at 0")
        try await r.editor.closeProject()
    }

    @Test func anEditKeepsThePlayheadAndColourDoesNotRebuild() async throws {
        let r = try await rig()
        await r.player.seek(f(20))
        let before = r.player.built?.composition
        try await r.session.apply([CreateLook(name: "t", id: "look_t"), AssignLook(look: "look_t", clips: ["b"])])
        await r.player.rebuild()
        #expect(r.player.currentTime == f(20), "a rebuild keeps the playhead")
        #expect(r.player.built?.composition !== before, "assigning a look rebuilds")
        let assigned = r.player.built?.composition
        var u = UpdateLook(id: "look_t")
        u.exposure = 40
        try await r.session.apply([u])
        await r.player.rebuild()
        #expect(r.player.built?.composition === assigned, "a slider change keeps the composition")
        #expect(r.player.currentTime == f(20))
        try await r.session.apply([SplitAt(time: f(22))])
        await r.player.rebuild()
        #expect(r.player.built?.composition !== assigned, "a cut rebuilds")
        #expect(r.player.currentTime == f(20), "and keeps the playhead")
        try await r.editor.closeProject()
    }
}

struct SplitMix64Player: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
