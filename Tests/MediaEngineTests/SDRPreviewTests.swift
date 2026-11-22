import AVFoundation
import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing

/// What the player shows: raw footage as a plain player shows the file, and
/// an HLG project in SDR exactly as its export looks, on every frame.
@Suite("Preview colour", .serialized)
struct SDRPreviewTests {
    typealias Files = SourceColourTests

    static func built(_ p: Project, preview: Bool = true) async throws -> BuiltComposition {
        try await CompositionBuilder().build(p, sdrPreview: preview)
    }

    /// A Rec.709 value as macOS shows a video file holding it, in sRGB.
    static func shown(_ v: Double) -> Double {
        let light = pow(v, 1.961)
        return light <= 0.0031308 ? 12.92 * light : 1.055 * pow(light, 1 / 2.4) - 0.055
    }

    static let raw = Files.colours + [RGB(1, 1, 1), RGB(0, 0, 0), RGB(0.063, 0.063, 0.063), RGB(0.9, 0.86, 0.8)]

    @Test(arguments: raw) func rawSDRFootageLooksAsStored(_ c: RGB) async throws {
        let b = try await Self.built(try await Files.project([try await Files.file(c, hlg: false)], in: .hlg))
        #expect(b.sdrPreview && b.videoComposition?.colorTransferFunction == AVVideoTransferFunction_ITU_R_709_2)
        for start in [0.0, 0.2] {
            let all = try await Files.frames(b, from: start)
            #expect(all.count >= 8)
            for f in all { #expect(Files.off(f.rgb, c) < 3, "at \(f.at) s wanted \(c * 255), got \(f.rgb * 255)") }
        }
    }

    /// Looks, effects and blending still happen in HLG, as in export.
    @Test(arguments: [0.0, 35.0, -35.0], [1.0, 0.5]) func previewIsTheExportAsAnHDRDisplayShowsIt(_ exposure: Double, _ opacity: Double) async throws {
        let under = try await Files.file(RGB(0.2, 0.3, 0.45), hlg: false), over = try await Files.file(RGB(0.6, 0.4, 0.3), hlg: false)
        var p = try await Files.project([under, over], in: .hlg)
        var top = p.tracks[0].clips.removeLast()
        top.start = .zero
        top.opacity = opacity
        top.effects = [EffectInstance(id: "fx", effect: "blur.gaussian", kind: .filter)]
        var look = Look(id: "look", name: "look")
        look.exposure = exposure
        p.looks = [look]
        top.look = look.id
        p.tracks.append(Track(id: "over", kind: .overlay, name: "Over", clips: [top]))
        let seen = try await Files.frames(try await Self.built(p))
        let export = try await Files.frames(try await Self.built(p, preview: false))
        #expect(seen.count == export.count && seen.count >= 14)
        for (s, e) in zip(seen, export) {
            let want = HLGConversionTests.referenceDisplay(e.rgb)
            #expect(Files.off(s.rgb, want) < 4, "at \(s.at) s wanted \(want * 255), got \(s.rgb * 255)")
        }
    }

    /// HLG footage rolls off in the preview as in an SDR project, next to SDR footage too.
    @Test(arguments: [RGB(0.5, 0.4, 0.3), RGB(0.75, 0.7, 0.65), RGB(0.9, 0.9, 0.9)]) func hlgFootage(_ c: RGB) async throws {
        let files = [try await Files.file(c, hlg: true), try await Files.file(RGB(0.4, 0.4, 0.4), hlg: false)]
        let preview = try await Files.frames(try await Self.built(try await Files.project(files, in: .hlg)))
        let sdr = try await Files.frames(try await Self.built(try await Files.project(files, in: .sdr), preview: false))
        #expect(preview.count == sdr.count)
        for (a, b) in zip(preview, sdr) { #expect(Files.off(a.rgb, b.rgb) < 3, "at \(a.at) s wanted \(b.rgb * 255), got \(a.rgb * 255)") }
    }

    @Test func itHasNoEffectOnAnSDRProject() async throws {
        let b = try await Self.built(try await Files.project([try await Files.file(RGB(0.5, 0.5, 0.5), hlg: false)], in: .sdr))
        #expect(!b.sdrPreview && !b.hdr)
    }

    /// Without the colour space on the compositor's frames shadows came out
    /// lifted: 8 showed as 20, where players and other editors show about 4.
    @Test(arguments: [8.0, 16, 32, 64, 128, 224], [DynamicRange.sdr, .hlg]) func picturesOnScreenHaveTheGammaOfVideoFiles(_ level: Double, _ range: DynamicRange) async throws {
        let v = level / 255
        let b = try await Self.built(try await Files.project([try await Files.file(RGB(v, v, v), hlg: false)], in: range))
        let image = try await FrameCapture.timelineFrame(b, at: Time(seconds: 0.2), maxWidth: nil)
        let got = ColorTools.Pixels(image).rgb(160, 120).1
        #expect(abs(got - Self.shown(v)) * 255 < 4, "\(level) shows as \(got * 255), a player shows \(Self.shown(v) * 255)")
    }

    @Test func theLaterBuiltTwinPreviewsTheSame() async throws {
        var p = try await OpenGOPTests().project()
        p.settings.dynamicRange = .hlg
        p.tracks[0].clips[0].sourceStart = Time(ticks: 29 * 8000)
        let twin = try #require(try await Self.built(p).preroll)
        #expect(twin.built.sdrPreview)
    }

    @Test func theRule() {
        var s = UserSettings.PreviewSettings()
        #expect(s.dynamicRange == .auto)
        #expect(s.showsSDR(displayHDR: false, hdrFootage: true), "no HDR on the display")
        #expect(s.showsSDR(displayHDR: true, hdrFootage: false), "raw SDR footage looks as elsewhere")
        #expect(!s.showsSDR(displayHDR: true, hdrFootage: true))
        #expect(!s.showsSDR(displayHDR: nil, hdrFootage: true))
        s.dynamicRange = .project
        #expect(!s.showsSDR(displayHDR: false, hdrFootage: false))
        s.dynamicRange = .sdr
        #expect(s.showsSDR(displayHDR: true, hdrFootage: true))
    }

    @Test func settingsFromBeforeThePreviewStillLoad() throws {
        guard case .object(var o) = try JSONValue(encoding: UserSettings.defaults()) else { return }
        o.removeValue(forKey: "preview")
        #expect(try JSONValue.object(o).decode(UserSettings.self).preview == .init())
        let store = try UserSettingsStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("dme-preview-\(UUID().uuidString)"))
        #expect(throws: (any Error).self) { try store.set(key: "preview.dynamicRange", value: .string("hdr10")) }
    }

    /// Footage, display and setting each switch the player at the same
    /// revision or the next; what tools and export get never changes.
    @Test @MainActor func thePlayerFollowsFootageDisplayAndSetting() async throws {
        let sdrURL = try await Files.file(RGB(0.5, 0.4, 0.3), hlg: false), hlgURL = try await Files.file(RGB(0.5, 0.4, 0.3), hlg: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-preview-\(UUID().uuidString)")
        let editor = Editor(settings: try UserSettingsStore(directory: dir.appendingPathComponent("home")), prober: AVMediaProber())
        let media = MediaContext(editor: editor), player = PlayerController(media: media)
        let s = try await editor.createProject(at: dir.appendingPathComponent("p.dmeproj").path, name: "p",
                                               settings: ProjectSettings(width: 320, height: 240, frameRate: .fps30, dynamicRange: .hlg))
        let main = try #require(await s.project.tracks.first { $0.kind == .main }).id
        func add(_ id: EntityID, _ url: URL, at: Double) async throws {
            let asset = MediaAsset(id: id, path: url.path, name: "src", fingerprint: UUID().uuidString, info: try await AVMediaProber().probe(url))
            try await s.apply([AddMedia(assets: [asset]),
                               AddClip(track: main, asset: id, start: Time(seconds: at), sourceStart: .zero, sourceDuration: Time(seconds: 1), id: EntityID("\(id)-clip"))])
        }
        func expect(_ want: DynamicRange, _ when: String) async throws {
            for _ in 0..<300 where player.previewRange != want { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(player.previewRange == want, "\(when)")
            let tools = try await media.composition()
            #expect(tools.hdr && !tools.sdrPreview, "tools and export left HLG: \(when)")
        }
        try await add("sdr", sdrURL, at: 0)
        player.refreshPreviewRange(displayHDR: true)
        await player.follow()
        try await expect(.sdr, "only SDR footage")
        try await add("hlg", hlgURL, at: 1)
        try await expect(.hlg, "HDR footage on an HDR display")
        player.refreshPreviewRange(displayHDR: false)
        try await expect(.sdr, "moved to a display without HDR")
        player.refreshPreviewRange(displayHDR: true)
        try await expect(.hlg, "back on the HDR display")
        try editor.settings.set(key: "preview.dynamicRange", value: .string("sdr"))
        player.refreshPreviewRange(displayHDR: true)
        try await expect(.sdr, "setting sdr")
        try editor.settings.set(key: "preview.dynamicRange", value: .string("project"))
        await player.follow()
        try await expect(.hlg, "setting project, picked up by a player tool")
        try await editor.closeProject()
    }
}
