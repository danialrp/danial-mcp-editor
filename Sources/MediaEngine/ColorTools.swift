import AVFoundation
import CoreGraphics
import EditorCore
import EditorKit
import Foundation
import ImageIO

/// Numbers an agent needs to judge and match colour (C-5): a colour at a
/// point, statistics of a frame or region, and a comparison with a reference.
public enum ColorTools {
    /// 8-bit sRGB pixels of an image, row by row.
    struct Pixels {
        var width: Int, height: Int
        var data: [UInt8]

        init(_ img: CGImage) {
            width = img.width
            height = img.height
            data = [UInt8](repeating: 0, count: width * height * 4)
            let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * width + x) * 4
            return (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
        }
    }

    struct Region { var x, y, w, h: Double }

    static func region(_ args: Args) throws -> Region {
        guard let r = args.values["region"], r != .null else { return Region(x: 0, y: 0, w: 1, h: 1) }
        let g = { (k: String, d: Double) in r[k]?.doubleValue ?? d }
        let reg = Region(x: g("x", 0), y: g("y", 0), w: g("w", 1), h: g("h", 1))
        guard reg.w > 0, reg.h > 0, reg.x >= 0, reg.y >= 0, reg.x + reg.w <= 1.0001, reg.y + reg.h <= 1.0001 else {
            throw EditorError.invalid("region is {x, y, w, h} as fractions of the frame, inside 0 to 1", parameter: "region")
        }
        return reg
    }

    static func stats(_ px: Pixels, _ r: Region) -> JSONValue {
        let x0 = Int(r.x * Double(px.width)), y0 = Int(r.y * Double(px.height))
        let x1 = max(x0 + 1, Int((r.x + r.w) * Double(px.width))), y1 = max(y0 + 1, Int((r.y + r.h) * Double(px.height)))
        var sum = (0.0, 0.0, 0.0), sat = 0.0, lumas: [Double] = [], hist = [Int](repeating: 0, count: 16)
        var low = 0, high = 0
        for y in y0..<min(y1, px.height) {
            for x in x0..<min(x1, px.width) {
                let (r, g, b) = px.rgb(x, y)
                sum.0 += r; sum.1 += g; sum.2 += b
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas.append(l)
                let mx = max(r, g, b), mn = min(r, g, b)
                sat += mx > 0 ? (mx - mn) / mx : 0
                hist[min(15, Int(l * 16))] += 1
                if l < 0.02 { low += 1 }
                if l > 0.98 { high += 1 }
            }
        }
        let n = Double(max(1, lumas.count))
        lumas.sort()
        func pc(_ p: Double) -> Double { lumas.isEmpty ? 0 : (lumas[Int(Double(lumas.count - 1) * p)] * 1000).rounded() / 1000 }
        func r3(_ v: Double) -> JSONValue { .number((v * 1000).rounded() / 1000) }
        let mean = (sum.0 / n, sum.1 / n, sum.2 / n)
        return .object([
            "meanRGB": .array([r3(mean.0), r3(mean.1), r3(mean.2)]),
            "meanHex": .string(hex(mean.0, mean.1, mean.2)),
            "luma": .object(["mean": r3(lumas.reduce(0, +) / n), "p5": .number(pc(0.05)), "p50": .number(pc(0.5)), "p95": .number(pc(0.95))]),
            "saturation": r3(sat / n),
            "clippedBlacks": r3(Double(low) / n),
            "clippedWhites": r3(Double(high) / n),
            "lumaHistogram16": .array(hist.map { r3(Double($0) / n) }),
        ])
    }

    static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// The timeline frame, with looks or without (the camera picture).
    static func frame(_ media: MediaContext, at t: Time, withLook: Bool) async throws -> CGImage {
        if withLook {
            let built = try await media.composition()
            return try await FrameCapture.timelineFrame(built, at: t.snapped(to: built.frameRate), maxWidth: 960)
        }
        var p = await (try await media.editor.requireSession()).project
        for i in p.looks.indices { p.looks[i].enabled = false }
        let built = try await media.composition(for: p)
        return try await FrameCapture.timelineFrame(built, at: t.snapped(to: built.frameRate), maxWidth: 960)
    }

