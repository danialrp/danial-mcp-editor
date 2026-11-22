import Foundation

/// Paste: copies of clips at a time, keeping their tracks and their spacing
/// (the earliest copy starts at `start`). On the main track the copies are
/// inserted and later clips move; elsewhere they need free space.
public struct CopyClipsTo: EditorCommand {
    public static let name = "clip.copyTo"
    public static let spec = CommandSpec("Copy clips to a time (paste): the copies keep their tracks and spacing, the earliest starts at start. On the main track later clips move to make room; on other tracks the space must be free.", [
        Parameter("ids", .array(.id), "Clip ids", required: true),
        Parameter("start", .seconds, "Where the earliest copy starts", required: true),
    ])

    public var ids: [EntityID]
    public var start: Time
    public var idSeed: String?

    public init(ids: [EntityID], start: Time) {
        self.ids = ids
        self.start = start
    }

    public mutating func prepare(in p: Project) throws {
        start = try p.snap(start, "start")
        idSeed = idSeed ?? IDGenerator.newSeed()
    }

    public func apply(to p: inout Project) throws {
        guard !ids.isEmpty else { throw EditorError.invalid("no clips to copy", parameter: "ids") }
        var q = p
        try paste(&q)
        p = q
    }

    private func paste(_ p: inout Project) throws {
        var gen = IDGenerator(seed: idSeed!)
        let found = try ids.map { id -> (Int, Clip) in let (t, c) = try p.locate(clip: id); return (t, p.tracks[t].clips[c]) }
        let first = found.map(\.1.start).min()!
        // Latest first, so inserting on the main track does not move the others' places.
        for (t, c) in found.sorted(by: { $0.1.start > $1.1.start }) {
            try p.tracks[t].ensureUnlocked()
            var copy = c
            copy.id = gen.next("clip")
            copy.start = start + (c.start - first)
            if p.tracks[t].kind == .main { p.tracks[t].insertRippling(copy, ids: &gen) } else { try p.tracks[t].place(copy) }
        }
    }
}

/// Moves clips by whole frames (the , and . keys).
public struct NudgeClips: EditorCommand {
    public static let name = "clip.nudge"
    public static let spec = CommandSpec("Move clips earlier (negative) or later by whole frames, keeping their tracks. Fails when a clip would overlap another or go before 0 s.", [
        Parameter("ids", .array(.id), "Clip ids", required: true),
        Parameter("frames", .integer, "Frames to move; negative is earlier", required: true),
    ])

    public var ids: [EntityID]
    public var frames: Int

    public init(ids: [EntityID], frames: Int) {
        self.ids = ids
        self.frames = frames
    }

    public func apply(to p: inout Project) throws {
        guard !ids.isEmpty else { throw EditorError.invalid("no clips to move", parameter: "ids") }
        // All or nothing: work on a copy.
        var p2 = p
        try nudge(&p2)
        p = p2
    }

    private func nudge(_ p: inout Project) throws {
        let by = Time(ticks: p.settings.frameRate.frameDuration.ticks * Int64(frames))
        let moving = Set(ids)
        var placed: [(Int, Clip)] = []
        for id in ids {
            let (t, c) = try p.locate(clip: id)
            try p.tracks[t].ensureUnlocked()
            var clip = p.tracks[t].clips[c]
            clip.start = clip.start + by
            guard clip.start.ticks >= 0 else { throw EditorError.invalid("clip \(id) would start before 0 s", parameter: "frames") }
            placed.append((t, clip))
        }
        for t in Set(placed.map(\.0)) { p.tracks[t].clips.removeAll { moving.contains($0.id) } }
        for (t, clip) in placed.sorted(by: { $0.1.start < $1.1.start }) { try p.tracks[t].place(clip) }
    }
}

/// Extract audio (CapCut): each clip's sound goes onto an audio track as its
/// own clip with the same timing, and the original clip is muted, so the
/// sound can be trimmed apart from the picture (J and L cuts).
public struct DetachAudio: EditorCommand {
    public static let name = "clip.detachAudio"
    public static let spec = CommandSpec("Extract the sound of clips onto an audio track as their own clips (same timing, gain and fades) and mute the originals, so sound and picture can be cut apart. The track is created when the project has none free at those times.", [
        Parameter("ids", .array(.id), "Clip ids", required: true),
        Parameter("track", .id, "Audio track to use; default the first audio track with room, else a new one"),
    ])

    public var ids: [EntityID]
    public var track: EntityID?
    public var idSeed: String?

    public init(ids: [EntityID], track: EntityID? = nil) {
        self.ids = ids
        self.track = track
    }

    public mutating func prepare(in p: Project) throws { idSeed = idSeed ?? IDGenerator.newSeed() }

