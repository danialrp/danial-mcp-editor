import EditorCore
import Foundation
import Testing
@testable import EditorKit

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("dme-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func seededProject() -> Project {
    var p = Project(id: "project_t", name: "t", settings: ProjectSettings(width: 1440, height: 2560, frameRate: .fps60, dynamicRange: .hlg))
    p.tracks = [Track(id: "main", kind: .main, name: "Main")]
    p.media = [MediaAsset(id: "cam", path: "/x/cam.mov", name: "cam.mov", fingerprint: "1",
                          info: MediaInfo(duration: Time(seconds: 3600),
                                          video: VideoInfo(width: 3840, height: 2160, frameRate: 60, codec: "hvc1"),
                                          audio: AudioInfo(sampleRate: 48000, channels: 2, codec: "aac")))]
    return p
}

/// 2,000 one-second clips with gaps of one frame, as one batch.
func manyClips(_ n: Int) -> [any EditorCommand] {
    (0..<n).map { i in
        AddClip(track: "main", asset: "cam", start: Time(seconds: Double(i) * 1.5),
                sourceStart: Time(seconds: Double(i)), sourceDuration: Time(seconds: 1))
    }
}

@Suite struct SessionTests {
    @Test func undoRedoAndRevision() async throws {
        let url = tempDir().appendingPathComponent("p.dmeproj")
        let s = try EditorSession.create(at: url, project: seededProject())
        try await s.apply([AddClip(track: "main", asset: "cam", sourceDuration: Time(seconds: 10), id: "a")])
        try await s.apply([SplitAt(time: Time(seconds: 4))])
        #expect(await s.project.tracks[0].clips.count == 2)
        #expect(await s.revision == 2)
        try await s.undo()
        #expect(await s.project.tracks[0].clips.count == 1)
        try await s.redo()
        #expect(await s.project.tracks[0].clips.count == 2)
        try await s.revert(to: 0)
        #expect(await s.project.tracks[0].clips.isEmpty)
        try await s.close()
    }

    @Test func staleRevisionAndDryRunChangeNothing() async throws {
        let s = try EditorSession.create(at: tempDir().appendingPathComponent("p"), project: seededProject())
        let r = try await s.apply([AddClip(track: "main", asset: "cam", sourceDuration: Time(seconds: 10))], dryRun: true)
        #expect(r.dryRun && r.applied.count == 1)
        #expect(await s.revision == 0)
        await #expect(throws: EditorError.self) {
            try await s.apply([AddClip(track: "main", asset: "cam")], ifRevision: 5)
        }
        try await s.close()
    }

    @Test func aFailingBatchAppliesNothing() async throws {
        let s = try EditorSession.create(at: tempDir().appendingPathComponent("p"), project: seededProject())
        await #expect(throws: EditorError.self) {
            try await s.apply([AddClip(track: "main", asset: "cam", sourceDuration: Time(seconds: 10)),
                               AddClip(track: "main", asset: "nope")])
        }
        #expect(await s.revision == 0)
        #expect(await s.project.tracks[0].clips.isEmpty)
        try await s.close()
    }

    @Test func crashRecoveryReplaysTheJournal() async throws {
        let url = tempDir().appendingPathComponent("p.dmeproj")
        let s = try EditorSession.create(at: url, project: seededProject())
        try await s.apply(manyClips(50))
        try await s.apply([SplitAt(time: Time(seconds: 0.5))])
        try await s.apply([RemoveClips(ids: [await s.project.tracks[0].clips[3].id])])
        try await s.undo()
        let expected = await s.project
        await s.abandonForTesting()   // no snapshot: as if the process were killed

        let reopened = try await EditorSession.open(at: url)
        #expect(await reopened.project == expected)
        #expect(await reopened.revision == 4)
        #expect(await reopened.canRedo)
        try await reopened.redo()
        try await reopened.close()
    }

    @Test func aTornLastJournalLineIsDropped() async throws {
        let url = tempDir().appendingPathComponent("p.dmeproj")
        let s = try EditorSession.create(at: url, project: seededProject())
        try await s.apply([AddClip(track: "main", asset: "cam", sourceDuration: Time(seconds: 10))])
        await s.abandonForTesting()
        let journal = url.appendingPathComponent("journal.jsonl")
        let h = try FileHandle(forWritingTo: journal)
        h.seekToEndOfFile()
        h.write(Data("{\"revision\":2,\"op\":\"app".utf8))   // a write cut short
        try h.close()
        let r = try await EditorSession.open(at: url)
        #expect(await r.revision == 1)
        try await r.close()
    }

    @Test func aSecondProcessCannotOpenTheSameProject() async throws {
        let url = tempDir().appendingPathComponent("p.dmeproj")
        let s = try EditorSession.create(at: url, project: seededProject())
        await #expect(throws: EditorError.self) { _ = try await EditorSession.open(at: url) }
        try await s.close()
    }

    @Test func timedPerformanceOnA2000ClipTimeline() async throws {
        let url = tempDir().appendingPathComponent("p.dmeproj")
        let s = try EditorSession.create(at: url, project: seededProject())
        let clock = ContinuousClock()

        let build = try await clock.measure { try await s.apply(manyClips(2000)) }
        #expect(await s.project.tracks[0].clips.count == 2000)

        let one = try await clock.measure { try await s.apply([SplitAt(time: Time(seconds: 1500.5))]) }

        let splits: [any EditorCommand] = (0..<500).map { SplitAt(time: Time(seconds: Double($0) * 3 + 0.5)) }
        let batch = try await clock.measure { try await s.apply(splits) }

        try await s.close()
        let open = try await clock.measure {
            let r = try await EditorSession.open(at: url)
            try await r.close()
        }
        print("2,000-clip batch \(build), one command \(one), 500-command batch \(batch), open \(open)")
        #expect(one < .milliseconds(16))
        #expect(batch < .milliseconds(250))
        #expect(open < .seconds(1))
    }
}
