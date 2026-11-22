import AVFoundation
import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing

/// The two ways to view SDR: `video`, as plain players and CapCut show a
/// file, and `edits`, as the Edits app shows it in an SDR project.
@Suite("Preview gamma", .serialized)
struct PreviewGammaTests {
    typealias Files = SourceColourTests

    /// A Rec.709 value read with the camera curve of BT.709, in sRGB.
    static func camera(_ v: Double) -> Double {
        let light = v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45)
        return light <= 0.0031308 ? 12.92 * light : 1.055 * pow(light, 1 / 2.4) - 0.055
    }

    /// What the Edits window showed for these greys in an SDR project
    /// (measured on screen).
    static let editsShows: [(level: Double, shown: Double)] = [(8, 20), (16, 31), (32, 48), (64, 79), (128, 141), (224, 228)]

    struct Rig {
        let editor: Editor
        let media: MediaContext
        let player: PlayerController
    }

    @MainActor static func rig(_ url: URL, _ range: DynamicRange, sourceFrom: Int = 0) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-gamma-\(UUID().uuidString)")
        let editor = Editor(settings: try UserSettingsStore(directory: dir.appendingPathComponent("home")), prober: AVMediaProber())
        let s = try await editor.createProject(at: dir.appendingPathComponent("p.dmeproj").path, name: "p",
                                               settings: ProjectSettings(width: 320, height: 240, frameRate: .fps30, dynamicRange: range))
        let main = try #require(await s.project.tracks.first { $0.kind == .main }).id
        try await s.apply([AddMedia(assets: [MediaAsset(id: "src", path: url.path, name: "src", fingerprint: UUID().uuidString, info: try await AVMediaProber().probe(url))]),
                           AddClip(track: main, asset: "src", start: .zero, sourceStart: Time(ticks: Int64(sourceFrom) * 8000), sourceDuration: Time(ticks: 15 * 8000), id: "a")])
        let media = MediaContext(editor: editor)
        let player = PlayerController(media: media)
        await player.follow()
        return Rig(editor: editor, media: media, player: player)
    }

    static func grey(_ built: BuiltComposition, frame: Int = 6) async throws -> Double {
        ColorTools.Pixels(try await FrameCapture.timelineFrame(built, at: Time(ticks: Int64(frame) * 8000), maxWidth: nil)).rgb(160, 120).1
    }

    @Test(arguments: editsShows.map(\.level), [DynamicRange.sdr, .hlg]) @MainActor func editsGammaMatchesEdits(_ level: Double, _ range: DynamicRange) async throws {
        let v = level / 255, want = try #require(Self.editsShows.first { $0.level == level }).shown
        let r = try await Self.rig(try await Files.file(RGB(v, v, v), hlg: false), range)
        let revision = r.player.revision
        let before = try await Self.grey(try #require(r.player.built))
        #expect(abs(before - SDRPreviewTests.shown(v)) * 255 < 4, "the default is the video gamma")

        try r.editor.settings.set(key: "preview.gamma", value: .string("edits"))
        await r.player.follow()
        #expect(r.player.revision == revision, "a setting is not an edit")
        let after = try await Self.grey(try #require(r.player.built))
        #expect(abs(after * 255 - want) < 4, "\(level) shows as \(after * 255), Edits shows \(want)")

        let project = await (try await r.editor.requireSession()).project
        for (who, built) in [("tools", try await r.media.composition()), ("export", try await r.media.composition(for: project))] {
            #expect(built.hdr == (range == .hlg) && !built.sdrPreview, "\(who) keep the project's range")
            if range == .sdr {
                let kept = try await Self.grey(built)
                #expect(abs(kept - SDRPreviewTests.shown(v)) * 255 < 4, "\(who) keep the video gamma")
            }
        }

        try r.editor.settings.set(key: "preview.gamma", value: .string("video"))
        await r.player.follow()
        let back = try await Self.grey(try #require(r.player.built))
        #expect(abs(back - before) * 255 < 1, "and back")
        try await r.editor.closeProject()
    }

    /// The exact still drawn over the player on a leading frame of open-GOP
    /// video comes from another reading path: it takes the same gamma.
    @Test @MainActor func stillsOnLeadingFramesTakeTheGammaToo() async throws {
        let r = try await Self.rig(OpenGOPTests.fixture, .sdr, sourceFrom: 29)
        var video: [Double] = []
        for n in 0..<5 { video.append(try await Self.grey(try #require(r.player.built), frame: n)) }
        try r.editor.settings.set(key: "preview.gamma", value: .string("edits"))
        await r.player.follow()
        for n in 0..<5 {
            let light = video[n] <= 0.04045 ? video[n] / 12.92 : pow((video[n] + 0.055) / 1.055, 2.4)
            let want = Self.camera(pow(light, 1 / 1.961)), got = try await Self.grey(try #require(r.player.built), frame: n)
            #expect(abs(got - want) * 255 < 4, "frame \(n): \(got * 255), wanted \(want * 255)")
        }
        try await r.editor.closeProject()
    }

    /// A raw frame alone has no reason to pass through HLG and back, which
    /// in half float lifts the empty channels of pure colours; the camera
    /// curve then shows that several times larger.
    @Test(arguments: [RGB(1, 0, 0), RGB(0, 1, 0), RGB(0, 0, 1), RGB(1, 1, 0)]) func pureColoursStayPure(_ c: RGB) async throws {
        let url = try await Files.file(c, hlg: false)
        let sdr = try await Files.frames(try await CompositionBuilder().build(try await Files.project([url], in: .sdr)))
        let seen = try await Files.frames(try await CompositionBuilder().build(try await Files.project([url], in: .hlg), sdrPreview: true))
        #expect(seen.count == sdr.count)
        func clipped(_ p: RGB) -> RGB { RGB(min(max(p.x, 0), 1), min(max(p.y, 0), 1), min(max(p.z, 0), 1)) }
        for (a, b) in zip(seen, sdr) { #expect(Files.off(clipped(a.rgb), clipped(b.rgb)) < 1, "wanted \(b.rgb * 255), got \(a.rgb * 255)") }
    }

    /// A graded frame drawn straight in SDR is still the export as an HDR display shows it.
    @Test(arguments: ["exposure", "contrast", "saturation", "temperature"], [60.0, -60.0]) func gradedAloneIsStillTheExport(_ slider: String, _ value: Double) async throws {
        var p = try await Files.project([try await Files.file(RGB(0.6, 0.4, 0.3), hlg: false)], in: .hlg)
        var look = Look(id: "look", name: "look")
        look[slider: slider] = value
        p.looks = [look]
        p.tracks[0].clips[0].look = look.id
        let seen = try await Files.frames(try await CompositionBuilder().build(p, sdrPreview: true))
        let export = try await Files.frames(try await CompositionBuilder().build(p))
        #expect(seen.count == export.count && seen.count >= 14)
        for (s, e) in zip(seen, export) {
            let want = HLGConversionTests.referenceDisplay(e.rgb)
            #expect(Files.off(RGB(min(max(s.rgb.x, 0), 1), min(max(s.rgb.y, 0), 1), min(max(s.rgb.z, 0), 1)), want) < 4, "wanted \(want * 255), got \(s.rgb * 255)")
        }
    }
}
