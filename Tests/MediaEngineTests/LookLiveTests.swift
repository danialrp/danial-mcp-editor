import AVFoundation
import EditorCore
import Foundation
@testable import MediaEngine
import Testing

/// Looks on real decoded video (4:2:0 YUV, the path camera footage takes):
/// a look at 0 gives back the source exactly, and values changed in place
/// (a drag, `look.update`) give the same picture as a fresh build.
@Suite("Looks on video", .serialized)
struct LookLiveTests {
    func project(_ look: Look?) async throws -> Project {
        var p = try await OpenGOPTests().project()
        if let look {
            p.looks = [look]
            for i in p.tracks[0].clips.indices { p.tracks[0].clips[i].look = look.id }
        }
        return p
    }

    /// Every pixel of the frame at `t`, as bytes.
    func frame(_ built: BuiltComposition, _ t: Time) async throws -> [UInt8] {
        let img = try await FrameCapture.timelineFrame(built, at: t, maxWidth: nil)
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return px
    }

    func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 }

    @Test func aLookAtZeroChangesNoPixel() async throws {
        let plain = try await CompositionBuilder().build(try await project(nil))
        let zero = try await CompositionBuilder().build(try await project(Look(id: "look_z", name: "z")))
        for n in [3, 20, 34, 45] {
            let t = Time(ticks: Int64(n) * 8000)
            #expect(maxDiff(try await frame(plain, t), try await frame(zero, t)) == 0, "frame \(n)")
        }
    }

    @Test func valuesChangedInPlaceMatchAFreshBuild() async throws {
        var a = Look(id: "look_l", name: "l")
        a.exposure = 30
        var b = a
        b.exposure = -45; b.contrast = 35; b.temperature = 40; b.clarity = 50; b.shadows = 30
        let live = try await CompositionBuilder().build(try await project(a))
        live.setLooks([b])
        let fresh = try await CompositionBuilder().build(try await project(b))
        let before = try await CompositionBuilder().build(try await project(a))
        for n in [5, 22, 40] {
            let t = Time(ticks: Int64(n) * 8000)
            let l = try await frame(live, t), f = try await frame(fresh, t)
            #expect(maxDiff(l, f) == 0, "frame \(n): in place and fresh differ")
            #expect(maxDiff(l, try await frame(before, t)) > 10, "frame \(n): the new values show")
        }
    }
}
