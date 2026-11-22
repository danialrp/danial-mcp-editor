import AVFoundation
import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing
import CoreGraphics
import ImageIO

/// The HTML slicing itself: pure string work, always tested.
@Suite struct HFDocumentTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/hf")

    @Test func readsRootAndHosts() throws {
        let html = try String(contentsOf: Self.fixture.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(HFDocument.root(html) == .init(id: "main", width: 360, height: 640, fps: 30, duration: 4))
        let hosts = HFDocument.hosts(html)
        #expect(hosts.map(\.src) == ["compositions/a.html", "compositions/b.html"])
        #expect(hosts.map(\.start) == [0, 2] && hosts.map(\.end) == [2.5, 4])
    }

    @Test func shiftsTimedElementsAndWrapsTimelines() throws {
        let html = try String(contentsOf: Self.fixture.appendingPathComponent("index.html"), encoding: .utf8)
        let s = HFDocument.shifted(html, offset: 2, duration: 2)
        #expect(HFDocument.root(s)?.duration == 2)
        let hosts = HFDocument.hosts(s)
        // a (0-2.5) is cut to its last half second; b (2-4) now starts at 0.
        #expect(hosts[0].start == 0 && hosts[0].duration == 0.5)
        #expect(hosts[1].start == 0 && hosts[1].duration == 2)
        #expect(s.contains("m.fromTo(tl, { time: 2.000000 }, { time: 4.000000, duration: 2.000000"))
        #expect(!s.contains("window.__timelines[\"main\"] = tl;"))
        // Outside the slice: moved past its end.
        let first = HFDocument.hosts(HFDocument.shifted(html, offset: 0, duration: 2))
        #expect(first[1].start == 3 && first[1].duration == 0.001)
    }

    @Test func subCompositionsShiftByTheirOwnOffset() throws {
        let sub = try String(contentsOf: Self.fixture.appendingPathComponent("compositions/a.html"), encoding: .utf8)
        // Slice 2-4 shows a from its second 2 on, at slice time 0, for 0.5 s.
        let s = HFDocument.shifted(sub, offset: 2, duration: 0.5, rootStart: 0)
        #expect(HFDocument.root(s)?.id == "a" && HFDocument.root(s)?.duration == 0.5)
        #expect(s.contains("window.__timelines[\"a\"] = (function () {"))
        #expect(s.contains("{ time: 2.000000 }, { time: 2.500000"))
    }
}

/// Renders through the real HyperFrames command line. Runs only when
/// DME_HF_COMMAND holds the command as a JSON array, for example
/// ["/path/to/hf.sh"] or ["npx", "--yes", "hyperframes"].
@Suite("HyperFrames rendering", .serialized, .enabled(if: ProcessInfo.processInfo.environment["DME_HF_COMMAND"] != nil))
struct HyperFramesRenderTests {
    let host: HyperFramesHost
    let folder: URL
    let project = EntityID("project_hftest_\(UUID().uuidString.prefix(8))")

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dme-hf-\(UUID().uuidString)")
        folder = tmp.appendingPathComponent("comp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: HFDocumentTests.fixture, to: folder)
        let store = try UserSettingsStore(directory: tmp.appendingPathComponent("home"))
        let cmd = try JSONDecoder().decode([String].self, from: Data(ProcessInfo.processInfo.environment["DME_HF_COMMAND"]!.utf8))
        try store.update {
            $0.hyperframes.command = cmd
            $0.hyperframes.sliceSeconds = 2
            $0.hyperframes.parallelSlices = 2
            $0.hyperframes.quality = "draft"
        }
        host = HyperFramesHost(settings: store)
    }

    var composition: HyperFramesHost.Composition {
        get throws {
            let a = MediaAsset(id: "hf_test", path: "comp", name: "comp", fingerprint: "", info: MediaInfo(duration: Time(seconds: 4), video: nil, audio: nil), kind: .hyperframes)
            return try HyperFramesHost.composition(a, package: folder.deletingLastPathComponent())
        }
    }

