import Foundation
import Testing
@testable import EditorCore

/// A project with a main track, an audio track and one 60 s video asset.
func makeProject(fps: FrameRate = .fps60) -> Project {
    var p = Project(id: "project_t", name: "t", settings: ProjectSettings(width: 1440, height: 2560, frameRate: fps, dynamicRange: .hlg))
    p.tracks = [Track(id: "main", kind: .main, name: "Main"), Track(id: "music", kind: .audio, name: "Music")]
    p.media = [
        MediaAsset(id: "cam", path: "/x/cam.mov", name: "cam.mov", fingerprint: "1",
                   info: MediaInfo(duration: Time(seconds: 60), video: VideoInfo(width: 3840, height: 2160, frameRate: 60, codec: "hvc1"),
                                   audio: AudioInfo(sampleRate: 48000, channels: 2, codec: "aac"))),
        MediaAsset(id: "song", path: "/x/song.wav", name: "song.wav", fingerprint: "2",
                   info: MediaInfo(duration: Time(seconds: 30), video: nil, audio: AudioInfo(sampleRate: 48000, channels: 2, codec: "lpcm"))),
    ]
    return p
}

func run(_ p: inout Project, _ c: some EditorCommand) throws {
    var c = c
    try c.prepare(in: p)
    try c.apply(to: &p)
}

func s(_ x: Double) -> Time { Time(seconds: x) }

@Suite struct TimelineTests {
    @Test func appendsClipsAndSnapsToFrames() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        try run(&p, AddClip(track: "main", asset: "cam", start: s(10.004), sourceStart: s(20), sourceDuration: s(5), id: "b"))
        let clips = p.tracks[0].clips
        #expect(clips.map(\.id) == ["a", "b"])
        #expect(clips[1].start == s(10))   // 10.004 snapped to the 60 fps grid
        #expect(clips[1].end == s(15))
    }

    @Test func refusesOverlapInPlaceMode() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        #expect(throws: EditorError.self) {
            try run(&p, AddClip(track: "main", asset: "cam", start: s(5), sourceDuration: s(2)))
        }
    }

    @Test func insertModePushesLaterClipsAndSplits() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        try run(&p, AddClip(track: "main", asset: "cam", start: s(4), sourceStart: s(30), sourceDuration: s(2), mode: .insert, id: "x"))
        let c = p.tracks[0].clips
        #expect(c.count == 3)
        #expect(c[0].range == TimeRange(start: s(0), end: s(4)))
        #expect(c[1].id == "x" && c[1].range == TimeRange(start: s(4), end: s(6)))
        #expect(c[2].range == TimeRange(start: s(6), end: s(12)) && c[2].sourceStart == s(4))
    }

    @Test func splitKeepsSourceContinuityWithSpeed() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(12.2), speed: 1.22, id: "a"))
        #expect(p.tracks[0].clips[0].duration == s(10))
        try run(&p, SplitAt(time: s(5)))
        let c = p.tracks[0].clips
        #expect(c.count == 2)
        #expect(c[0].end == c[1].start)
        #expect(c[0].sourceEnd == c[1].sourceStart)
        #expect(c[1].sourceEnd == s(12.2))
        #expect(c[0].sourceDuration == s(6.1))
    }

    @Test func deleteLeftAndRightRippleTheMainTrack() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        try run(&p, AddClip(track: "main", asset: "cam", sourceStart: s(20), sourceDuration: s(10), id: "b"))
        try run(&p, DeleteToClipEdge(time: s(13), side: .left))      // removes 10-13
        #expect(p.tracks[0].clips.map(\.range) == [TimeRange(start: s(0), end: s(10)), TimeRange(start: s(10), end: s(17))])
        #expect(p.tracks[0].clips[1].sourceStart == s(23))
        try run(&p, DeleteToClipEdge(time: s(4), side: .right))      // removes 4-10
        #expect(p.tracks[0].clips.map(\.range) == [TimeRange(start: s(0), end: s(4)), TimeRange(start: s(4), end: s(11))])
    }

    @Test func deleteLeftAtABoundaryActsOnThePreviousClip() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "b"))
        try run(&p, SplitAt(time: s(10)))   // already a boundary: no change
        #expect(p.tracks[0].clips.count == 2)
        try run(&p, DeleteToClipEdge(time: s(10), side: .left))
        #expect(p.tracks[0].clips.map(\.id) == ["b"])
        #expect(p.tracks[0].clips[0].start == .zero)
    }

    @Test func deleteRangeLeavesOtherTracksAlone() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(20), id: "a"))
        try run(&p, AddClip(track: "music", asset: "song", start: s(15), id: "m"))
        try run(&p, DeleteRange(start: s(2), end: s(5)))
        #expect(p.tracks[0].end == s(17))
        #expect(p.tracks[1].clips[0].start == s(15))
    }

    @Test func removeRipplesOnlyOnMainByDefault() throws {
        var p = makeProject()
        for i in 0..<3 { try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(5), id: EntityID("c\(i)"))) }
        try run(&p, RemoveClips(ids: ["c1"]))
        #expect(p.tracks[0].clips.map(\.start) == [s(0), s(5)])
    }

    @Test func trimAndSlipStayInsideTheSource() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", start: s(1), sourceStart: s(5), sourceDuration: s(10), id: "a"))
        try run(&p, TrimClip(id: "a", edge: .start, time: s(3)))
        #expect(p.tracks[0].clips[0].sourceStart == s(7))
        #expect(p.tracks[0].clips[0].end == s(11))
        #expect(throws: EditorError.self) { try run(&p, SlipClip(id: "a", by: s(-8))) }
        try run(&p, SlipClip(id: "a", by: s(-7)))
        #expect(p.tracks[0].clips[0].sourceStart == .zero)
        #expect(throws: EditorError.self) { try run(&p, TrimClip(id: "a", edge: .end, time: s(70))) }
    }

    @Test func lockedTracksRefuseEdits() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        try run(&p, SetTrack(id: "main", locked: true))
        #expect(throws: EditorError.self) { try run(&p, SplitAt(time: s(5))) }
        try run(&p, SplitAt(time: s(5), allTracks: true))   // skips the locked track
        #expect(p.tracks[0].clips.count == 1)
    }

    @Test func audioOnlyMediaCannotGoOnTheMainTrack() throws {
        var p = makeProject()
        #expect(throws: EditorError.self) { try run(&p, AddClip(track: "main", asset: "song")) }
    }

    @Test func duplicateGoesRightAfterTheOriginal() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(2), id: "a"))
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(3), id: "b"))
        try run(&p, DuplicateClips(ids: ["a"]))
        let c = p.tracks[0].clips
        #expect(c.count == 3 && c[1].start == s(2) && c[1].sourceStart == .zero && c[2].id == "b" && c[2].start == s(4))
    }

    @Test func preparedCommandsReplayToTheSameResult() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(30), id: "a"))
        var cmd = SplitAt(time: s(7.5))
        try cmd.prepare(in: p)
        var first = p, second = p
        try cmd.apply(to: &first)
        let decoded = try CommandRegistry.decode(name: SplitAt.name, arguments: CommandRegistry.encode(cmd))
        try decoded.apply(to: &second)
        #expect(first == second)
    }

    @Test func manySplitsDoNotDrift() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(60), speed: 1.22, id: "a"))
        let total = p.tracks[0].clips[0].sourceDuration
        for i in 1..<400 { try run(&p, SplitAt(time: FrameRate.fps60.time(ofFrame: Int64(i * 7)))) }
        let c = p.tracks[0].clips
        #expect(c.count == 400)
        for i in 1..<c.count {
            #expect(c[i - 1].end == c[i].start)
            #expect(c[i - 1].sourceEnd == c[i].sourceStart)
        }
        #expect(c.last!.sourceEnd == total)
    }
}

