import EditorCore
import Foundation
import Testing
@testable import EditorKit

/// A small, seedable random source, so a failing sequence can be run again.
struct SplitMix64: RandomNumberGenerator {
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

/// Random edits, as a person or an agent might make them in any order: cuts,
/// deletes with and without ripple, moves between tracks, trims, slips,
/// speed, sound, nudges, freezes, undo and redo. After every step the rules
/// of the timeline are checked; an edit that is refused must change nothing;
/// undo must give back exactly the project before the edit; and the journal
/// must rebuild exactly the final project.
@Suite("Edits in random order keep the timeline sound", .serialized)
struct EditPropertyTests {
    static let frame = FrameRate.fps60.frameDuration

    static func project() -> Project {
        var p = seededProject()
        p.tracks = [Track(id: "main", kind: .main, name: "Main"),
                    Track(id: "over", kind: .overlay, name: "Overlay"),
                    Track(id: "music", kind: .audio, name: "Music")]
        p.media.append(MediaAsset(id: "song", path: "/x/song.wav", name: "song.wav", fingerprint: "2",
                                  info: MediaInfo(duration: Time(seconds: 600), video: nil,
                                                  audio: AudioInfo(sampleRate: 48000, channels: 2, codec: "lpcm"))))
        return p
    }

    /// The rules every project must keep, whatever was done to it.
    static func problems(_ p: Project) -> [String] {
        var out: [String] = []
        var ids = Set<EntityID>()
        for t in p.tracks {
            for (i, c) in t.clips.enumerated() {
                if !ids.insert(c.id).inserted { out.append("\(c.id) appears twice") }
                if c.start.ticks < 0 { out.append("\(c.id) starts before 0") }
                if c.duration < frame { out.append("\(c.id) is shorter than a frame (\(c.duration.ticks) ticks)") }
                if c.start.ticks % frame.ticks != 0 { out.append("\(c.id) starts off the frame grid (\(c.start.ticks))") }
                if c.duration.ticks % frame.ticks != 0 { out.append("\(c.id) lasts off the frame grid (\(c.duration.ticks))") }
                if c.sourceStart.ticks < 0 { out.append("\(c.id) reads before its file starts") }
                if c.sourceDuration.ticks <= 0 { out.append("\(c.id) reads nothing from its file") }
                if let a = p.media.first(where: { $0.id == c.asset }), a.info.video != nil || a.info.audio != nil,
                   c.sourceEnd > a.info.duration + frame {
                    out.append("\(c.id) reads past the end of its file (\(c.sourceEnd.seconds) > \(a.info.duration.seconds))")
                }
                if c.fadeIn + c.fadeOut > c.duration { out.append("\(c.id) fades are longer than the clip") }
                if !c.gainDB.isFinite { out.append("\(c.id) gain is not a number") }
                if i > 0 {
                    let b = t.clips[i - 1]
                    if b.start > c.start { out.append("\(t.id) clips out of order at \(c.id)") }
                    if b.end > c.start { out.append("\(t.id): \(b.id) overlaps \(c.id) (\(b.end.seconds) > \(c.start.seconds))") }
                }
            }
        }
        return out
    }

    enum Op: CustomStringConvertible {
        case cmd(any EditorCommand), undo, redo
        var description: String {
            switch self {
            case .cmd(let c): "\(type(of: c)) \(String(describing: c).prefix(160))"
            case .undo: "undo"
            case .redo: "redo"
            }
        }
    }

