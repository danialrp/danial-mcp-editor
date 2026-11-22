import Foundation
import Testing
@testable import EditorCore

/// Paste (clip.copyTo) and nudge (clip.nudge).
@Suite struct ClipEditTests {
    func project() throws -> Project {
        var p = makeProject()
        p.tracks.insert(Track(id: "over", kind: .overlay, name: "Over"), at: 1)
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(4), id: "a"))
        try run(&p, AddClip(track: "main", asset: "cam", start: s(4), sourceStart: s(10), sourceDuration: s(4), id: "b"))
        try run(&p, AddClip(track: "over", asset: "cam", start: s(1), sourceStart: s(20), sourceDuration: s(2), id: "o"))
        return p
    }

    @Test func pasteKeepsTracksAndSpacingAndInsertsOnTheMainTrack() throws {
        var p = try project()
        try run(&p, CopyClipsTo(ids: ["a", "o"], start: s(8)))
        #expect(p.tracks[0].clips.count == 3 && p.tracks[0].clips[2].start == s(8) && p.tracks[0].clips[2].sourceStart == s(0))
        #expect(p.tracks[1].clips.count == 2 && p.tracks[1].clips[1].start == s(9), "the overlay copy keeps its 1 s offset")
        // Pasting in the middle of the main track inserts and pushes later clips.
        try run(&p, CopyClipsTo(ids: ["a"], start: s(4)))
        #expect(p.tracks[0].clips.map(\.start) == [s(0), s(4), s(8), s(12)])
        // On an overlay the space must be free.
        #expect(throws: EditorError.self) { try run(&p, CopyClipsTo(ids: ["o"], start: s(1.5))) }
    }

    @Test func nudgeMovesByFramesAndRefusesOverlapsAndNegativeTimes() throws {
        var p = try project()
        try run(&p, NudgeClips(ids: ["o"], frames: 3))
        #expect(p.tracks[1].clips[0].start == s(1) + Time(ticks: FrameRate.fps60.frameDuration.ticks * 3))
        #expect(throws: EditorError.self) { try run(&p, NudgeClips(ids: ["a"], frames: -1)) }
        #expect(throws: EditorError.self) { try run(&p, NudgeClips(ids: ["a"], frames: 1)) }
        #expect(p.tracks[0].clips[0].start == s(0), "a refused nudge changes nothing")
        try run(&p, NudgeClips(ids: ["a", "b"], frames: 6))
        #expect(p.tracks[0].clips.map(\.start) == [s(0.1), s(4.1)], "clips moving together do not collide with each other")
    }

    @Test func extractAudioMovesTheSoundToAnAudioTrackAndMutesThePicture() throws {
        var p = try project()
        try run(&p, SetClipAudio(ids: ["a"], gainDB: 3))
        try run(&p, DetachAudio(ids: ["a", "b"]))
        let music = p.tracks.first { $0.id == "music" }!
        #expect(music.clips.count == 2, "the free audio track takes both")
        #expect(music.clips.map(\.start) == [s(0), s(4)] && music.clips[0].sourceStart == s(0) && music.clips[1].sourceStart == s(10))
        #expect(music.clips[0].gainDB == 3, "gain goes with the sound")
        #expect(p.tracks[0].clips.allSatisfy { $0.muted }, "the pictures are muted")
        // The audio track is now busy there: the next one goes to a new track.
        try run(&p, DetachAudio(ids: ["o"]))
        #expect(p.tracks.filter { $0.kind == .audio }.count == 2 && p.tracks.last?.clips.first?.start == s(1), "a new audio track takes it")
        #expect(throws: EditorError.self) { try run(&p, DetachAudio(ids: [music.clips[0].id])) }
    }

    @Test func freezeFrameHoldsOneSourceFrameAndPushesTheRest() throws {
        var p = try project()
        try run(&p, SetClipAudio(ids: ["a"], gainDB: 2))
        try run(&p, FreezeFrame(time: s(1), duration: s(1.5)))
        let m = p.tracks[0].clips
        #expect(m.map(\.start) == [s(0), s(1), s(2.5), s(5.5)], "split at 1 s, the hold inserted, later clips pushed")
        let held = m[1]
        #expect(held.duration == s(1.5) && held.sourceStart == s(1) && abs(held.sourceDuration.seconds - 1.0 / 60) < 1e-6)
        #expect(held.muted && held.effects.isEmpty && held.gainDB == 2)
        #expect(m[2].sourceStart == s(1), "the rest of the clip carries on from the held frame")
        #expect(throws: EditorError.self) { try run(&p, FreezeFrame(time: s(30))) }
    }
}