@Suite struct ClipPropertyTests {
    @Test func speedChangeRipplesTheMainTrack() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(12.2), id: "a"))
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(5), id: "b"))
        try run(&p, SetClipSpeed(ids: ["a"], speed: 1.22))
        let c = p.tracks[0].clips
        #expect(c[0].duration == s(10))
        #expect(c[1].start == s(10))
        #expect(abs(c[0].speed - 1.22) < 0.001)
    }

    @Test func speedChangeWithoutRippleRefusesOverlap() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(5), id: "b"))
        #expect(throws: EditorError.self) { try run(&p, SetClipSpeed(ids: ["a"], speed: 0.5, ripple: false)) }
    }

    @Test func audioAndTransformAreValidated() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(2), id: "a"))
        try run(&p, SetClipAudio(ids: ["a"], gainDB: -6, fadeIn: s(0.5)))
        #expect(p.tracks[0].clips[0].gainDB == -6)
        #expect(throws: EditorError.self) { try run(&p, SetClipAudio(ids: ["a"], fadeOut: s(1.8))) }
        var t = SetClipTransform(ids: ["a"])
        t.scale = 1.2
        t.opacity = 0.5
        try run(&p, t)
        #expect(p.tracks[0].clips[0].transform.scale == 1.2 && p.tracks[0].clips[0].opacity == 0.5)
    }

    @Test func oldFilesWithoutNewFieldsStillLoad() throws {
        let json = #"{"id":"a","asset":"cam","start":0,"duration":1,"sourceStart":0,"sourceDuration":1}"#
        let c = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(c.gainDB == 0 && c.opacity == 1 && c.transform == .identity)
    }
}
