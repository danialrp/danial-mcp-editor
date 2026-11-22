// Commands that change how clips look and sound.

extension Project {
    /// Clips grouped by track, in time order within each track.
    func clipsByTrack(_ ids: [EntityID]) throws -> [(track: Int, clips: [Int])] {
        guard !ids.isEmpty else { throw EditorError.invalid("ids must not be empty", parameter: "ids") }
        var map: [Int: [Int]] = [:]
        for id in ids {
            let (t, c) = try locate(clip: id)
            map[t, default: []].append(c)
        }
        return map.keys.sorted().map { ($0, Array(Set(map[$0]!)).sorted()) }
    }
}

public struct SetClipSpeed: EditorCommand {
    public static let name = "clip.setSpeed"
    public static let spec = CommandSpec("Change clip speed; the voice keeps its pitch. The clip's length changes and, on the main track, later clips move with it.", [
        Parameter("ids", .array(.id), "Clip ids", required: true),
        Parameter("speed", .number, "1 is normal, 1.22 is 22% faster", required: true),
        Parameter("ripple", .boolean, "Move later clips by the change in length; default true on the main track"),
    ])

    public var ids: [EntityID]
    public var speed: Double
    public var ripple: Bool?

    public init(ids: [EntityID], speed: Double, ripple: Bool? = nil) {
        self.ids = ids
        self.speed = speed
        self.ripple = ripple
    }

    public func apply(to p: inout Project) throws {
        guard speed >= 0.05, speed <= 100 else { throw EditorError.invalid("speed must be between 0.05 and 100", parameter: "speed") }
        let rate = p.settings.frameRate
        for (ti, indexes) in try p.clipsByTrack(ids) {
            try p.tracks[ti].ensureUnlocked()
            let rippling = ripple ?? (p.tracks[ti].kind == .main)
            var track = p.tracks[ti]
            var shift = Time.zero
            var next = indexes.makeIterator()
            var target = next.next()
            for i in track.clips.indices {
                track.clips[i].start = track.clips[i].start + shift
                guard i == target else { continue }
                target = next.next()
                let c = track.clips[i]
                var d = Time(ticks: Int64((Double(c.sourceDuration.ticks) / speed).rounded())).snapped(to: rate)
                if d.ticks <= 0 { d = rate.frameDuration }
                track.clips[i].duration = d
                track.clips[i].fitFades()
                if rippling { shift = shift + (d - c.duration) }
            }
            if !rippling {
                for i in 1..<max(1, track.clips.count) where track.clips[i - 1].end > track.clips[i].start {
                    throw EditorError(.conflict, "clip \(track.clips[i - 1].id) would overlap clip \(track.clips[i].id); pass ripple true or make room")
                }
            }
            p.tracks[ti] = track
        }
    }
}

public struct SetClipAudio: EditorCommand {
    public static let name = "clip.setAudio"
    public static let spec = CommandSpec("Set the sound of clips: gain, mute, fade in and fade out.", [
        Parameter("ids", .array(.id), "Clip ids", required: true),
        Parameter("gainDB", .number, "Gain in dB, -60 to +24; 0 leaves the level as recorded"),
        Parameter("muted", .boolean, "Silence the clip"),
        Parameter("fadeIn", .seconds, "Fade-in length at the clip start"),
        Parameter("fadeOut", .seconds, "Fade-out length at the clip end"),
    ])

    public var ids: [EntityID]
    public var gainDB: Double?
    public var muted: Bool?
    public var fadeIn: Time?
    public var fadeOut: Time?

