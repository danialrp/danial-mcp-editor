/// A point or a duration on a timeline, in ticks of 1/240000 s.
///
/// 240000 divides evenly by 24, 25, 30, 48, 50 and 60 fps frame durations and by
/// 48000 Hz audio samples, so frame and sample positions are exact integers and
/// repeated cuts never accumulate rounding error.
///
/// In JSON a time is a number of seconds. Every tick count converts to seconds
/// and back exactly, so files and tool arguments stay readable without losing
/// precision.
public struct Time: Hashable, Comparable, Sendable, Codable {
    public static let ticksPerSecond: Int64 = 240_000

    public var ticks: Int64

    public init(ticks: Int64) { self.ticks = ticks }

    public static let zero = Time(ticks: 0)

    /// Not-a-number and infinite values become zero rather than trapping;
    /// callers that must reject them check `isFinite` first.
    public init(seconds: Double) {
        let t = (seconds * Double(Self.ticksPerSecond)).rounded()
        self.ticks = t.isFinite && abs(t) < 9e18 ? Int64(t) : 0
    }

    public var seconds: Double { Double(ticks) / Double(Self.ticksPerSecond) }

    /// The largest time a tool argument or command may give, either sign
    /// (about 31 years). Values a project derives from such times (a word
    /// plus an offset, a keyframe on a fast clip) stay where seconds in JSON
    /// still convert back to the exact tick.
    public static let maxSeconds: Double = 1e9

    /// The longest a timeline may run.
    public static let maxTimelineSeconds: Double = maxSeconds

    /// What a saved project may hold: wider than `maxSeconds`, so a project
    /// always opens again, and small enough that tick counts cannot overflow.
    public static let maxStoredSeconds: Double = 1e13

    /// Set to true in a decoder's `userInfo` for tool arguments and commands,
    /// which `maxSeconds` limits; project files are read with the wider limit.
    public static let argumentsKey = CodingUserInfoKey(rawValue: "dme.timeArguments")!

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(Double.self)
        let limit = decoder.userInfo[Self.argumentsKey] as? Bool == true ? Self.maxSeconds : Self.maxStoredSeconds
        guard s.isFinite, abs(s) <= limit else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "time must be a number of seconds between -\(Int(limit)) and \(Int(limit))"))
        }
        self.init(seconds: s)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(seconds)
    }

    public static func max(_ a: Time, _ b: Time) -> Time { a > b ? a : b }
    public static func min(_ a: Time, _ b: Time) -> Time { a < b ? a : b }

    public static func < (a: Time, b: Time) -> Bool { a.ticks < b.ticks }
    public static func + (a: Time, b: Time) -> Time { Time(ticks: a.ticks + b.ticks) }
    public static func - (a: Time, b: Time) -> Time { Time(ticks: a.ticks - b.ticks) }

    /// Nearest position on a frame grid. Ties go to the earlier frame.
    public func snapped(to rate: FrameRate) -> Time {
        let f = rate.frameDuration.ticks
        let q = ticks / f, r = ticks % f
        let frames = (r * 2 > f) ? q + 1 : q
        return Time(ticks: frames * f)
    }

    /// Index of the frame that contains this time.
    public func frameIndex(at rate: FrameRate) -> Int64 {
        ticks >= 0 ? ticks / rate.frameDuration.ticks
                   : -((-ticks + rate.frameDuration.ticks - 1) / rate.frameDuration.ticks)
    }
}

/// A frame rate that divides the tick base exactly.
public struct FrameRate: Hashable, Sendable, Codable {
    public let fps: Int

    public init?(fps: Int) {
        guard fps > 0, Time.ticksPerSecond % Int64(fps) == 0 else { return nil }
        self.fps = fps
    }

    // In JSON a frame rate is a plain integer.
    public init(from decoder: Decoder) throws {
        let v = try decoder.singleValueContainer().decode(Int.self)
        guard let r = FrameRate(fps: v) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unsupported frame rate \(v)"))
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fps)
    }

    public static let fps30 = FrameRate(fps: 30)!
    public static let fps60 = FrameRate(fps: 60)!

    public var frameDuration: Time { Time(ticks: Time.ticksPerSecond / Int64(fps)) }

    public func time(ofFrame index: Int64) -> Time {
        Time(ticks: index * frameDuration.ticks)
    }
}

/// A half-open range [start, start + duration).
public struct TimeRange: Hashable, Sendable, Codable {
    public var start: Time
    public var duration: Time

    public init(start: Time, duration: Time) {
        self.start = start
        self.duration = duration
    }

    public init(start: Time, end: Time) {
        self.init(start: start, duration: end - start)
    }

    public var end: Time { start + duration }
    public var isEmpty: Bool { duration.ticks <= 0 }

    public func contains(_ t: Time) -> Bool { t >= start && t < end }
}
