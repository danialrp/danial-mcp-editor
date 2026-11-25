import EditorCore
import Foundation
import Testing
@testable import EditorKit

/// The bugs the full property test found, each as a plain case, so they
/// stay fixed even when the random runs no longer reach them.
@Suite struct FoundByPropertyTests {
    func session(compactEvery: Int = 1000) throws -> (EditorSession, URL) {
        let url = tempDir().appendingPathComponent("p.dmeproj")
        return (try EditorSession.create(at: url, project: FullPropertyTests.project(), compactEvery: compactEvery), url)
    }

    @Test func aHugeNudgeIsRefusedNotACrash() async throws {
        let (s, _) = try session()
        try await s.apply([AddClip(track: "main", asset: "cam", sourceDuration: Time(seconds: 2), id: "a")])
        await #expect(throws: EditorError.self) { try await s.apply([NudgeClips(ids: ["a"], frames: Int.max / 4)]) }
    }

    @Test func aTimeBeyondTheLimitIsRefused() throws {
        #expect(throws: EditorError.self) { try CommandRegistry.decode(name: "marker.add", arguments: Data(#"{"time":1e15}"#.utf8)) }
        #expect(throws: EditorError.self) { try CommandRegistry.decode(name: "marker.add", arguments: Data(#"{"time":2e9}"#.utf8)) }
        #expect(throws: Never.self) { try CommandRegistry.decode(name: "marker.add", arguments: Data(#"{"time":1e8}"#.utf8)) }
        // A saved project is read with a wider limit, so it always opens.
        var p = FullPropertyTests.project()
        p.markers = [Marker(id: "m", time: Time(seconds: 5e9), name: "far")]
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)) == p)
    }

    @Test func undoOfAStepOlderThanTheSnapshotSurvivesAReopen() async throws {
        let (s, url) = try session(compactEvery: 2)
        try await s.apply([AddMarker(time: Time(seconds: 1), name: "one", id: "m1")])
        try await s.apply([AddMarker(time: Time(seconds: 2), name: "two", id: "m2")])   // the journal is compacted here
        try await s.undo()
        let afterUndo = await s.project
        try await s.redo()
        try await s.undo()
        await s.abandonForTesting()
        let r = try await EditorSession.open(at: url)
        #expect(await r.project == afterUndo)
        try await r.redo()
        #expect(await r.project.markers.map(\.id) == ["m1", "m2"])
        try await r.close()
    }

    @Test func removingMediaRemovesItsTranscripts() async throws {
        let (s, _) = try session()
        try await s.apply([AddTranscript(transcript: Transcript(id: "t", asset: "song", language: "en", engine: "import",
                                                                sourceStart: .zero, sourceEnd: Time(seconds: 5), words: []))])
        try await s.apply([RemoveMedia(ids: ["song"])])
        #expect(await s.project.transcripts.isEmpty)
    }

    @Test func aLookFromAProfileFileIsChecked() async throws {
        let (s, _) = try session()
        var bad = Look(id: "look_p", name: "p")
        bad.exposure = 300
        await #expect(throws: EditorError.self) { try await s.apply([PutLook(look: bad)]) }
        var badColour = Look(id: "look_p", name: "p")
        badColour.picked = [PickedColor(id: "pc", color: "red")]
        await #expect(throws: EditorError.self) { try await s.apply([PutLook(look: badColour)]) }
        try await s.apply([PutLook(look: Look(id: "look_p", name: "p"))])
    }

    @Test func relinkingKeepsSoundForSoundClips() async throws {
        let (s, _) = try session()
        try await s.apply([AddClip(track: "music", asset: "cam", sourceDuration: Time(seconds: 2), id: "a")])
        let silent = MediaInfo(duration: Time(seconds: 600), video: VideoInfo(width: 1080, height: 1920, frameRate: 60, codec: "hvc1"), audio: nil)
        await #expect(throws: EditorError.self) {
            try await s.apply([SetMediaPath(id: "cam", path: "/y/cam.mov", name: "cam.mov", fingerprint: "9", info: silent)])
        }
    }

    @Test func aNegativeHistoryLimitIsNotACrash() async throws {
        let (s, _) = try session()
        #expect(await s.history(limit: -5).isEmpty)
    }

    @Test func splittingALongFreezeKeepsSourceInEveryPiece() async throws {
        let (s, _) = try session()
        try await s.apply([AddClip(track: "main", asset: "cam", sourceDuration: Time(seconds: 2), id: "a")])
        try await s.apply([FreezeFrame(time: Time(seconds: 1), duration: Time(seconds: 100_000))])
        try await s.apply([SplitAt(time: Time(seconds: 1) + FrameRate.fps60.frameDuration)])
        for c in await s.project.tracks[0].clips { #expect(c.sourceDuration.ticks > 0, "\(c.id) reads nothing") }
    }

    @Test func copiesGetTheirOwnEffectIDs() async throws {
        let (s, _) = try session()
        try await s.apply([AddClip(track: "main", asset: "cam", sourceDuration: Time(seconds: 2), id: "a"),
                           PutEffect(clip: "a", instance: EffectInstance(id: "fx", effect: "blur.gaussian", kind: .filter))])
        try await s.apply([DuplicateClips(ids: ["a"])])
        try await s.apply([CopyClipsTo(ids: ["a"], start: Time(seconds: 30))])
        let ids = await s.project.tracks[0].clips.flatMap(\.effects).map(\.id)
        #expect(ids.count == 3 && Set(ids).count == 3)
    }

    @Test func importingAMissingOrBrokenTranscriptSaysWhy() async throws {
        let (s, url) = try session()
        let editor = Editor(settings: try UserSettingsStore(directory: url.deletingLastPathComponent().appendingPathComponent("home")),
                            prober: RefusingProber())
        await editor.adoptForTesting(s)
        let tool = ToolCatalog.named("transcript.import")!
        await #expect(throws: EditorError.self) {
            _ = try await tool.call(editor, arguments: .object(["path": .string("/x/none.json"), "asset": .string("cam")]))
        }
        let bad = url.deletingLastPathComponent().appendingPathComponent("bad.txt")
        try Data("not json".utf8).write(to: bad)
        await #expect(throws: EditorError.self) {
            _ = try await tool.call(editor, arguments: .object(["path": .string(bad.path), "asset": .string("cam")]))
        }
    }

    @Test func aProfileLoadsTwiceWithItsPickedColours() async throws {
        let (s, url) = try session()
        let editor = Editor(settings: try UserSettingsStore(directory: url.deletingLastPathComponent().appendingPathComponent("home")),
                            prober: RefusingProber())
        await editor.adoptForTesting(s)
        try await s.apply([CreateLook(name: "skin", id: "look_a")])
        try await s.apply([AddPickedColor(look: "look_a", color: "#E0A080")])
        _ = try await ToolCatalog.named("look.saveProfile")!.call(editor, arguments: .object(["look": .string("look_a"), "name": .string("skin")]))
        for _ in 0..<2 {
            _ = try await ToolCatalog.named("look.loadProfile")!.call(editor, arguments: .object(["name": .string("skin")]))
        }
        #expect(await s.project.looks.count == 3)
        #expect(FullPropertyTests.problems(await s.project).isEmpty)
    }

    @Test func timesNearTheLimitStillReopen() async throws {
        let (s, url) = try session()
        try await s.apply([AddClip(track: "main", asset: "cam", sourceDuration: Time(seconds: 2), id: "a")])
        _ = try? await s.apply([FreezeFrame(time: Time(seconds: 1), duration: Time(seconds: 9e11))])
        for _ in 0..<2 { _ = try? await s.apply([DuplicateClips(ids: await s.project.tracks[0].clips.map(\.id))]) }
        _ = try? await s.apply([AddMarker(time: Time(seconds: 9.9e11), name: "far")])
        let before = await s.project
        try await s.close()
        let r = try await EditorSession.open(at: url)
        #expect(await r.project == before)
        try await r.close()
    }

    @Test func aClipReadingOneTickSurvivesEveryCut() async throws {
        for op in 0..<4 {
            var p = FullPropertyTests.project()
            p.tracks[0].clips = [Clip(id: "tiny", asset: "cam", start: .zero, duration: Time(seconds: 1), sourceStart: Time(seconds: 3), sourceDuration: Time(ticks: 1))]
            let s = try EditorSession.create(at: tempDir().appendingPathComponent("p.dmeproj"), project: p)
            let mid = Time(seconds: 0.5)
            let c: any EditorCommand = [SplitAt(time: mid) as any EditorCommand,
                                        DeleteRange(start: Time(seconds: 0.25), end: Time(seconds: 0.75), ripple: true),
                                        DeleteToClipEdge(time: mid, side: .left, ripple: true),
                                        FreezeFrame(time: mid)][op]
            _ = try? await s.apply([c])
            let bad = FullPropertyTests.problems(await s.project)
            #expect(bad.isEmpty, "\(c.name): \(bad)")
        }
    }
}
