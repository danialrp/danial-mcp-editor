import Foundation
import Testing
@testable import EditorCore

private func fx(_ id: String, _ kind: EffectKind, _ d: Double? = nil) -> EffectInstance {
    EffectInstance(id: EntityID(id), effect: "e.\(kind.rawValue)", kind: kind, params: ["radius": 10], duration: d.map(s))
}

@Suite struct EffectTests {
    @Test func keyframeValues() {
        let ks = [Keyframe(time: s(1), value: 1, easing: .linear), Keyframe(time: s(3), value: 2, easing: .ease),
                  Keyframe(time: s(5), value: 4, easing: .hold), Keyframe(time: s(6), value: 0)]
        #expect(Keyframe.value(ks, at: s(0)) == 1, "before the first: first value")
        #expect(Keyframe.value(ks, at: s(2)) == 1.5, "linear halfway")
        #expect(Keyframe.value(ks, at: s(4)) == 3, "ease is symmetric at the middle")
        #expect(Keyframe.value(ks, at: s(3.5))! < 2.5, "ease starts slow")
        #expect(Keyframe.value(ks, at: s(5.9)) == 4, "hold keeps its value")
        #expect(Keyframe.value(ks, at: s(9)) == 0, "after the last: last value")
        #expect(Keyframe.value([], at: s(1)) == nil)
    }

