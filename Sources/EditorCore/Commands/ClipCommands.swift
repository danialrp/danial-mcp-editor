public enum PlacementMode: String, Codable, Sendable, CaseIterable {
    /// Use free space only; fail if the clip would overlap another.
    case place
    /// Push later clips on the track to make room.
    case insert
}

extension Project {
    /// Checks that an asset can be shown on a track of this kind.
    func checkAsset(_ a: MediaAsset, fits kind: TrackKind) throws {
        switch kind {
        case .main, .overlay:
            if a.info.video == nil { throw EditorError.invalid("media \(a.id) has no picture and cannot go on a \(kind.rawValue) track") }
        case .audio:
            if a.info.audio == nil { throw EditorError.invalid("media \(a.id) has no sound and cannot go on an audio track") }
        }
    }

    /// Checks that a source range lies inside an asset.
    func checkSource(_ start: Time, _ duration: Time, in a: MediaAsset) throws {
        guard start.ticks >= 0 else { throw EditorError.invalid("sourceStart must not be negative", parameter: "sourceStart") }
        guard duration.ticks > 0 else { throw EditorError.invalid("the source range is empty", parameter: "sourceDuration") }
        if start + duration > a.info.duration + Time(ticks: 1) {
            throw EditorError.invalid("source range \(start.seconds)-\((start + duration).seconds) s is past the end of media \(a.id) (\(a.info.duration.seconds) s)")
        }
    }
}

public struct AddClip: EditorCommand {
    public static let name = "clip.add"
    public static let spec = CommandSpec("Place part of a media file on a track.", [
        Parameter("track", .id, "Track id", required: true),
        Parameter("asset", .id, "Media asset id", required: true),
        Parameter("start", .seconds, "Timeline time; default is the end of the track"),
        Parameter("sourceStart", .seconds, "Where in the file the clip begins; default 0"),
        Parameter("sourceDuration", .seconds, "How much of the file to use; default the rest of it"),
        Parameter("speed", .number, "Playback speed, 1 is normal; default 1"),
        Parameter("mode", .oneOf(PlacementMode.allCases.map(\.rawValue)), "place (free space only, default) or insert (push later clips)"),
        Parameter("id", .id, "Id for the new clip; one is made if omitted"),
    ])

    public var track: EntityID
    public var asset: EntityID
    public var start: Time?
    public var sourceStart: Time?
    public var sourceDuration: Time?
    public var speed: Double?
    public var mode: PlacementMode?
    public var id: EntityID?
    public var idSeed: String?

    public init(track: EntityID, asset: EntityID, start: Time? = nil, sourceStart: Time? = nil,
                sourceDuration: Time? = nil, speed: Double? = nil, mode: PlacementMode? = nil, id: EntityID? = nil) {
        self.track = track
        self.asset = asset
        self.start = start
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.speed = speed
        self.mode = mode
        self.id = id
    }

    public mutating func prepare(in p: Project) throws {
        let t = p.tracks[try p.trackIndex(track)]
        start = try p.snap(start ?? t.end, "start")
        if let id { try requireUnusedID(id, in: p) } else { id = .random("clip") }
        idSeed = idSeed ?? IDGenerator.newSeed()
    }

    public func apply(to p: inout Project) throws {
        let ti = try p.trackIndex(track)
        try p.tracks[ti].ensureUnlocked()
        let a = try p.asset(asset)
        try p.checkAsset(a, fits: p.tracks[ti].kind)
        let s = speed ?? 1
        guard s >= 0.05, s <= 100 else { throw EditorError.invalid("speed must be between 0.05 and 100", parameter: "speed") }
        let srcStart = sourceStart ?? .zero
        let srcDur = sourceDuration ?? (a.isImage ? Time(seconds: MediaAsset.stillDefaultSeconds) : a.info.duration - srcStart)
        try p.checkSource(srcStart, srcDur, in: a)
        let duration = Time(ticks: Int64((Double(srcDur.ticks) / s).rounded())).snapped(to: p.settings.frameRate)
        guard duration.ticks > 0 else { throw EditorError.invalid("the clip would be shorter than one frame") }
        let clip = Clip(id: id!, asset: asset, start: start!, duration: duration,
                        sourceStart: srcStart, sourceDuration: srcDur)
        switch mode ?? .place {
        case .place: try p.tracks[ti].place(clip)
        case .insert:
            var ids = IDGenerator(seed: idSeed!)
            p.tracks[ti].insertRippling(clip, ids: &ids)
        }
    }
}