    static func randomOp(_ p: Project, _ g: inout SplitMix64) -> Op {
        let clips = p.tracks.flatMap(\.clips)
        let end = max(p.duration.seconds, 1)
        func t(_ upTo: Double) -> Time { Time(seconds: Double.random(in: 0...upTo, using: &g)).snapped(to: .fps60) }
        func pick() -> EntityID? { clips.randomElement(using: &g)?.id }
        let video = ["main", "over"]
        switch Int.random(in: 0..<20, using: &g) {
        case 0, 1:
            let tr = video.randomElement(using: &g)!
            return .cmd(AddClip(track: EntityID(tr), asset: "cam", start: t(end + 5), sourceStart: t(3000),
                                sourceDuration: Time(seconds: Double.random(in: 0.05...20, using: &g)).snapped(to: .fps60)))
        case 2:
            return .cmd(AddClip(track: "music", asset: "song", start: t(end), sourceStart: t(500),
                                sourceDuration: Time(seconds: Double.random(in: 0.05...30, using: &g)).snapped(to: .fps60)))
        case 3, 4:
            return .cmd(SplitAt(time: t(end), allTracks: Bool.random(using: &g) ? true : nil))
        case 5:
            return .cmd(DeleteToClipEdge(time: t(end), side: Bool.random(using: &g) ? .left : .right,
                                         ripple: Bool.random(using: &g)))
        case 6:
            let a = t(end), b = a + Time(seconds: Double.random(in: 0.02...4, using: &g)).snapped(to: .fps60)
            return .cmd(DeleteRange(start: a, end: b, ripple: Bool.random(using: &g), allTracks: Bool.random(using: &g) ? true : nil))
        case 7, 8:
            guard let id = pick() else { return .undo }
            let isSound = p.tracks.first { $0.clips.contains { $0.id == id } }?.kind == .audio
            return .cmd(MoveClip(id: id, start: t(end + 5), track: isSound ? nil : EntityID(video.randomElement(using: &g)!)))
        case 9, 10:
            guard let c = clips.randomElement(using: &g) else { return .undo }
            let edge: TrimClip.Edge = Bool.random(using: &g) ? .start : .end
            let to = c.start + Time(seconds: Double.random(in: -3...(c.duration.seconds + 3), using: &g)).snapped(to: .fps60)
            return .cmd(TrimClip(id: c.id, edge: edge, time: Time.max(.zero, to)))
        case 11:
            guard let id = pick() else { return .undo }
            return .cmd(SlipClip(id: id, by: Time(seconds: Double.random(in: -5...5, using: &g)).snapped(to: .fps60)))
        case 12:
            guard let id = pick() else { return .undo }
            return .cmd(RemoveClips(ids: [id], ripple: Bool.random(using: &g)))
        case 13:
            guard let id = pick() else { return .undo }
            return .cmd(SetClipSpeed(ids: [id], speed: [0.25, 0.5, 1, 1.22, 1.5, 2, 4].randomElement(using: &g)!,
                                     ripple: Bool.random(using: &g)))
        case 14:
            guard let id = pick() else { return .undo }
            return .cmd(SetClipAudio(ids: [id], gainDB: Double.random(in: -60...12, using: &g), muted: Bool.random(using: &g),
                                     fadeIn: Time(seconds: Double.random(in: 0...3, using: &g)).snapped(to: .fps60),
                                     fadeOut: Time(seconds: Double.random(in: 0...3, using: &g)).snapped(to: .fps60)))
        case 15:
            guard let id = pick() else { return .undo }
            return .cmd(NudgeClips(ids: [id], frames: Int.random(in: -30...30, using: &g)))
        case 16:
            return .cmd(CloseGaps(track: Bool.random(using: &g) ? nil : "over"))
        case 17:
            guard let id = pick() else { return .undo }
            return .cmd(DuplicateClips(ids: [id]))
        case 18:
            return .undo
        default:
            return .redo
        }
    }