    public init(ids: [EntityID], gainDB: Double? = nil, muted: Bool? = nil, fadeIn: Time? = nil, fadeOut: Time? = nil) {
        self.ids = ids
        self.gainDB = gainDB
        self.muted = muted
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public func apply(to p: inout Project) throws {
        if let g = gainDB, !(-60...24).contains(g) { throw EditorError.invalid("gainDB must be between -60 and 24", parameter: "gainDB") }
        for (ti, indexes) in try p.clipsByTrack(ids) {
            try p.tracks[ti].ensureUnlocked()
            for i in indexes {
                var c = p.tracks[ti].clips[i]
                if let gainDB { c.gainDB = gainDB }
                if let muted { c.muted = muted }
                if let fadeIn { c.fadeIn = fadeIn }
                if let fadeOut { c.fadeOut = fadeOut }
                guard c.fadeIn.ticks >= 0, c.fadeOut.ticks >= 0, c.fadeIn + c.fadeOut <= c.duration else {
                    throw EditorError.invalid("fades of clip \(c.id) must not be negative or longer than the clip together (\(c.duration.seconds) s)")
                }
                p.tracks[ti].clips[i] = c
            }
        }
    }
}

public struct SetClipTransform: EditorCommand {
    public static let name = "clip.setTransform"
    public static let spec = CommandSpec("Place clips' pictures on the canvas: position, scale, rotation, fit, crop and opacity. Omitted values stay as they are.", [
        Parameter("ids", .array(.id), "Clip ids", required: true),
        Parameter("x", .number, "Centre across the canvas, 0 left edge to 1 right edge; 0.5 is centred"),
        Parameter("y", .number, "Centre down the canvas, 0 top to 1 bottom; 0.5 is centred"),
        Parameter("scale", .number, "1 is the size given by fit"),
        Parameter("rotation", .number, "Degrees clockwise"),
        Parameter("fit", .oneOf(Transform.Fit.allCases.map(\.rawValue)), "fit (whole picture visible) or fill (canvas covered)"),
        Parameter("cropLeft", .number, "Fraction of the source cut from the left, 0 to 1"),
        Parameter("cropTop", .number, "Fraction cut from the top"),
        Parameter("cropRight", .number, "Fraction cut from the right"),
        Parameter("cropBottom", .number, "Fraction cut from the bottom"),
        Parameter("opacity", .number, "0 transparent to 1 opaque"),
    ])

    public var ids: [EntityID]
    public var x: Double?
    public var y: Double?
    public var scale: Double?
    public var rotation: Double?
    public var fit: Transform.Fit?
    public var cropLeft: Double?
    public var cropTop: Double?
    public var cropRight: Double?
    public var cropBottom: Double?
    public var opacity: Double?

    public init(ids: [EntityID]) { self.ids = ids }

    public func apply(to p: inout Project) throws {
        if let scale, !(0.01...100).contains(scale) { throw EditorError.invalid("scale must be between 0.01 and 100", parameter: "scale") }
        if let opacity, !(0...1).contains(opacity) { throw EditorError.invalid("opacity must be between 0 and 1", parameter: "opacity") }
        for (v, k) in [(cropLeft, "cropLeft"), (cropTop, "cropTop"), (cropRight, "cropRight"), (cropBottom, "cropBottom")] {
            if let v, !(0..<1).contains(v) { throw EditorError.invalid("\(k) must be at least 0 and below 1", parameter: k) }
        }
        for (ti, indexes) in try p.clipsByTrack(ids) {
            try p.tracks[ti].ensureUnlocked()
            guard p.tracks[ti].kind != .audio else { throw EditorError.invalid("clips on audio tracks have no picture") }
            for i in indexes {
                var t = p.tracks[ti].clips[i].transform
                if let x { t.x = x }
                if let y { t.y = y }
                if let scale { t.scale = scale }
                if let rotation { t.rotation = rotation }
                if let fit { t.fit = fit }
                if let cropLeft { t.cropLeft = cropLeft }
                if let cropTop { t.cropTop = cropTop }
                if let cropRight { t.cropRight = cropRight }
                if let cropBottom { t.cropBottom = cropBottom }
                guard t.cropLeft + t.cropRight < 1, t.cropTop + t.cropBottom < 1 else {
                    throw EditorError.invalid("the crop would leave nothing of clip \(p.tracks[ti].clips[i].id)")
                }
                p.tracks[ti].clips[i].transform = t
                if let opacity { p.tracks[ti].clips[i].opacity = opacity }
            }
        }
    }
}

public struct SetJoinFades: EditorCommand {
    public static let name = "timeline.setJoinFades"
    public static let spec = CommandSpec("Set the short sound fade on each side of every cut between touching clips on a track, so cuts do not click. Zero turns it off.", [
        Parameter("duration", .seconds, "Fade length on each side, 0 to 1 s; the production flow uses 0.05", required: true),
        Parameter("track", .id, "Track id; default the main track"),
    ])

    public var duration: Time
    public var track: EntityID?

    public init(duration: Time, track: EntityID? = nil) {
        self.duration = duration
        self.track = track
    }

    public func apply(to p: inout Project) throws {
        guard duration.ticks >= 0, duration <= Time(seconds: 1) else {
            throw EditorError.invalid("duration must be between 0 and 1 s", parameter: "duration")
        }
        let ti = try track.map { try p.trackIndex($0) } ?? p.mainTrackIndex()
        try p.tracks[ti].ensureUnlocked()
        p.tracks[ti].joinFade = duration
    }
}