    public static func make(_ media: MediaContext) -> [Tool] {
        [
            Tool("color.sample", .read, "The colour at a point of the timeline frame, as #RRGGBB, averaged over a small square. Without a look by default, so a picked colour (skin, eyes) matches the camera picture.", [
                Parameter("time", .seconds, "Timeline time", required: true),
                Parameter("x", .number, "Across the frame, 0 left to 1 right", required: true),
                Parameter("y", .number, "Down the frame, 0 top to 1 bottom", required: true),
                Parameter("radius", .integer, "Half-size of the square in pixels of a 960-wide frame; default 4"),
                Parameter("withLook", .boolean, "Sample the picture with looks applied"),
            ]) { _, args in
                let img = try await frame(media, at: try args.time("time")!, withLook: try args.bool("withLook") ?? false)
                let px = Pixels(img)
                let r = Double(try args.int("radius") ?? 4)
                let cx = try args.double("x")!, cy = try args.double("y")!
                guard (0...1).contains(cx), (0...1).contains(cy) else { throw EditorError.invalid("x and y are fractions from 0 to 1") }
                let reg = Region(x: max(0, cx - r / Double(px.width)), y: max(0, cy - r / Double(px.height)),
                                 w: min(1 - max(0, cx - r / Double(px.width)), 2 * r / Double(px.width)),
                                 h: min(1 - max(0, cy - r / Double(px.height)), 2 * r / Double(px.height)))
                let s = stats(px, reg)
                return .object(["color": s["meanHex"]!, "rgb": s["meanRGB"]!])
            },
            Tool("color.stats", .read, "Colour and light statistics of the timeline frame or a region of it: mean colour, luma percentiles, saturation, clipped blacks and whites, luma histogram.", [
                Parameter("time", .seconds, "Timeline time", required: true),
                Parameter("region", .object, "{\"x\", \"y\", \"w\", \"h\"} as fractions of the frame; default the whole frame"),
                Parameter("withLook", .boolean, "With looks applied; default true"),
            ]) { _, args in
                let img = try await frame(media, at: try args.time("time")!, withLook: try args.bool("withLook") ?? true)
                return stats(Pixels(img), try region(args))
            },
            Tool("color.compare", .read, "Compare the timeline frame with a reference image (a still from a film, a scene, another clip): both sets of statistics and the differences, to steer look changes toward the reference.", [
                Parameter("time", .seconds, "Timeline time", required: true),
                Parameter("reference", .string, "Image file (PNG, JPEG, HEIC) to match", required: true),
                Parameter("region", .object, "Region of the timeline frame to compare; default the whole frame"),
                Parameter("referenceRegion", .object, "Region of the reference; default the whole image"),
            ]) { _, args in
                let img = try await frame(media, at: try args.time("time")!, withLook: true)
                let url = URL(fileURLWithPath: (try args.requiredString("reference") as NSString).expandingTildeInPath)
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let ref = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                              kCGImageSourceThumbnailMaxPixelSize: 960,
                                                                              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                    throw EditorError(.notFound, "cannot read image \(url.path)")
                }
                let a = stats(Pixels(img), try region(args))
                var refArgs = args.values
                refArgs["region"] = args.values["referenceRegion"]
                let b = stats(Pixels(ref), try region(Args(refArgs)))
                func d(_ path: [String]) -> JSONValue {
                    var x: JSONValue? = a, y: JSONValue? = b
                    for k in path { x = x?[k]; y = y?[k] }
                    guard let xv = x?.doubleValue, let yv = y?.doubleValue else { return .null }
                    return .number(((yv - xv) * 1000).rounded() / 1000)
                }
                let ma = a["meanRGB"]?.arrayValue?.compactMap(\.doubleValue) ?? [0, 0, 0]
                let mb = b["meanRGB"]?.arrayValue?.compactMap(\.doubleValue) ?? [0, 0, 0]
                return .object([
                    "frame": a, "reference": b,
                    "referenceMinusFrame": .object([
                        "lumaMean": d(["luma", "mean"]), "lumaP5": d(["luma", "p5"]), "lumaP95": d(["luma", "p95"]),
                        "saturation": d(["saturation"]),
                        "meanRGB": .array(zip(ma, mb).map { .number((($1 - $0) * 1000).rounded() / 1000) }),
                    ]),
                ])
            },
        ]
    }
}
