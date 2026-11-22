import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import CoreMedia
import EditorCore
import EditorKit
import Foundation

/// Reads media properties with AVFoundation. Nothing is decoded.
public struct AVMediaProber: MediaProber {
    public init() {}

    public func probe(_ url: URL) async throws -> MediaInfo {
        if let still = Self.stillInfo(url) { return still }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw EditorError(.invalid, "\(url.lastPathComponent) is not a readable media file: \(error.localizedDescription)")
        }
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            throw EditorError(.invalid, "\(url.lastPathComponent) has no picture or sound")
        }
        var video: VideoInfo?
        if let v = videoTracks.first {
            let (size, transform, fps, formats) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            let shown = size.applying(transform)
            let f = formats.first
            let ext = f.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] }
            video = VideoInfo(
                width: Int(abs(shown.width).rounded()),
                height: Int(abs(shown.height).rounded()),
                frameRate: (Double(fps) * 1000).rounded() / 1000,
                codec: f.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown",
                bitDepth: ext?[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int
                    ?? (ext?["BitsPerComponent"] as? Int),
                transfer: ext?[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
                primaries: ext?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String)
        }
        var audio: AudioInfo?
        if let a = audioTracks.first {
            let formats = try await a.load(.formatDescriptions)
            if let f = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                audio = AudioInfo(sampleRate: Int(asbd.mSampleRate), channels: Int(asbd.mChannelsPerFrame),
                                  codec: fourCC(asbd.mFormatID))
            }
        }
        let seconds = duration.isNumeric ? duration.seconds : 0
        return MediaInfo(duration: Time(seconds: seconds), video: video, audio: audio)
    }
}

/// A four-character code as text, for example "hvc1" or "aac ".
func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    let s = String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    return s.trimmingCharacters(in: .whitespaces)
}

extension AVMediaProber {
    /// A still picture's size, read upright (with its EXIF orientation);
    /// nil when the file is not a picture.
    static func stillInfo(_ url: URL) -> MediaInfo? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int, var h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let depth = props[kCGImagePropertyDepth] as? Int
        return MediaInfo(duration: MediaAsset.stillDuration,
                         video: VideoInfo(width: w, height: h, frameRate: 0, codec: "image/" + (type.preferredFilenameExtension ?? "picture"),
                                          bitDepth: depth, transfer: nil, primaries: nil),
                         audio: nil)
    }
}
