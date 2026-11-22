import AVFoundation
import CoreGraphics
import EditorCore
import Foundation
import ImageIO
@testable import MediaEngine
import Testing
import UniformTypeIdentifiers

/// Still pictures in the media pool and on the timeline: any length, upright,
/// transparency kept, drawn by the same compositor as video.
@Suite("Still pictures", .serialized)
struct StillTests {
    /// A 200x200 PNG: opaque pure red, with a fully transparent hole in the middle.
    static func png() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dme-still-\(UUID().uuidString).png")
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.clear(CGRect(x: 75, y: 75, width: 50, height: 50))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func aPictureIsAnEndlessSourceDrawnWithItsTransparency() async throws {
        let url = try Self.png()
        defer { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        let info = try await AVMediaProber().probe(url)
        #expect(info.video?.width == 200 && info.video?.codec == "image/png" && info.audio == nil)
        #expect(info.duration == MediaAsset.stillDuration)
        var p = try await OpenGOPTests().project()
        p.media.append(MediaAsset(id: "pic", path: url.path, name: "pic.png", fingerprint: "pic", info: info, kind: .image))
        var over = Track(id: "over", kind: .overlay, name: "Over")
        var add = AddClip(track: "over", asset: "pic", start: Time.zero)
        p.tracks.append(over)
        try add.prepare(in: p)
        try add.apply(to: &p)
        over = p.tracks[1]
        #expect(over.clips.first?.duration.seconds == MediaAsset.stillDefaultSeconds, "placed without a length: the default")
        // Scale the picture to the whole 320x240 frame's height: 240x240 in the middle.
        p.tracks[1].clips[0].transform.fit = .fit
        let built = try await CompositionBuilder().build(p)
        let img = ColorTools.Pixels(try await FrameCapture.timelineFrame(built, at: OpenGOPTests().f(3), maxWidth: nil))
        let red = img.rgb(100, 60), hole = img.rgb(160, 120), outside = img.rgb(10, 120)
        #expect(red.0 > 0.9 && red.1 < 0.1 && red.2 < 0.1, "opaque part: red \(red)")
        #expect(abs(hole.0 - hole.1) < 0.05 && abs(hole.1 - hole.2) < 0.05, "the hole shows the grey video under it: \(hole)")
        #expect(abs(outside.0 - outside.1) < 0.05, "outside the picture: the grey video \(outside)")
    }

    /// A picture that runs past the last video still plays and is reachable:
    /// the composition lasts as long as the timeline, and its frame there is
    /// the picture.
    @Test func aPictureAfterTheVideoKeepsTheTimelineLong() async throws {
        let url = try Self.png()
        defer { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        let info = try await AVMediaProber().probe(url)
        var p = try await OpenGOPTests().project()
        let videoEnd = p.duration
        p.media.append(MediaAsset(id: "pic", path: url.path, name: "pic.png", fingerprint: "pic", info: info, kind: .image))
        p.tracks.append(Track(id: "over", kind: .overlay, name: "Over"))
        var add = AddClip(track: "over", asset: "pic", start: videoEnd + Time(seconds: 2), sourceDuration: Time(seconds: 600))
        try add.prepare(in: p)
        try add.apply(to: &p)
        let built = try await CompositionBuilder().build(p)
        #expect(abs(built.composition.duration.seconds - p.duration.seconds) < 0.01,
                "composition \(built.composition.duration.seconds) s, timeline \(p.duration.seconds) s")
        let img = ColorTools.Pixels(try await FrameCapture.timelineFrame(built, at: videoEnd + Time(seconds: 300), maxWidth: nil))
        let red = img.rgb(100, 60)
        #expect(red.0 > 0.9 && red.1 < 0.1, "the picture is drawn 5 minutes after the video: \(red)")
    }
}