    /// RGBA of the middle pixel of a few spots, at `t` seconds of a file.
    func frame(_ url: URL, at t: Double) async throws -> CGImage {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        return try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let pa = ColorTools.Pixels(a), pb = ColorTools.Pixels(b)
        var sum = 0.0
        for i in 0..<min(pa.data.count, pb.data.count) { sum += abs(Double(pa.data[i]) - Double(pb.data[i])) }
        return sum / Double(pa.data.count)
    }

    @Test func slicesMatchAWholeRenderAndAFixRendersOnlyItsSlice() async throws {
        let c = try composition
        // Reference: the whole composition rendered in one go.
        let whole = folder.deletingLastPathComponent().appendingPathComponent("whole.mov")
        let cmd = try JSONDecoder().decode([String].self, from: Data(ProcessInfo.processInfo.environment["DME_HF_COMMAND"]!.utf8))
        let r = try await HyperFramesHost.run(cmd + ["render", folder.path, "--format", "mov", "--fps", "30", "-q", "draft", "--quiet", "-o", whole.path],
                                              env: ["HYPERFRAMES_SKIP_SKILLS": "1", "HYPERFRAMES_NO_TELEMETRY": "1", "DO_NOT_TRACK": "1"], timeout: 900)
        #expect(r.status == 0, "\(r.output.suffix(500))")

        let rendered = try await host.render(c, project: project) { _, _, _ in }
        #expect(rendered == [0, 1])
        let slices = try await host.slices(c, project: project)
        #expect(slices.count == 2 && slices.allSatisfy { $0.current != nil })
        for t in [0.5, 1.9, 2.1, 2.4, 3.5] {
            let s = slices[t < 2 ? 0 : 1]
            let d = meanDifference(try await frame(whole, at: t), try await frame(s.current!, at: t - s.start))
            #expect(d < 3, "frame at \(t) s differs from the whole render by \(d) on average")
        }

        // Fix one part: b only shows in the second slice.
        let b = folder.appendingPathComponent("compositions/b.html")
        try (try String(contentsOf: b, encoding: .utf8)).replacingOccurrences(of: "#7878FF", with: "#FFB000").write(to: b, atomically: true, encoding: .utf8)
        let after = try await host.slices(c, project: project)
        #expect(after[0].current != nil, "the first slice does not show b and stays current")
        #expect(after[1].current == nil && after[1].stale != nil, "the second slice is stale; its old render still plays")
        let again = try await host.render(c, project: project) { _, _, _ in }
        #expect(again == [1], "only the slice showing the fixed part renders again")
    }
}

/// A depth composition (phase 8): the page is read as two passes and its
/// EDGE windows, the footage preview is left out.
@Suite struct HFDepthDocumentTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/hf-depth/index.html")

    @Test func readsPassesEdgesAndDropsTheFootagePreview() throws {
        let html = try String(contentsOf: Self.fixture, encoding: .utf8)
        #expect(HFDocument.isDepth(html))
        #expect(!HFDocument.isDepth(try String(contentsOf: HFDocumentTests.fixture.appendingPathComponent("index.html"), encoding: .utf8)))
        #expect(HFDocument.edges(html) == [1...2])
        #expect(HFDocument.forPass(html, "back").contains(#"<html lang="en" class="pass-back">"#))
        #expect(HFDocument.forPass(#"<html class="x">"#, "front") == #"<html class="pass-front x">"#)
        let clean = HFDocument.withoutFootagePreview(html)
        #expect(!clean.contains("footage.mp4") && clean.contains(#"id="back""#))
    }
}

