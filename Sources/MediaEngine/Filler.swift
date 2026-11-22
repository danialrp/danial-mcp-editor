import AVFoundation
import CoreVideo
import Foundation

/// A one-second black video, made once and kept in the cache. A composition
/// ends where its last real media ends, so a timeline whose end is still
/// pictures (or HyperFrames layers, or nothing) would stop the player and
/// refuse seeks early. A track of this, stretched to the timeline's end,
/// gives the composition its full length; the compositor never draws it.
enum Filler {
    static let seconds = 1.0
    private static let lock = NSLock()

    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DanialMCPEditor", isDirectory: true).appendingPathComponent("filler-black-1s.mov")
    }

    /// The filler and its video track, made the first time they are needed.
    /// Keep the asset while the track is used: a track whose asset is gone
    /// cannot be inserted (AVFoundation error -12780).
    static func track() async throws -> (asset: AVURLAsset, track: AVAssetTrack) {
        let u = url
        if let t = try? await usable(u) { return t }
        // Missing or damaged (an interrupted write): make it again.
        if FileManager.default.fileExists(atPath: u.path) { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
        try await make(u)
        guard let t = try await usable(u) else { throw EditorErrorFiller.unreadable(u.path) }
        return t
    }

    private static func usable(_ u: URL) async throws -> (asset: AVURLAsset, track: AVAssetTrack)? {
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let asset = AVURLAsset(url: u)
        guard let t = try await asset.loadTracks(withMediaType: .video).first,
              try await t.load(.timeRange).duration.seconds >= seconds * 0.9 else { return nil }
        return (asset, t)
    }

    enum EditorErrorFiller: Error { case unreadable(String) }

    private static func make(_ u: URL) async throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written next to its place and moved in, so two builds at once never read half a file.
        let tmp = u.deletingLastPathComponent().appendingPathComponent("filler-\(UUID().uuidString).mov")
        let w = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 72,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 72,
        ])
        w.add(input)
        guard w.startWriting() else { throw w.error ?? EditorErrorFiller.unreadable(tmp.path) }
        w.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, nil, &pb)
        if let pb {
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            for t in [CMTime.zero, CMTime(seconds: seconds - 1.0 / 30, preferredTimescale: 600)] {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                adaptor.append(pb, withPresentationTime: t)
            }
        }
        input.markAsFinished()
        w.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await w.finishWriting()
        guard w.status == .completed else { throw w.error ?? EditorErrorFiller.unreadable(tmp.path) }
        try lock.withLock {
            if FileManager.default.fileExists(atPath: u.path) {
                try? FileManager.default.trashItem(at: tmp, resultingItemURL: nil)
            } else {
                try FileManager.default.moveItem(at: tmp, to: u)
            }
        }
    }
}
