import AVFoundation
import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing
import VideoToolbox

/// Colour through real files and the built composition, on every frame.
/// Left alone, AVFoundation converts source frames to the composition's
/// colour space, except the first frame of each decode session, under the
/// same tags (measured): a test that reads one frame, or gives the render
/// graph a buffer of its own, cannot see that.
@Suite("Colour of real files", .serialized)
struct SourceColourTests {
    /// A one-second flat HEVC 10-bit file holding `rgb` as stored R'G'B'.
    static func file(_ rgb: RGB, hlg: Bool) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dme-colour-\(UUID().uuidString).mov")
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: hlg ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: hlg ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: hlg ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        w.add(input)
        guard w.startWriting() else { throw w.error ?? EditorError.invalid("cannot write the test file") }
        w.startSession(atSourceTime: .zero)
        let kr = hlg ? 0.2627 : 0.2126, kb = hlg ? 0.0593 : 0.0722
        let y = kr * rgb.x + (1 - kr - kb) * rgb.y + kb * rgb.z
        let code = { (v: Double) in UInt16(v.rounded()) << 6 }
        let luma = code(64 + 876 * y)
        let cb = code(512 + 896 * (rgb.z - y) / (2 * (1 - kb))), cr = code(512 + 896 * (rgb.x - y) / (2 * (1 - kr)))
        let pb = LookRender.buffer(320, 240, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, hlg ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, hlg ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pb, [])
        for plane in 0..<2 {
            let n = CVPixelBufferGetBytesPerRowOfPlane(pb, plane) / 2 * CVPixelBufferGetHeightOfPlane(pb, plane)
            let p = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!.assumingMemoryBound(to: UInt16.self)
            for i in 0..<n { p[i] = plane == 0 ? luma : (i % 2 == 0 ? cb : cr) }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await w.finishWriting()
        return url
    }

    /// A project showing `files` one after another, half a second each.
    static func project(_ files: [URL], in range: DynamicRange, effects: [EffectInstance] = []) async throws -> Project {
        var p = Project(id: "p", name: "colour", settings: ProjectSettings(width: 320, height: 240, frameRate: .fps30, dynamicRange: range))
        var main = Track(id: "main", kind: .main, name: "Main")
        let each = Time(seconds: 0.5)
        for (i, url) in files.enumerated() {
            let id = EntityID("src\(i)")
            p.media.append(MediaAsset(id: id, path: url.path, name: "src", fingerprint: UUID().uuidString, info: try await AVMediaProber().probe(url)))
            var c = Clip(id: EntityID("clip\(i)"), asset: id, start: Time(ticks: each.ticks * Int64(i)), duration: each,
                         sourceStart: .zero, sourceDuration: each)
            c.effects = effects
            main.clips.append(c)
        }
        p.tracks = [main]
        return p
    }

    static func middle(_ pb: CVPixelBuffer) -> RGB {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let px = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: Float16.self)
        let i = 120 * (CVPixelBufferGetBytesPerRow(pb) / 2) + 160 * 4
        return RGB(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
    }

