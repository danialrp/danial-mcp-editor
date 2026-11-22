import AVFoundation
import CoreGraphics
import CoreText
import EditorCore
import EditorKit
import Foundation
import ImageIO

/// What an agent needs to understand a download without playing it: a
/// contact sheet, single frames, the subtitle text and the loudness.
public enum SocialInspect {
    public struct Options: Sendable {
        public var file: String?
        public var sheetFrames: Int
        public var columns: Int
        public var frameWidth: Int
        public var frames: Int
        public var times: [Double]?
        public var subtitles = true
        public var audio = true
        public var maxText: Int
        public var loudnessMaxSeconds: Double
    }

    /// Times spread evenly over a length: the middle of each of `n` parts.
    public static func evenTimes(_ n: Int, over duration: Double) -> [Double] {
        guard n > 0, duration > 0 else { return [] }
        return (0..<n).map { (Double($0) + 0.5) * duration / Double(n) }
    }

    /// Inspects one download; images are returned for the caller to inline.
    public static func run(_ e: SocialStore.Entry, _ o: Options) async throws -> (JSONValue, [CGImage]) {
        let folder = e.folder
        let out = folder.appendingPathComponent(SocialStore.inspectFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = e.item.files
        var result: [String: JSONValue] = [
            "id": .string(e.item.id), "folder": .string(folder.path), "location": .string(e.location.rawValue),
            "metadata": try JSONValue(encoding: e.item.metadata),
        ]
        var inline: [CGImage] = []
        let chosen: [SocialFile]
        if let name = o.file {
            guard let f = files.first(where: { $0.name == name }) else {
                throw EditorError(.notFound, "\(e.item.id) has no file \(name); files are \(files.map(\.name).joined(separator: ", "))", parameter: "file")
            }
            chosen = [f]
        } else if let v = files.first(where: { $0.kind == .video }) {
            chosen = [v]
        } else if files.contains(where: { $0.kind == .image }) {
            chosen = files.filter { $0.kind == .image }
        } else {
            chosen = files.filter { $0.kind == .audio }.prefix(1).map { $0 }
        }
        result["files"] = try JSONValue(encoding: chosen)

        if let v = chosen.first, v.kind == .video {
            let url = folder.appendingPathComponent(v.name)
            let d = v.duration ?? 0
            let stem = SocialPlatform.safeName((v.name as NSString).deletingPathExtension)
            if o.sheetFrames > 0, d > 0 {
                var frames: [(Time, CGImage)] = []
                for t in evenTimes(min(48, o.sheetFrames), over: d) {
                    frames.append((Time(seconds: t), try await FrameCapture.sourceFrame(path: url.path, at: Time(seconds: t), maxWidth: o.frameWidth)))
                }
                if let sheet = FrameCapture.sheet(frames, columns: max(1, o.columns)) {
                    let p = out.appendingPathComponent("sheet-\(stem).png")
                    try FrameCapture.png(sheet).write(to: p, options: .atomic)
                    result["sheet"] = .object(["path": .string(p.path), "frames": .number(Double(frames.count)),
                                               "times": .array(frames.map { .number(($0.0.seconds * 100).rounded() / 100) })])
                    inline.append(sheet)
                }
            }
            let times = (o.times ?? evenTimes(o.frames, over: d)).filter { $0 >= 0 && (d == 0 || $0 < d) }
            var saved: [JSONValue] = []
            for t in times {
                let img = try await FrameCapture.sourceFrame(path: url.path, at: Time(seconds: t), maxWidth: max(o.frameWidth, 720))
                let p = out.appendingPathComponent(String(format: "frame-%@-%07.2f.png", stem, t))
                try FrameCapture.png(img).write(to: p, options: .atomic)
                saved.append(.object(["time": .number((t * 100).rounded() / 100), "path": .string(p.path),
                                      "width": .number(Double(img.width)), "height": .number(Double(img.height))]))
            }
            if !saved.isEmpty { result["frames"] = .array(saved) }
        } else {
            let pictures = chosen.filter { $0.kind == .image }
            if !pictures.isEmpty {
                var imgs: [(String, CGImage)] = []
                for p in pictures {
                    if let img = thumbnail(folder.appendingPathComponent(p.name), maxWidth: o.frameWidth) { imgs.append((p.name, img)) }
                }
                result["pictures"] = .array(pictures.map { .object(["path": .string(folder.appendingPathComponent($0.name).path),
                                                                     "width": $0.width.map { .number(Double($0)) } ?? .null,
                                                                     "height": $0.height.map { .number(Double($0)) } ?? .null]) })
                if let sheet = grid(imgs, columns: max(1, min(o.columns, imgs.count))) {
                    let p = out.appendingPathComponent("sheet-pictures.png")
                    try FrameCapture.png(sheet).write(to: p, options: .atomic)
                    result["sheet"] = .object(["path": .string(p.path), "frames": .number(Double(imgs.count))])
                    inline.append(sheet)
                }
            }
        }

        if o.subtitles {
            var subs: [JSONValue] = []
            for f in files where f.kind == .subtitles {
                let p = folder.appendingPathComponent(f.name)
                guard let raw = try? String(contentsOf: p, encoding: .utf8) else { continue }
                let text = SubtitleText.plain(raw)
                subs.append(.object(["language": f.language.map { .string($0) } ?? .null, "path": .string(p.path),
                                     "text": .string(String(text.prefix(o.maxText))), "truncated": .bool(text.count > o.maxText),
                                     "characters": .number(Double(text.count))]))
            }
            if !subs.isEmpty { result["subtitles"] = .array(subs) }
        }

        if o.audio, let a = chosen.first(where: { $0.kind == .video || $0.kind == .audio }),
           let d = a.duration, d > 0, d <= o.loudnessMaxSeconds {
            let asset = AVURLAsset(url: folder.appendingPathComponent(a.name))
            if (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false {
                if let l = try? await Loudness.measure(asset) {
                    result["audio"] = .object(["file": .string(a.name), "integratedLUFS": .number(l.integratedLUFS),
                                               "shortTermMaxLUFS": .number(l.shortTermMaxLUFS), "samplePeakDBFS": .number(l.samplePeakDBFS),
                                               "seconds": .number((l.seconds * 100).rounded() / 100)])
                }
            } else {
                result["audio"] = .object(["file": .string(a.name), "hasSound": .bool(false)])
            }
        }
        return (.object(result), inline)
    }

    /// A picture file read upright and scaled to at most `maxWidth`.
    static func thumbnail(_ url: URL, maxWidth: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxWidth,
        ] as CFDictionary)
    }

    /// Pictures of different sizes in a grid of equal cells, each labelled
    /// with its file name.
    static func grid(_ images: [(String, CGImage)], columns: Int) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let cw = images.map(\.1.width).max()!, ch = images.map(\.1.height).max()!, label = max(14, ch / 14)
        let rows = (images.count + columns - 1) / columns
        let w = cw * columns, h = (ch + label) * rows
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (i, (name, img)) in images.enumerated() {
            let col = i % columns, row = i / columns
            let y = h - (row + 1) * (ch + label)
            let x = col * cw + (cw - img.width) / 2
            ctx.draw(img, in: CGRect(x: x, y: y + label + (ch - img.height) / 2, width: img.width, height: img.height))
            let attr = NSAttributedString(string: name, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, CGFloat(label) * 0.7, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: col * cw + 6, y: y + label / 5)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        return ctx.makeImage()
    }
}