public struct MoveClip: EditorCommand {
    public static let name = "clip.move"
    public static let spec = CommandSpec("Move a clip to another time or track.", [
        Parameter("id", .id, "Clip id", required: true),
        Parameter("start", .seconds, "New timeline start", required: true),
        Parameter("track", .id, "Target track; default the clip's own track"),
        Parameter("mode", .oneOf(PlacementMode.allCases.map(\.rawValue)), "place (default) or insert"),
    ])

    public var id: EntityID
    public var start: Time
    public var track: EntityID?
    public var mode: PlacementMode?
    public var idSeed: String?

    public init(id: EntityID, start: Time, track: EntityID? = nil, mode: PlacementMode? = nil) {
        self.id = id
        self.start = start
        self.track = track
        self.mode = mode
    }

    public mutating func prepare(in p: Project) throws {
        start = try p.snap(start, "start")
        idSeed = idSeed ?? IDGenerator.newSeed()
    }

    public func apply(to p: inout Project) throws {
        let (ti, ci) = try p.locate(clip: id)
        try p.tracks[ti].ensureUnlocked()
        var clip = p.tracks[ti].clips.remove(at: ci)
        let target = try track.map { try p.trackIndex($0) } ?? ti
        try p.tracks[target].ensureUnlocked()
        try p.checkAsset(try p.asset(clip.asset), fits: p.tracks[target].kind)
        clip.start = start
        switch mode ?? .place {
        case .place: try p.tracks[target].place(clip)
        case .insert:
            var ids = IDGenerator(seed: idSeed!)
            p.tracks[target].insertRippling(clip, ids: &ids)
        }
    }
}

public struct TrimClip: EditorCommand {
    public enum Edge: String, Codable, Sendable, CaseIterable { case start, end }

    public static let name = "clip.trim"
    public static let spec = CommandSpec("Move a clip's start or end edge. Speed is kept. Other clips do not move.", [
        Parameter("id", .id, "Clip id", required: true),
        Parameter("edge", .oneOf(Edge.allCases.map(\.rawValue)), "start or end", required: true),
        Parameter("time", .seconds, "Timeline time for that edge", required: true),
    ])

    public var id: EntityID
    public var edge: Edge
    public var time: Time

    public init(id: EntityID, edge: Edge, time: Time) {
        self.id = id
        self.edge = edge
        self.time = time
    }

    public mutating func prepare(in p: Project) throws { time = try p.snap(time, "time") }

    public func apply(to p: inout Project) throws {
        let (ti, ci) = try p.locate(clip: id)
        try p.tracks[ti].ensureUnlocked()
        let a = try p.asset(p.tracks[ti].clips[ci].asset)
        var c = p.tracks[ti].clips[ci]
        let speed = c.speed
        switch edge {
        case .start:
            guard time < c.end else { throw EditorError.invalid("the start must be before the clip's end (\(c.end.seconds) s)", parameter: "time") }
            let newSourceStart = c.sourceStart + Time(ticks: Int64((Double((time - c.start).ticks) * speed).rounded()))
            c.sourceDuration = c.sourceEnd - newSourceStart
            c.sourceStart = newSourceStart
            c.duration = c.end - time
            c.start = time
        case .end:
            guard time > c.start else { throw EditorError.invalid("the end must be after the clip's start (\(c.start.seconds) s)", parameter: "time") }
            c.duration = time - c.start
            c.sourceDuration = Time(ticks: Int64((Double(c.duration.ticks) * speed).rounded()))
        }
        try p.checkSource(c.sourceStart, c.sourceDuration, in: a)
        if let h = p.tracks[ti].overlapping(c.range, ignoring: [c.id]).first {
            throw EditorError(.conflict, "the trimmed clip would overlap clip \(h.id)")
        }
        c.fitFades()
        p.tracks[ti].clips[ci] = c
    }
}