    @Test func keyframesFollowThePictureThroughTrimAndSpeed() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceStart: s(10), sourceDuration: s(10), id: "a"))
        // zoom from 1 at timeline 2 s to 2 at timeline 4 s
        try run(&p, SetKeyframes(clip: "a", property: .scale, keyframes: [Keyframe(time: s(2), value: 1, easing: .linear),
                                                                          Keyframe(time: s(4), value: 2, easing: .linear)]))
        #expect(p.tracks[0].clips[0].keyframes["scale"]!.map(\.time) == [s(12), s(14)], "stored in source time")
        #expect(p.tracks[0].clips[0].animated(at: s(3)).transform.scale == 1.5)
        // Trimming the start by 1 s moves the picture 1 s earlier on the timeline; the zoom moves with it.
        try run(&p, TrimClip(id: "a", edge: .start, time: s(1)))
        try run(&p, MoveClip(id: "a", start: s(0)))
        #expect(p.tracks[0].clips[0].animated(at: s(2)).transform.scale == 1.5)
        // At double speed the same picture comes twice as early.
        try run(&p, SetClipSpeed(ids: ["a"], speed: 2))
        #expect(p.tracks[0].clips[0].animated(at: s(1)).transform.scale == 1.5)
        #expect(p.tracks[0].clips[0].animated(at: s(0)).transform.x == 0.5, "other properties untouched")
    }

    @Test func keyframesRefuseBadInput() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        #expect(throws: EditorError.self) { try run(&p, SetKeyframes(clip: "a", property: .scale, keyframes: [Keyframe(time: s(11), value: 1)])) }
        #expect(throws: EditorError.self) { try run(&p, SetKeyframes(clip: "a", property: .scale, keyframes: [Keyframe(time: s(1), value: 0)])) }
        #expect(throws: EditorError.self) { try run(&p, SetKeyframes(clip: "a", property: .opacity, keyframes: [Keyframe(time: s(1), value: 2)])) }
        #expect(throws: EditorError.self) {
            try run(&p, SetKeyframes(clip: "a", property: .x, keyframes: [Keyframe(time: s(1), value: 0), Keyframe(time: s(1), value: 1)]))
        }
    }

    @Test func removeKeyframesInARange() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        try run(&p, SetKeyframes(clip: "a", property: .x, keyframes: [1, 2, 3, 4].map { Keyframe(time: s($0), value: $0) }))
        try run(&p, SetKeyframes(clip: "a", property: .y, keyframes: [Keyframe(time: s(2), value: 0.4)]))
        try run(&p, RemoveKeyframes(clip: "a", property: .x, from: s(2), to: s(3)))
        #expect(p.tracks[0].clips[0].keyframes["x"]!.map(\.value) == [1, 4])
        #expect(p.tracks[0].clips[0].keyframes["y"] != nil)
        try run(&p, RemoveKeyframes(clip: "a"))
        #expect(p.tracks[0].clips[0].keyframes.isEmpty)
    }

    @Test func progressOfEachKind() {
        let len = s(10)
        #expect(fx("f", .filter).progress(at: s(5), clipDuration: len) == 0.5)
        let i = fx("i", .in, 2)
        #expect(i.progress(at: s(0), clipDuration: len) == 0)
        #expect(i.progress(at: s(1), clipDuration: len) == 0.5)
        #expect(i.progress(at: s(2), clipDuration: len) == nil, "done after its duration")
        let o = fx("o", .out, 2)
        #expect(o.progress(at: s(7.9), clipDuration: len) == nil, "not yet")
        #expect(o.progress(at: s(9), clipDuration: len) == 0.5)
        #expect(fx("o", .out, 20).progress(at: s(5), clipDuration: len) == 0.5, "longer than the clip: spread over the clip")
    }

    @Test func splitKeepsIntroAtStartAndOutroAtEnd() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        for e in [fx("fx_in", .in, 1), fx("fx_blur", .filter), fx("fx_out", .out, 1)] { try run(&p, PutEffect(clip: "a", instance: e)) }
        try run(&p, SplitAt(time: s(4)))
        let (l, r) = (p.tracks[0].clips[0], p.tracks[0].clips[1])
        #expect(l.effects.map(\.kind) == [.in, .filter])
        #expect(r.effects.map(\.kind) == [.filter, .out])
        #expect(l.effects[1].id != r.effects[0].id, "the copy gets its own id")
        #expect(r.effects[0].params == l.effects[1].params)
    }

    @Test func putRemoveReorder() throws {
        var p = makeProject()
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(10), id: "a"))
        try run(&p, PutEffect(clip: "a", instance: fx("fx_1", .filter)))
        try run(&p, PutEffect(clip: "a", instance: fx("fx_2", .filter)))
        try run(&p, PutEffect(clip: "a", instance: fx("fx_0", .filter), index: 0))
        #expect(p.tracks[0].clips[0].effects.map(\.id.raw) == ["fx_0", "fx_1", "fx_2"])
        var changed = fx("fx_1", .filter)
        changed.params["radius"] = 50
        try run(&p, PutEffect(clip: "a", instance: changed))
        #expect(p.tracks[0].clips[0].effects[1].params["radius"] == 50, "same id replaces in place")
        try run(&p, ReorderEffect(clip: "a", effect: "fx_2", index: 0))
        #expect(p.tracks[0].clips[0].effects.map(\.id.raw) == ["fx_2", "fx_0", "fx_1"])
        try run(&p, RemoveEffect(clip: "a", effect: "fx_0"))
        #expect(p.tracks[0].clips[0].effects.map(\.id.raw) == ["fx_2", "fx_1"])
        #expect(throws: EditorError.self) { try run(&p, PutEffect(clip: "a", instance: fx("main", .filter))) }   // id in use
        #expect(throws: EditorError.self) { try run(&p, PutEffect(clip: "a", instance: fx("fx_9", .in))) }      // no duration
    }

    @Test func manifestChecksParameters() throws {
        let json = """
        {"id": "t.blur", "kind": "filter", "passes": ["a"], "parameters": [
          {"name": "radius", "type": "number", "min": 0, "max": 100, "default": 20},
          {"name": "soft", "type": "boolean"},
          {"name": "mode", "type": "choice", "choices": ["x", "y"], "default": 1}]}
        """
        let m = try JSONDecoder().decode(EffectManifest.self, from: Data(json.utf8))
        #expect(m.problems().isEmpty)
        #expect(try m.resolve([:]) == ["radius": 20, "soft": 0, "mode": 1])
        #expect(try m.resolve(["radius": 5], over: ["radius": 9, "mode": 0]) == ["radius": 5, "soft": 0, "mode": 0])
        #expect(throws: EditorError.self) { try m.resolve(["radius": 101]) }
        #expect(throws: EditorError.self) { try m.resolve(["mode": 2]) }
        #expect(throws: EditorError.self) { try m.resolve(["soft": 0.5]) }
        #expect(throws: EditorError.self) { try m.resolve(["size": 1]) }
        #expect(throws: EditorError.self) { try m.checkDuration(1) }
        let bad = try JSONDecoder().decode(EffectManifest.self, from: Data(#"{"id": "Bad Id", "kind": "in", "passes": []}"#.utf8))
        #expect(bad.problems().count == 3)
    }

    @Test func clipsWithoutEffectsDecodeFromOlderFiles() throws {
        let json = #"{"id": "a", "asset": "cam", "start": 0, "duration": 1, "sourceStart": 0, "sourceDuration": 1}"#
        let c = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(c.effects.isEmpty && c.keyframes.isEmpty)
    }
}