    public func apply(to p: inout Project) throws {
        guard !ids.isEmpty else { throw EditorError.invalid("no clips", parameter: "ids") }
        var q = p
        var gen = IDGenerator(seed: idSeed!)
        var sounds: [Clip] = []
        for id in ids {
            let (t, c) = try q.locate(clip: id)
            try q.tracks[t].ensureUnlocked()
            let clip = q.tracks[t].clips[c]
            guard q.tracks[t].kind != .audio else { throw EditorError.invalid("clip \(id) is already on an audio track", parameter: "ids") }
            guard try q.asset(clip.asset).info.audio != nil else { throw EditorError.invalid("clip \(id) has no sound", parameter: "ids") }
            var s = clip
            s.id = gen.next("clip")
            s.transform = Transform.identity
            s.opacity = 1
            s.effects = []
            s.keyframes = [:]
            s.look = nil
            sounds.append(s)
            q.tracks[t].clips[c].muted = true
        }
        // A track with room for all of them: the one given, the first audio
        // track that is free there, or a new one.
        func fits(_ t: Track) -> Bool { sounds.allSatisfy { t.overlapping($0.range).isEmpty } }
        let ti: Int
        if let track {
            ti = try q.trackIndex(track)
            guard q.tracks[ti].kind == .audio else { throw EditorError.invalid("track \(track) is not an audio track", parameter: "track") }
        } else if let i = q.tracks.firstIndex(where: { $0.kind == .audio && !$0.locked && fits($0) }) {
            ti = i
        } else {
            q.tracks.append(Track(id: gen.next("track"), kind: .audio, name: "Extracted sound"))
            ti = q.tracks.count - 1
        }
        try q.tracks[ti].ensureUnlocked()
        for s in sounds.sorted(by: { $0.start < $1.start }) { try q.tracks[ti].place(s) }
        p = q
    }
}

/// Freeze frame: the picture at a time held for a while. The clip is split
/// there and a copy that shows one source frame, stretched over `duration`,
/// is inserted (later clips move). Being the same footage, it keeps the
/// clip's look, its transform as shown at that moment, its person matte and
/// exact colour; it is silent.
public struct FreezeFrame: EditorCommand {
    public static let name = "clip.freezeFrame"
    public static let spec = CommandSpec("Freeze frame: hold the clip's picture at a time for a while. The clip is split there and one source frame is inserted, stretched over duration (later clips move); it keeps the look, the transform as shown at that moment and the person matte, and is silent. One undo step.", [
        Parameter("time", .seconds, "Timeline time of the frame to hold", required: true),
        Parameter("duration", .seconds, "How long to hold it; default 2 s"),
        Parameter("track", .id, "Track; default the main track"),
    ])

    public var time: Time
    public var duration: Time?
    public var track: EntityID?
    public var idSeed: String?

    public init(time: Time, duration: Time? = nil, track: EntityID? = nil) {
        self.time = time
        self.duration = duration
        self.track = track
    }

    public mutating func prepare(in p: Project) throws {
        time = try p.snap(time, "time")
        if let d = duration { duration = try p.snap(d, "duration") }
        idSeed = idSeed ?? IDGenerator.newSeed()
    }

    public func apply(to p: inout Project) throws {
        let hold = duration ?? Time(seconds: 2).snapped(to: p.settings.frameRate)
        guard hold.ticks > 0 else { throw EditorError.invalid("duration must be at least one frame", parameter: "duration") }
        let ti = try track.map { try p.trackIndex($0) } ?? p.tracks.firstIndex { $0.kind == .main }
        guard let ti, let ci = p.tracks[ti].clipIndex(containing: time) else {
            throw EditorError.invalid("no clip at \(time.seconds) s on that track", parameter: "time")
        }
        try p.tracks[ti].ensureUnlocked()
        let c = p.tracks[ti].clips[ci]
        let a = try p.asset(c.asset)
        guard let fps = a.info.video?.frameRate, fps > 0, !a.isImage else {
            throw EditorError.invalid("clip \(c.id) is not footage; a picture holds by itself", parameter: "time")
        }
        // The source frame shown at that time, on the file's own frame grid.
        let frame = 1 / fps
        let src = (c.sourceTime(at: time).seconds / frame + 1e-6).rounded(.down) * frame
        var gen = IDGenerator(seed: idSeed!)
        var q = p
        q.tracks[ti].split(at: time, ids: &gen)
        var held = c
        held.id = gen.next("clip")
        held.start = time
        held.duration = hold
        held.sourceStart = Time(seconds: src)
        held.sourceDuration = Time(seconds: frame)
        (held.transform, held.opacity) = c.animated(at: time)
        held.keyframes = [:]
        held.effects = []
        held.muted = true
        held.fadeIn = .zero
        held.fadeOut = .zero
        q.tracks[ti].insertRippling(held, ids: &gen)
        p = q
    }
}
