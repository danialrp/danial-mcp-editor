import CoreGraphics
import EditorCore
import Foundation
import ImageIO
@testable import MediaEngine
import Testing
import UniformTypeIdentifiers

/// A contact sheet for looking at the colour controls by eye: one row per
/// slider, its values left to right, rendered from a real frame. Runs only
/// when DME_SHEET_FRAME names a picture and DME_SHEET_OUT a PNG to write.
@Suite("Colour contact sheet")
struct LookSheetTests {
    static let frame = ProcessInfo.processInfo.environment["DME_SHEET_FRAME"]
    static let out = ProcessInfo.processInfo.environment["DME_SHEET_OUT"]

    @Test(.enabled(if: frame != nil && out != nil)) func sheet() async throws {
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: Self.frame!) as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let w = img.width, h = img.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixel: (Int, Int) -> RGB = { x, y in let i = (y * w + x) * 4; return RGB(Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2])) / 255 }

        let names = (ProcessInfo.processInfo.environment["DME_SHEET_SLIDERS"]?.split(separator: ",").map(String.init)) ?? Look.sliders.map(\.name)
        let values: [Double] = [-100, -50, -25, 0, 25, 50, 100]
        let tw = w / 2, th = h / 2
        let sw = tw * values.count, sh = th * names.count
        var sheet = [UInt8](repeating: 0, count: sw * sh * 4)
        for (r, name) in names.enumerated() {
            let range = Look.sliders.first { $0.name == name }!.range
            for (c, v) in values.enumerated() {
                let value = range.lowerBound >= 0 ? (v + 100) / 2 : v
                let p = try await LookRender.render(LookRender.slider(name, value), width: w, height: h, pixel: pixel)
                for y in 0..<th {
                    for x in 0..<tw {
                        let q = p.at(x * 2, y * 2), o = ((r * th + y) * sw + c * tw + x) * 4
                        sheet[o] = UInt8(min(max(q.x, 0), 1) * 255); sheet[o + 1] = UInt8(min(max(q.y, 0), 1) * 255)
                        sheet[o + 2] = UInt8(min(max(q.z, 0), 1) * 255); sheet[o + 3] = 255
                    }
                }
            }
        }
        let octx = CGContext(data: &sheet, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: Self.out!) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, octx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// How much each slider at -100 and +100 moves this frame: mean and
    /// largest luma change, in levels of 255.
    @Test(.enabled(if: frame != nil)) func strengthOnThisFrame() async throws {
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: Self.frame!) as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let w = img.width, h = img.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixel: (Int, Int) -> RGB = { x, y in let i = (y * w + x) * 4; return RGB(Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2])) / 255 }
        let base = try await LookRender.render(nil, width: w, height: h, pixel: pixel)
        var lines: [String] = []
        for s in Look.sliders {
            var cells: [String] = []
            for v in (s.range.lowerBound < 0 ? [-100.0, 100.0] : [100.0]) {
                let p = try await LookRender.render(LookRender.slider(s.name, v), width: w, height: h, pixel: pixel)
                var sum = 0.0, top = 0.0
                for i in p.px.indices { let d = abs(Chart.luma(p.px[i]) - Chart.luma(base.px[i])) * 255; sum += d; top = max(top, d) }
                cells.append(String(format: "%+4.0f: mean %5.1f max %5.1f", v, sum / Double(p.px.count), top))
            }
            lines.append("\(s.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(cells.joined(separator: "   "))")
        }
        print("[strength]\n" + lines.joined(separator: "\n"))
    }
}
