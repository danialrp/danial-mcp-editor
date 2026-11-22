import Testing
@testable import EditorCore

/// A level track: speech at -10 dB, silence at -60 dB, per 10 ms.
func levels(_ parts: [(Double, Float)]) -> [Float] {
    parts.flatMap { (seconds, db) in [Float](repeating: db, count: Int((seconds * 100).rounded())) }
}

@Suite struct SilenceTests {
    let r = SilenceRules()

    @Test func padsAPauseAndKeepsTheEnding() {
        // speech 2 s, pause 1 s, speech 2 s, silence 3 s at the end
        let db = levels([(2, -10), (1, -60), (2, -10), (3, -60)])
        let p = SilenceFinder.pauses(levelsDB: db, hop: 0.01, rules: r)
        #expect(p.count == 1)   // the silence after the last word is never cut
        #expect(abs(p[0].cutFrom - 2.35) < 0.011)
        #expect(abs(p[0].cutTo - 2.90) < 0.011)
    }

    @Test func shortPausesAndClicksAreLeftAlone() {
        let db = levels([(2, -10), (0.2, -60), (2, -10), (0.3, -60), (0.04, -10), (0.3, -60), (2, -10), (1, -60)])
        let p = SilenceFinder.pauses(levelsDB: db, hop: 0.01, rules: r)
        // 0.2 s is under minPause; the 0.04 s click joins the two 0.3 s silences into one pause
        #expect(p.count == 1)
        #expect(abs(p[0].start - 4.2) < 0.011)
    }

    @Test func quietWordEndingsBelongToTheWord() {
        // speech, then a soft verb ending 25 dB down for 0.2 s, then silence
        let db = levels([(2, -10), (0.2, -35), (1, -70), (2, -10), (1, -70)])
        let p = SilenceFinder.pauses(levelsDB: db, hop: 0.01, rules: r)
        #expect(p.count == 1)
        #expect(abs(p[0].cutFrom - (2.2 + 0.35)) < 0.011)   // padding counts from the end of the soft tail
    }

    @Test func cutsLandOnFramesInsideClipsWithSpeed() {
        var p = makeProject()
        try! run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(9), speed: 1.22, id: "a"))
        let db = levels([(2, -10), (1, -60), (2, -10), (1, -60), (2, -10), (1, -60)])
        let cuts = SilenceFinder.cuts(track: p.tracks[0], envelopes: ["cam": db], hop: 0.01, rules: r, frameRate: .fps60)
        #expect(cuts.count == 2)
        for c in cuts {
            #expect(c.start.ticks % FrameRate.fps60.frameDuration.ticks == 0)
            #expect(c.end > c.start)
            #expect(c.sourceStart.seconds >= 2.35 - 0.02)
        }
    }

    @Test func transcriptWordsFollowCuts() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        p.transcripts = [Transcript(id: "t", asset: "cam", language: "en", engine: "test", sourceStart: .zero, sourceEnd: s(10),
                                    words: [TranscriptWord(text: "one", start: s(1), end: s(1.5)),
                                            TranscriptWord(text: "two", start: s(4), end: s(4.5)),
                                            TranscriptWord(text: "three", start: s(8), end: s(8.5))])]
        try run(&p, DeleteRange(start: s(3), end: s(5)))     // cuts out "two"
        try run(&p, SetClipSpeed(ids: p.tracks[0].clips.map(\.id), speed: 2))
        let w = p.timelineWords(p.transcripts[0])
        #expect(w.map(\.word.text) == ["one", "three"])
        #expect(w[0].start == s(0.5))
        #expect(w[1].start == s(1.5 + 1.5))   // first clip is 1.5 s long at speed 2; "three" is 3 s into the second
    }
}
