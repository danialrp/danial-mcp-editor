import EditorCore
import Foundation

/// An export format (R-1). Size, frame rate and dynamic range left out take
/// the project's own. Presets are data in the user settings (M-4).
public struct ExportPreset: Codable, Equatable, Sendable {
    public enum VideoCodec: String, Codable, Sendable, CaseIterable {
        /// HEVC Main 10 (10-bit), hardware encoded.
        case hevc
        /// H.264 High (8-bit), hardware encoded.
        case h264
        case prores422hq
        /// Keeps alpha.
        case prores4444
    }

    public enum AudioCodec: String, Codable, Sendable, CaseIterable {
        case aac
        /// 24-bit linear PCM; needs the mov container.
        case pcm
    }

    public enum Container: String, Codable, Sendable, CaseIterable { case mp4, mov }

    public var summary: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: FrameRate?
    public var dynamicRange: DynamicRange?
    public var videoCodec: VideoCodec
    /// Average video bit rate; ignored for ProRes.
    public var videoBitrateMbps: Double?
    public var audioCodec: AudioCodec
    public var audioBitrateKbps: Int
    public var container: Container

    public init(summary: String? = nil, width: Int? = nil, height: Int? = nil, frameRate: FrameRate? = nil,
                dynamicRange: DynamicRange? = nil, videoCodec: VideoCodec, videoBitrateMbps: Double? = nil,
                audioCodec: AudioCodec = .aac, audioBitrateKbps: Int = 320, container: Container = .mp4) {
        self.summary = summary
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.dynamicRange = dynamicRange
        self.videoCodec = videoCodec
        self.videoBitrateMbps = videoBitrateMbps
        self.audioCodec = audioCodec
        self.audioBitrateKbps = audioBitrateKbps
        self.container = container
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        frameRate = try c.decodeIfPresent(FrameRate.self, forKey: .frameRate)
        dynamicRange = try c.decodeIfPresent(DynamicRange.self, forKey: .dynamicRange)
        videoCodec = try c.decodeIfPresent(VideoCodec.self, forKey: .videoCodec) ?? .hevc
        videoBitrateMbps = try c.decodeIfPresent(Double.self, forKey: .videoBitrateMbps)
        audioCodec = try c.decodeIfPresent(AudioCodec.self, forKey: .audioCodec) ?? .aac
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? 320
        container = try c.decodeIfPresent(Container.self, forKey: .container) ?? .mp4
    }

    /// Problems that make the preset unusable, worded so they can be fixed.
    public func problems() -> [String] {
        var out: [String] = []
        if let w = width, w < 16 || w > 8192 || w % 2 != 0 { out.append("width must be an even number from 16 to 8192") }
        if let h = height, h < 16 || h > 8192 || h % 2 != 0 { out.append("height must be an even number from 16 to 8192") }
        if (width == nil) != (height == nil) { out.append("give width and height together, or neither") }
        if let b = videoBitrateMbps, b <= 0 || b > 1000 { out.append("videoBitrateMbps must be above 0 and at most 1000") }
        if audioBitrateKbps < 64 || audioBitrateKbps > 512 { out.append("audioBitrateKbps must be 64 to 512") }
        if container == .mp4, audioCodec == .pcm { out.append("PCM audio needs the mov container") }
        if container == .mp4, videoCodec == .prores422hq || videoCodec == .prores4444 { out.append("ProRes needs the mov container") }
        if videoCodec == .h264, (dynamicRange ?? .sdr) == .hlg { out.append("HDR (HLG) needs HEVC or ProRes; H.264 here is 8-bit") }
        return out
    }

    /// The canvas, frame rate and dynamic range this preset gives a project.
    public func settings(for p: ProjectSettings) -> ProjectSettings {
        ProjectSettings(width: width ?? p.width, height: height ?? p.height,
                        frameRate: frameRate ?? p.frameRate, dynamicRange: dynamicRange ?? p.dynamicRange)
    }

    /// Shipped presets: the delivery formats in use (requirements section 3).
    public static let shipped: [String: ExportPreset] = [
        "reel": ExportPreset(summary: "Instagram Reel or Short: 1440x2560, 60 fps, HEVC 10-bit HLG", width: 1440, height: 2560,
                             frameRate: .fps60, dynamicRange: .hlg, videoCodec: .hevc, videoBitrateMbps: 40),
        "story": ExportPreset(summary: "Story or ad: 2160x3840, 60 fps, H.264, Rec.709", width: 2160, height: 3840,
                              frameRate: .fps60, dynamicRange: .sdr, videoCodec: .h264, videoBitrateMbps: 60),
        "lesson": ExportPreset(summary: "Course lesson: 1920x1080, 30 fps, H.264, Rec.709", width: 1920, height: 1080,
                               frameRate: .fps30, dynamicRange: .sdr, videoCodec: .h264, videoBitrateMbps: 16),
        "youtube": ExportPreset(summary: "YouTube 4K: 3840x2160, 60 fps, HEVC 10-bit", width: 3840, height: 2160,
                                frameRate: .fps60, dynamicRange: .sdr, videoCodec: .hevc, videoBitrateMbps: 60),
        "master": ExportPreset(summary: "Master at the project's own format: ProRes 422 HQ, PCM audio",
                               videoCodec: .prores422hq, audioCodec: .pcm, container: .mov),
    ]
}

/// How exports are cut and run.
public struct ExportOptions: Codable, Equatable, Sendable {
    /// Length of one cached segment. Shorter re-renders less after a small
    /// edit; longer has fewer joins.
    public var segmentSeconds: Double = 2
    /// Segments rendered at once. The hardware encoder is the limit, so more
    /// than two barely helps (phase 0, test 2).
    public var parallelSegments: Int = 2
    /// Lets the hardware encoder favour speed (H.264 and HEVC). Measured,
    /// 4K 60 HEVC: 1.6 times faster, the frames against the
    /// careful mode at SSIM 0.996 and PSNR 52 dB, so on by default.
    public var speedOverQuality = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportOptions()
        segmentSeconds = try c.decodeIfPresent(Double.self, forKey: .segmentSeconds) ?? d.segmentSeconds
        parallelSegments = try c.decodeIfPresent(Int.self, forKey: .parallelSegments) ?? d.parallelSegments
        speedOverQuality = try c.decodeIfPresent(Bool.self, forKey: .speedOverQuality) ?? d.speedOverQuality
    }
}
