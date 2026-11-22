import Foundation
import Testing
@testable import EditorCore

@Suite struct LookTests {
    @Test func createUpdateAssignAndScope() throws {
        var p = makeProject()
        p.tracks.insert(Track(id: "gfx", kind: .overlay, name: "Graphics"), at: 1)
        try run(&p, AddClip(track: "main", asset: "cam", sourceDuration: s(5), id: "a"))
        try run(&p, AddClip(track: "gfx", asset: "cam", sourceDuration: s(5), id: "g"))
        var c = CreateLook(name: "Base", id: "base")
        c.exposure = 15
        c.vignette = 80
        try run(&p, c)
        try run(&p, AssignLook(look: "base", tracks: ["main"]))
        // The camera clip gets the look through its track; the graphics clip does not.
        #expect(p.effectiveLook(p.tracks[0].clips[0], on: p.tracks[0])?.exposure == 15)
        #expect(p.effectiveLook(p.tracks[1].clips[0], on: p.tracks[1]) == nil)
        var u = UpdateLook(id: "base")
        u.hsl = ["orange": PartialHSL(hue: nil, saturation: -10, luminance: 5)]
        try run(&p, u)
        #expect(p.looks[0].band(.orange) == HSLAdjust(hue: 0, saturation: -10, luminance: 5))
        try run(&p, RemoveLook(id: "base"))
        #expect(p.tracks[0].look == nil)
    }

    @Test func rangesAreChecked() throws {
        var p = makeProject()
        var c = CreateLook(id: "l")
        c.vignette = -5
        #expect(throws: EditorError.self) { try run(&p, c) }
        try run(&p, CreateLook(id: "l"))
        var pick = AddPickedColor(look: "l", color: "#C08670")
        pick.range = 200
        #expect(throws: EditorError.self) { try run(&p, pick) }
        #expect(throws: EditorError.self) { try run(&p, AddPickedColor(look: "l", color: "skin")) }
        try run(&p, AddPickedColor(look: "l", color: "#C08670"))
        #expect(p.looks[0].picked.count == 1)
    }

    @Test func aLookSurvivesJSONExactly() throws {
        var l = Look(id: "x", name: "Saved")
        l.exposure = 15; l.clarity = 9; l.highlights = -9; l.vignette = 80
        l.hsl["red"] = HSLAdjust(hue: 3, saturation: -20, luminance: 4)
        l.picked = [PickedColor(id: "c", color: "#C08670", range: 20, adjust: HSLAdjust(saturation: -40))]
        let back = try JSONDecoder().decode(Look.self, from: JSONEncoder().encode(l))
        #expect(back == l)
    }
}