public struct SlipClip: EditorCommand {
    public static let name = "clip.slip"
    public static let spec = CommandSpec("Shift which part of the file a clip shows, keeping its place and length on the timeline.", [
        Parameter("id", .id, "Clip id", required: true),
        Parameter("by", .seconds, "Source seconds to shift; negative moves earlier in the file", required: true),
    ])

    public var id: EntityID
    public var by: Time

    public init(id: EntityID, by: Time) {
        self.id = id
        self.by = by
    }

    public func apply(to p: inout Project) throws {
        let (ti, ci) = try p.locate(clip: id)
        try p.tracks[ti].ensureUnlocked()
        var c = p.tracks[ti].clips[ci]
        c.sourceStart = c.sourceStart + by
        try p.checkSource(c.sourceStart, c.sourceDuration, in: try p.asset(c.asset))
        p.tracks[ti].clips[ci] = c
    }
}

public struct RemoveClips: EditorCommand {
    public static let name = "clip.remove"
    public static let spec = CommandSpec("Remove clips. On the main track the gap closes by default.", [
        Parameter("ids", .array(.id), "Clip ids", required: true),
        Parameter("ripple", .boolean, "Close the gap; default true on the main track, false elsewhere"),
    ])

    public var ids: [EntityID]
    public var ripple: Bool?

    public init(ids: [EntityID], ripple: Bool? = nil) {
        self.ids = ids
        self.ripple = ripple
    }

    public func apply(to p: inout Project) throws {
        var byTrack: [Int: Set<EntityID>] = [:]
        for id in ids { byTrack[try p.locate(clip: id).track, default: []].insert(id) }
        for (ti, set) in byTrack {
            try p.tracks[ti].ensureUnlocked()
            p.tracks[ti].remove(set, ripple: ripple ?? (p.tracks[ti].kind == .main))
        }
    }
}

public struct ReplaceClipMedia: EditorCommand {
    public static let name = "clip.replaceMedia"
    public static let spec = CommandSpec("Show another media file in a clip, keeping its place, length and source range.", [
        Parameter("id", .id, "Clip id", required: true),
        Parameter("asset", .id, "New media asset id", required: true),
    ])

    public var id: EntityID
    public var asset: EntityID

    public init(id: EntityID, asset: EntityID) {
        self.id = id
        self.asset = asset
    }

    public func apply(to p: inout Project) throws {
        let (ti, ci) = try p.locate(clip: id)
        try p.tracks[ti].ensureUnlocked()
        let a = try p.asset(asset)
        try p.checkAsset(a, fits: p.tracks[ti].kind)
        let c = p.tracks[ti].clips[ci]
        try p.checkSource(c.sourceStart, c.sourceDuration, in: a)
        p.tracks[ti].clips[ci].asset = asset
    }
}

public struct DuplicateClips: EditorCommand {
    public static let name = "clip.duplicate"
    public static let spec = CommandSpec("Copy clips. Each copy goes right after its original and later clips move to make room.", [
        Parameter("ids", .array(.id), "Clip ids", required: true),
    ])

    public var ids: [EntityID]
    public var idSeed: String?

    public init(ids: [EntityID]) { self.ids = ids }

    public mutating func prepare(in p: Project) throws { idSeed = idSeed ?? IDGenerator.newSeed() }

    public func apply(to p: inout Project) throws {
        var gen = IDGenerator(seed: idSeed!)
        for id in ids {
            let (ti, ci) = try p.locate(clip: id)
            try p.tracks[ti].ensureUnlocked()
            var copy = p.tracks[ti].clips[ci]
            copy.id = gen.next("clip")
            copy.start = copy.end
            p.tracks[ti].insertRippling(copy, ids: &gen)
        }
    }
}