/// A depth composition rendered by HyperFrames and drawn over footage with
/// a person matte: behind him the back pass is cut, in the EDGE window his
/// outline is lit, the front pass covers all. Runs with DME_HF_COMMAND.
@Suite("HyperFrames depth rendering", .serialized, .enabled(if: ProcessInfo.processInfo.environment["DME_HF_COMMAND"] != nil))
struct HyperFramesDepthTests {
    @Test func backGoesBehindThePersonAndTheEdgeLightsInItsWindow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-hfd-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("p.dme")
        let folder = package.appendingPathComponent("hyperframes/depth")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: HFDepthDocumentTests.fixture, to: folder.appendingPathComponent("index.html"))
        let settings = try UserSettingsStore(directory: dir.appendingPathComponent("home"))
        let cmd = try JSONDecoder().decode([String].self, from: Data(ProcessInfo.processInfo.environment["DME_HF_COMMAND"]!.utf8))
        try settings.update {
            $0.hyperframes.command = cmd
            $0.hyperframes.quality = "draft"
            $0.matte.edge.referenceWidth = 320
            $0.matte.edge.profileFullTo = 1
        }
        // Footage with a disc-shaped person in the middle (imported masks).
        var p = try await OpenGOPTests().project()
        p.tracks[0].clips = [Clip(id: "a", asset: "src", start: .zero, duration: Time(seconds: 3), sourceStart: .zero, sourceDuration: Time(seconds: 3))]
        p.media[0].matte = .imported
        p.media[0].fingerprint = "fixture-\(UUID().uuidString)"
        let masks = MatteStore.importFolder(package: package, asset: "src")
        try FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
        for ms in [0, 1000, 2000, 3000, 4000] {
            let ctx = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: 100, y: 60, width: 120, height: 120))
            let d = CGImageDestinationCreateWithURL(masks.appendingPathComponent("\(ms).png") as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(d)
        }
        p.media.append(MediaAsset(id: "hf", path: "hyperframes/depth", name: "depth", fingerprint: "",
                                  info: MediaInfo(duration: Time(seconds: 3), video: VideoInfo(width: 320, height: 240, frameRate: 30, codec: "hyperframes"), audio: nil),
                                  kind: .hyperframes))
        var gfx = Track(id: "gfx", kind: .overlay, name: "Graphics")
        gfx.clips = [Clip(id: "g", asset: "hf", start: .zero, duration: Time(seconds: 3), sourceStart: .zero, sourceDuration: Time(seconds: 3))]
        p.tracks.append(gfx)

        let host = HyperFramesHost(settings: settings)
        let comp = try HyperFramesHost.composition(p.media[1], package: package)
        #expect(comp.depth && comp.edges == [1...2])
        _ = try await host.render(comp, project: p.id) { _, _, _ in }
        let store = MatteStore(settings: settings)
        _ = try await store.generate(p.media[0], package: package, only: [0]) { _, _, _ in }
        let built = try await CompositionBuilder().build(p, package: package, hyperframes: host, mattes: store, matteSettings: settings.current.matte)
        let g = AVAssetImageGenerator(asset: built.composition)
        g.videoComposition = built.videoComposition
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        func pixels(_ t: Double) async throws -> ColorTools.Pixels { ColorTools.Pixels(try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image) }
        func rgb(_ px: ColorTools.Pixels, _ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * px.width + x) * 4
            return (Int(px.data[i]), Int(px.data[i + 1]), Int(px.data[i + 2]))
        }
        for (t, lit) in [(0.5, false), (1.5, true)] {
            let px = try await pixels(t)
            let mid = rgb(px, 160, 120), far = rgb(px, 300, 220), corner = rgb(px, 10, 10), band = rgb(px, 226, 120)
            #expect(abs(mid.0 - mid.1) < 25 && abs(mid.1 - mid.2) < 25, "at \(t) s the person (grey footage) shows: \(mid)")
            #expect(far.0 > 200 && far.1 < 60 && far.2 < 60, "at \(t) s the back pass shows away from him: \(far)")
            #expect(corner.2 > 200 && corner.0 < 60, "at \(t) s the front pass covers: \(corner)")
            if lit { #expect(band.0 > 220 && band.1 > 220 && band.2 > 220, "in the EDGE window his outline is lit: \(band)") }
            else { #expect(band.0 > 200 && band.1 < 60, "outside the window the band shows the back pass: \(band)") }
        }
    }
}
