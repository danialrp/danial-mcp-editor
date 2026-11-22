import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import EditorCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders single frames for review, through the same compositor as playback
/// and export. HDR projects are tone mapped to an SDR picture for viewing.
public enum FrameCapture {
    /// The rendered timeline frame at `time`, at most `maxWidth` pixels wide.
    public static func timelineFrame(_ built: BuiltComposition, at time: Time, maxWidth: Int?) async throws -> CGImage {
        guard built.duration.ticks > 0 else { throw EditorError.invalid("the timeline is empty") }
        guard time >= .zero, time < built.duration else {
            throw EditorError.invalid("time must be within 0 and \(built.duration.seconds) s", parameter: "time")
        }
        // First frames of a clip at 0 s that has no room for its lead-in:
        // from the same timeline built later, where it has.
        if let (later, t) = built.prerolled(at: time) {
            if let from = later.inOrderStart(at: t), let image = try await decodedThrough(later, at: t, from: from, maxWidth: maxWidth) { return image }
            return try await timelineFrame(later, at: t, maxWidth: maxWidth)
        }
        // Leading frames of open-GOP video come out right only in order.
        if let from = built.inOrderStart(at: time),
           let image = try await decodedThrough(built, at: time, from: from, maxWidth: maxWidth) { return image }
        let g = AVAssetImageGenerator(asset: built.composition)
        g.videoComposition = built.videoComposition
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        g.dynamicRangePolicy = .forceSDR
        if let maxWidth { g.maximumSize = CGSize(width: maxWidth, height: 100_000) }
        MissedFrames.clear(cm(time))
        let image: CGImage?
        do { image = try await g.image(at: cm(time)).image } catch { image = nil }
        // A frame decoded on its own can come out empty in open-GOP video
        // (see DecodeStart); decoding straight through from earlier gives it.
        if image == nil || MissedFrames.take(cm(time)) {
            if let again = try await decodedThrough(built, at: time, from: Time.max(.zero, time - Time(seconds: 3)), maxWidth: maxWidth) { return again }
        }
        guard let image else { throw EditorError(.io, "the frame at \(time.seconds) s cannot be decoded") }
        return image
    }

    /// The timeline frame at `time`, decoded in order from `from`.
    static func decodedThrough(_ built: BuiltComposition, at time: Time, from: Time, maxWidth: Int?) async throws -> CGImage? {
        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: built.composition)
        // The compositor's own format, so nothing is converted on the way;
        // Core Image turns it into an sRGB picture below.
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        out.videoComposition = built.videoComposition
        reader.add(out)
        let frame = built.frameRate.frameDuration
        let start = built.safeStart(from)
        reader.timeRange = CMTimeRange(start: cm(start), duration: cm(time - start + frame))
        guard reader.startReading() else { return nil }
        var best: CVPixelBuffer?
        let limit = time + Time(ticks: frame.ticks / 2)
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            if MediaEngine.time(sb.presentationTimeStamp) <= limit { best = pb } else { break }
        }
        reader.cancelReading()
        guard let best else { return nil }
        var ci = CIImage(cvPixelBuffer: best)
        if let maxWidth, ci.extent.width > CGFloat(maxWidth) {
            let k = CGFloat(maxWidth) / ci.extent.width
            ci = ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        return CIContext().createCGImage(ci, from: ci.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// A frame of a media file as stored, before any processing.
    public static func sourceFrame(path: String, at time: Time, maxWidth: Int?) async throws -> CGImage {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        g.dynamicRangePolicy = .forceSDR
        if let maxWidth { g.maximumSize = CGSize(width: maxWidth, height: 100_000) }
        do {
            return try await g.image(at: cm(time)).image
        } catch {
            // A leading frame of open-GOP video cannot be decoded on its own;
            // decode in order from the keyframe before it.
            if let image = try await sourceFrameInOrder(asset, at: time, maxWidth: maxWidth) { return image }
            throw error
        }
    }

    /// The frame shown at `time`, decoded in order from where that works.
    static func sourceFrameInOrder(_ asset: AVURLAsset, at time: Time, maxWidth: Int?) async throws -> CGImage? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let segments = try await track.load(.segments)
        let at = cm(time)
        let start = DecodeStart.earlierStart(track, segments: segments, at: at) ?? CMTimeSubtract(at, CMTime(seconds: 3, preferredTimescale: 600))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTimeMaximum(.zero, start), end: CMTimeAdd(at, CMTime(seconds: 0.5, preferredTimescale: 600)))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        guard reader.startReading() else { return nil }
        var best: CVPixelBuffer?
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            if sb.presentationTimeStamp <= at { best = pb } else { break }
        }
        reader.cancelReading()
        guard let best else { return nil }
        let t = try await track.load(.preferredTransform)
        let rotation = ((Int((atan2(t.b, t.a) * 180 / .pi).rounded()) % 360) + 360) % 360
        var ci = CIImage(cvPixelBuffer: best).oriented(MatteStore.orientation(rotation))
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        if let maxWidth, ci.extent.width > CGFloat(maxWidth) {
            let k = CGFloat(maxWidth) / ci.extent.width
            ci = ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        return CIContext().createCGImage(ci, from: ci.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Frames laid out in a grid, each labelled with its time.
    public static func sheet(_ images: [(Time, CGImage)], columns: Int) -> CGImage? {
        guard let first = images.first?.1 else { return nil }
        let cw = first.width, ch = first.height, label = max(14, ch / 14)
        let rows = (images.count + columns - 1) / columns
        let w = cw * min(columns, images.count), h = (ch + label) * rows
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (i, (t, img)) in images.enumerated() {
            let col = i % columns, row = i / columns
            let y = h - (row + 1) * (ch + label)
            ctx.draw(img, in: CGRect(x: col * cw, y: y + label, width: cw, height: ch))
            drawText(String(format: "%.2f s", t.seconds), in: ctx, at: CGPoint(x: col * cw + 6, y: y + label / 5), size: CGFloat(label) * 0.7)
        }
        return ctx.makeImage()
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw EditorError(.io, "cannot encode PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw EditorError(.io, "cannot encode PNG") }
        return data as Data
    }

    private static func drawText(_ text: String, in ctx: CGContext, at p: CGPoint, size: CGFloat) {
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }
}