    @Test(arguments: 0..<200)
    func randomEdits(_ seed: Int) async throws {
        var g = SplitMix64(UInt64(seed) &* 7919 &+ 17)
        let url = tempDir().appendingPathComponent("p.dmeproj")
        let s = try EditorSession.create(at: url, project: Self.project())
        try await s.apply([AddClip(track: "main", asset: "cam", sourceStart: Time(seconds: 10), sourceDuration: Time(seconds: 30), id: "first")])
        var log: [String] = []
        var applied = 0
        for step in 0..<80 {
            let before = await s.project, rev = await s.revision
            let op = Self.randomOp(before, &g)
            log.append("\(step): \(op)")
            var refused = false
            do {
                switch op {
                case .cmd(let c): try await s.apply([c])
                case .undo: try await s.undo()
                case .redo: try await s.redo()
                }
            } catch is EditorError {
                refused = true
            }
            let after = await s.project, revAfter = await s.revision
            if refused {
                #expect(after == before && revAfter == rev, "a refused edit changed the project\n\(log.suffix(4).joined(separator: "\n"))")
            }
            let bad = Self.problems(after)
            #expect(bad.isEmpty, "seed \(seed) step \(step): \(bad.prefix(5).joined(separator: "; "))\n\(log.suffix(4).joined(separator: "\n"))")
            if !bad.isEmpty { break }
            // Undo gives back exactly the project before an applied edit; redo the edit again.
            if !refused { applied += 1 }
            if !refused, case .cmd = op {
                try await s.undo()
                #expect(await s.project == before, "undo after \(op) did not restore the project")
                try await s.redo()
                #expect(await s.project == after, "redo after \(op) did not give the edit back")
            }
        }
        #expect(applied > 30, "most random edits should apply (\(applied) of 80)")
        let final = await s.project
        await s.abandonForTesting()
        let reopened = try await EditorSession.open(at: url)
        #expect(await reopened.project == final, "the journal does not rebuild the project (seed \(seed))")
        try await reopened.close()
    }

    /// A cut keeps every frame: the pieces cover the clip exactly and read
    /// on from each other in the file.
    @Test(arguments: [0.5, 1.22, 2.0])
    func splitKeepsTimeAndSource(_ speed: Double) async throws {
        let s = try EditorSession.create(at: tempDir().appendingPathComponent("p"), project: Self.project())
        try await s.apply([AddClip(track: "main", asset: "cam", start: Time(seconds: 1), sourceStart: Time(seconds: 5),
                                   sourceDuration: Time(seconds: 12), id: "a")])
        try await s.apply([SetClipSpeed(ids: ["a"], speed: speed)])
        let whole = await s.project.tracks[0].clips[0]
        var g = SplitMix64(UInt64(speed * 1000))
        for _ in 0..<12 {
            let clips = await s.project.tracks[0].clips
            guard let c = clips.randomElement(using: &g), c.duration.ticks > Self.frame.ticks * 2 else { continue }
            let at = c.start + Time(ticks: Self.frame.ticks * Int64.random(in: 1..<(c.duration.ticks / Self.frame.ticks), using: &g))
            try await s.apply([SplitAt(time: at)])
        }
        let pieces = await s.project.tracks[0].clips
        #expect(pieces.first?.start == whole.start && pieces.last?.end == whole.end, "the pieces cover the clip")
        #expect(pieces.map(\.duration.ticks).reduce(0, +) == whole.duration.ticks)
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            #expect(a.end == b.start, "no gap or overlap at a cut")
            #expect(abs((a.sourceEnd - b.sourceStart).ticks) <= 1, "the file reads on across a cut")
        }
        #expect(abs((pieces.last!.sourceEnd - whole.sourceEnd).ticks) <= Int64(pieces.count), "the same part of the file in all")
        try await s.close()
    }

    /// Ripple delete of a range takes exactly its length out of the timeline
    /// and leaves what is before it alone.
    @Test func rippleDeleteRangeShortensByItsLength() async throws {
        let s = try EditorSession.create(at: tempDir().appendingPathComponent("p"), project: Self.project())
        try await s.apply([AddClip(track: "main", asset: "cam", sourceDuration: Time(seconds: 10), id: "a"),
                           AddClip(track: "main", asset: "cam", start: Time(seconds: 10), sourceStart: Time(seconds: 20), sourceDuration: Time(seconds: 10), id: "b")])
        let before = await s.project.duration
        try await s.apply([DeleteRange(start: Time(seconds: 8), end: Time(seconds: 12.5), ripple: true, allTracks: true)])
        let p = await s.project
        #expect(p.duration == before - Time(seconds: 4.5))
        #expect(p.tracks[0].clips[0].start == .zero && p.tracks[0].clips[0].end == Time(seconds: 8))
        #expect(p.tracks[0].clips[1].start == Time(seconds: 8), "what follows closes up")
        #expect(p.tracks[0].clips[1].sourceStart == Time(seconds: 22.5), "and starts where the range ended in its file")
        try await s.close()
    }
}