    /// Every frame the built composition draws from `from` on, as export reads it.
    static func frames(_ built: BuiltComposition, from: Double = 0) async throws -> [(at: Double, rgb: RGB)] {
        let r = try AVAssetReader(asset: built.composition)
        let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video),
                                                    videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
        o.videoComposition = built.videoComposition
        r.add(o)
        r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), duration: .positiveInfinity)
        r.startReading()
        var out: [(Double, RGB)] = []
        while let sample = o.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) {
            out.append((sample.presentationTimeStamp.seconds, middle(pb)))
        }
        return out
    }

    /// The frame of one file furthest from `want`, as `view` shows it, over
    /// reads that start at the first frame and part way in.
    static func worst(_ url: URL, in range: DynamicRange, want: RGB, effects: [EffectInstance] = [],
                      view: (RGB) -> RGB = { $0 }) async throws -> (off: Double, note: String) {
        let built = try await CompositionBuilder().build(try await project([url], in: range, effects: effects))
        var worst = (off: 0.0, note: "")
        for start in [0.0, 0.2] {
            let all = try await frames(built, from: start)
            #expect(all.count >= 8, "only \(all.count) frames read from \(start) s")
            for f in all where off(view(f.rgb), want) >= worst.off {
                worst = (off(view(f.rgb), want), "wanted \(want * 255), got \(view(f.rgb) * 255) at \(f.at) s")
            }
        }
        return worst
    }

    static func off(_ a: RGB, _ b: RGB) -> Double { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) * 255 }

    static let colours = [RGB(0.78, 0.55, 0.43), RGB(0.5, 0.4, 0.3), RGB(0.45, 0.2, 0.7), RGB(0.5, 0.5, 0.5)]

    @Test(arguments: colours) func sdrFileInHLGProject(_ c: RGB) async throws {
        let w = try await Self.worst(try await Self.file(c, hlg: false), in: .hlg, want: c, view: HLGConversionTests.referenceDisplay)
        #expect(w.off < 4, "\(w.note)")
    }

    /// A clip with effects is drawn on its own first; it converts the same way.
    @Test func sdrFileWithAnEffectInHLGProject() async throws {
        let c = RGB(0.5, 0.4, 0.3)
        let blur = EffectInstance(id: "fx", effect: "blur.gaussian", kind: .filter)
        let w = try await Self.worst(try await Self.file(c, hlg: false), in: .hlg, want: c, effects: [blur], view: HLGConversionTests.referenceDisplay)
        #expect(w.off < 4, "\(w.note)")
    }

    @Test func hlgFileInSDRProject() async throws {
        let c = RGB(0.5, 0.4, 0.3)
        let w = try await Self.worst(try await Self.file(c, hlg: true), in: .sdr, want: HLGConversionTests.referenceDisplay(c))
        #expect(w.off < 4, "\(w.note)")
    }

    @Test(arguments: [false, true]) func sameSpaceIsUntouched(_ hlg: Bool) async throws {
        let c = RGB(0.5, 0.4, 0.3)
        let w = try await Self.worst(try await Self.file(c, hlg: hlg), in: hlg ? DynamicRange.hlg : DynamicRange.sdr, want: c)
        #expect(w.off < 3, "\(w.note)")
    }

    /// SDR and HLG files cut together, either order, either project.
    @Test(arguments: [false, true], [DynamicRange.sdr, .hlg]) func mixedTimeline(_ hlgFirst: Bool, _ range: DynamicRange) async throws {
        let c = RGB(0.5, 0.4, 0.3)
        let kinds = [hlgFirst, !hlgFirst]
        let files = [try await Self.file(c, hlg: kinds[0]), try await Self.file(c, hlg: kinds[1])]
        let built = try await CompositionBuilder().build(try await Self.project(files, in: range))
        var wrong: [String] = []
        for f in try await Self.frames(built) {
            let hlg = kinds[f.at < 0.5 - 1e-3 ? 0 : 1], same = hlg == (range == .hlg)
            let got = (!same && range == .hlg) ? HLGConversionTests.referenceDisplay(f.rgb) : f.rgb
            let want = (!same && range == .sdr) ? HLGConversionTests.referenceDisplay(c) : c
            if Self.off(got, want) >= 4 { wrong.append("\(f.at) s: wanted \(want * 255), got \(got * 255)") }
        }
        #expect(wrong.isEmpty, "\(wrong.count) frames wrong, first \(wrong.first ?? "")")
    }

    /// A still opens a decode session for each request, and the player for each seek.
    @Test @MainActor func playerFramesMatchWhileSeekingAndPlaying() async throws {
        let c = RGB(0.5, 0.4, 0.3)
        let built = try await CompositionBuilder().build(try await Self.project([try await Self.file(c, hlg: false)], in: .hlg))
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        var seen = 0, worst = 0.0
        func take() {
            guard let pb = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) else { return }
            let d = Self.off(HLGConversionTests.referenceDisplay(Self.middle(pb)), c)
            seen += 1
            worst = max(worst, d)
        }
        for n in [0, 5, 9] {
            await player.seek(to: CMTime(value: CMTimeValue(n), timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
            try await Task.sleep(nanoseconds: 300_000_000)
            take()
        }
        await player.seek(to: .zero)
        player.play()
        for _ in 0..<25 { try await Task.sleep(nanoseconds: 20_000_000); take() }
        player.pause()
        #expect(seen >= 5, "only \(seen) pictures came from the player")
        #expect(worst < 4, "worst \(worst) levels")
    }

    @Test func stillsMatchTheSource() async throws {
        let c = RGB(0.5, 0.4, 0.3)
        let built = try await CompositionBuilder().build(try await Self.project([try await Self.file(c, hlg: true)], in: .sdr))
        let want = HLGConversionTests.referenceDisplay(c)
        let g = AVAssetImageGenerator(asset: built.composition)
        g.videoComposition = built.videoComposition
        for n in [0, 4, 9] {
            let image = try await g.image(at: CMTime(value: CMTimeValue(n), timescale: 30)).image
            let space = try #require(image.colorSpace)
            var px = [UInt8](repeating: 0, count: 320 * 240 * 4)
            let ctx = try #require(CGContext(data: &px, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 1280,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 240))
            let i = 120 * 1280 + 160 * 4
            let got = RGB(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255
            #expect(Self.off(got, want) < 4, "frame \(n): wanted \(want * 255), got \(got * 255)")
        }
    }

    /// Two projects opened one after the other, at the same revision, differ
    /// in dynamic range: each gets its own composition, not the last one's.
    @Test func switchingProjectsNeverKeepsTheLastComposition() async throws {
        let url = try await Self.file(RGB(0.5, 0.5, 0.5), hlg: false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let editor = Editor(settings: try UserSettingsStore(directory: dir.appendingPathComponent("home")), prober: AVMediaProber())
        let media = MediaContext(editor: editor)
        let asset = MediaAsset(id: "src", path: url.path, name: "src", fingerprint: "f", info: try await AVMediaProber().probe(url))
        var stale = 0
        for i in 0..<40 {
            let range: DynamicRange = i % 2 == 0 ? .sdr : .hlg
            let s = try await editor.createProject(at: dir.appendingPathComponent("\(i).dmeproj").path, name: "\(i)",
                                                   settings: ProjectSettings(width: 320, height: 240, frameRate: .fps30, dynamicRange: range))
            let main = try #require(await s.project.tracks.first { $0.kind == .main }).id
            try await s.apply([AddMedia(assets: [asset]),
                               AddClip(track: main, asset: "src", start: .zero, sourceStart: .zero, sourceDuration: Time(seconds: 1), id: "a")])
            if try await media.composition().hdr != (range == .hlg) { stale += 1 }
            try await editor.closeProject()
        }
        #expect(stale == 0, "\(stale) of 40 switches kept the last project's composition")
    }
}
