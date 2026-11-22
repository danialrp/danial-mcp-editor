extension Project {
    /// Track indexes a timeline command acts on: the given ids, every track, or
    /// the main track by default.
    func targetTracks(_ ids: [EntityID]?, all: Bool?) throws -> [Int] {
        if all == true { return Array(tracks.indices) }
        if let ids, !ids.isEmpty { return try ids.map { try trackIndex($0) } }
        return [try mainTrackIndex()]
    }

    /// Like `targetTracks`, but checks locks: named tracks must be unlocked,
    /// and `allTracks` skips locked ones.
    func editableTracks(_ ids: [EntityID]?, all: Bool?) throws -> [Int] {
        let t = try targetTracks(ids, all: all)
        if all == true { return t.filter { !tracks[$0].locked } }
        for i in t { try tracks[i].ensureUnlocked() }
        return t
    }
}

private let tracksParameters = [
    Parameter("tracks", .array(.id), "Track ids; default the main track"),
    Parameter("allTracks", .boolean, "Act on every track"),
]

public struct SplitAt: EditorCommand {
    public static let name = "timeline.split"
    public static let spec = CommandSpec("Split clips at a time (Cmd+B).", [
        Parameter("time", .seconds, "Timeline time", required: true),
    ] + tracksParameters)

    public var time: Time
    public var tracks: [EntityID]?
    public var allTracks: Bool?
    public var idSeed: String?

    public init(time: Time, tracks: [EntityID]? = nil, allTracks: Bool? = nil) {
        self.time = time
        self.tracks = tracks
        self.allTracks = allTracks
    }

    public mutating func prepare(in p: Project) throws {
        time = try p.snap(time, "time")
        idSeed = idSeed ?? IDGenerator.newSeed()
    }

    public func apply(to p: inout Project) throws {
        var gen = IDGenerator(seed: idSeed!)
        for ti in try p.editableTracks(tracks, all: allTracks) {
            p.tracks[ti].split(at: time, ids: &gen)
        }
    }
}

/// Deletes from the start of the clip under `time` up to `time` (Q), or from
/// `time` to the end of that clip (W), and closes the gap.
public struct DeleteToClipEdge: EditorCommand {
    public enum Side: String, Codable, Sendable, CaseIterable { case left, right }

    public static let name = "timeline.deleteToEdge"
    public static let spec = CommandSpec("Delete from a time to the start (left, key Q) or end (right, key W) of the clip under it, and close the gap.", [
        Parameter("time", .seconds, "Timeline time, usually the playhead", required: true),
        Parameter("side", .oneOf(Side.allCases.map(\.rawValue)), "left or right", required: true),
        Parameter("track", .id, "Track id; default the main track"),
        Parameter("ripple", .boolean, "Close the gap; default true"),
    ])

    public var time: Time
    public var side: Side
    public var track: EntityID?
    public var ripple: Bool?
    public var idSeed: String?

    public init(time: Time, side: Side, track: EntityID? = nil, ripple: Bool? = nil) {
        self.time = time
        self.side = side
        self.track = track
        self.ripple = ripple
    }

    public mutating func prepare(in p: Project) throws {
        time = try p.snap(time, "time")
        idSeed = idSeed ?? IDGenerator.newSeed()
    }

    public func apply(to p: inout Project) throws {
        let ti = try track.map { try p.trackIndex($0) } ?? p.mainTrackIndex()
        try p.tracks[ti].ensureUnlocked()
        // At a clip boundary, "left" means the clip that ends here.
        let probe = side == .left ? time - Time(ticks: 1) : time
        guard let ci = p.tracks[ti].clipIndex(containing: probe) else {
            throw EditorError.invalid("there is no clip at \(time.seconds) s on track \(p.tracks[ti].id)", parameter: "time")
        }
        let c = p.tracks[ti].clips[ci]
        let range = side == .left ? TimeRange(start: c.start, end: time) : TimeRange(start: time, end: c.end)
        guard !range.isEmpty else { return }
        var gen = IDGenerator(seed: idSeed!)
        p.tracks[ti].delete(range, ripple: ripple ?? true, ids: &gen)
    }
}

public struct DeleteRange: EditorCommand {
    public static let name = "timeline.deleteRange"
    public static let spec = CommandSpec("Delete everything in a time range, splitting clips at its edges. The gap closes by default.", [
        Parameter("start", .seconds, "Range start", required: true),
        Parameter("end", .seconds, "Range end", required: true),
        Parameter("ripple", .boolean, "Close the gap; default true"),
    ] + tracksParameters)

    public var start: Time
    public var end: Time
    public var ripple: Bool?
    public var tracks: [EntityID]?
    public var allTracks: Bool?
    public var idSeed: String?

    public init(start: Time, end: Time, ripple: Bool? = nil, tracks: [EntityID]? = nil, allTracks: Bool? = nil) {
        self.start = start
        self.end = end
        self.ripple = ripple
        self.tracks = tracks
        self.allTracks = allTracks
    }

    public mutating func prepare(in p: Project) throws {
        start = try p.snap(start, "start")
        end = try p.snap(end, "end")
        guard start < end else { throw EditorError.invalid("end must be after start", parameter: "end") }
        idSeed = idSeed ?? IDGenerator.newSeed()
    }

    public func apply(to p: inout Project) throws {
        var gen = IDGenerator(seed: idSeed!)
        for ti in try p.editableTracks(tracks, all: allTracks) {
            p.tracks[ti].delete(TimeRange(start: start, end: end), ripple: ripple ?? true, ids: &gen)
        }
    }
}

public struct CloseGaps: EditorCommand {
    public static let name = "timeline.closeGaps"
    public static let spec = CommandSpec("Move clips left so a track has no empty spaces, starting at zero.", [
        Parameter("track", .id, "Track id; default the main track"),
    ])

    public var track: EntityID?

    public init(track: EntityID? = nil) { self.track = track }

    public func apply(to p: inout Project) throws {
        let ti = try track.map { try p.trackIndex($0) } ?? p.mainTrackIndex()
        try p.tracks[ti].ensureUnlocked()
        p.tracks[ti].closeGaps()
    }
}
