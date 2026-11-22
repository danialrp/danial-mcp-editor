// Effects on clips and transform keyframes (E-7, E-8, X-1, X-2).

extension Project {
    fileprivate func effectIndex(_ fx: EntityID, on c: Clip) throws -> Int {
        guard let i = c.effects.firstIndex(where: { $0.id == fx }) else {
            throw EditorError.invalid("clip \(c.id) has no effect \(fx); its effects are \(c.effects.map(\.id.raw).joined(separator: ", "))", parameter: "effect")
        }
        return i
    }

    fileprivate mutating func editClip(_ id: EntityID, _ change: (inout Clip) throws -> Void) throws {
        let (ti, ci) = try locate(clip: id)
        try tracks[ti].ensureUnlocked()
        var c = tracks[ti].clips[ci]
        try change(&c)
        tracks[ti].clips[ci] = c
    }
}

/// Adds an effect instance to a clip, or replaces the one with the same id.
/// Created by `effect.add` and `effect.set`, which check the parameters
/// against the plug-in first.
public struct PutEffect: EditorCommand {
    public static let name = "effect.put"
    public static let spec = CommandSpec("Add or replace an effect instance on a clip.", [
        Parameter("clip", .id, "Clip id", required: true),
        Parameter("instance", .object, "The effect instance", required: true),
        Parameter("index", .integer, "Position in the clip's effect list for a new instance; default last"),
    ], exposedAsTool: false)

    public var clip: EntityID
    public var instance: EffectInstance
    public var index: Int?

    public init(clip: EntityID, instance: EffectInstance, index: Int? = nil) {
        self.clip = clip
        self.instance = instance
        self.index = index
    }

    public mutating func prepare(in p: Project) throws {
        let (ti, ci) = try p.locate(clip: clip)
        let exists = p.tracks[ti].clips[ci].effects.contains { $0.id == instance.id }
        if !exists { try requireUnusedID(instance.id, in: p) }
    }

    public func apply(to p: inout Project) throws {
        if instance.kind != .filter, (instance.duration?.ticks ?? 0) <= 0 {
            throw EditorError.invalid("\(instance.kind.rawValue) effects need a duration", parameter: "duration")
        }
        try p.editClip(clip) { c in
            if let i = c.effects.firstIndex(where: { $0.id == instance.id }) {
                c.effects[i] = instance
            } else {
                let at = index ?? c.effects.count
                guard (0...c.effects.count).contains(at) else {
                    throw EditorError.invalid("index must be 0 to \(c.effects.count)", parameter: "index")
                }
                c.effects.insert(instance, at: at)
            }
        }
    }
}

public struct RemoveEffect: EditorCommand {
    public static let name = "effect.remove"
    public static let spec = CommandSpec("Remove an effect from a clip.", [
        Parameter("clip", .id, "Clip id", required: true),
        Parameter("effect", .id, "Effect instance id (from clip.get)", required: true),
    ])

    public var clip: EntityID
    public var effect: EntityID

    public init(clip: EntityID, effect: EntityID) {
        self.clip = clip
        self.effect = effect
    }

    public func apply(to p: inout Project) throws {
        let pr = p
        try p.editClip(clip) { c in c.effects.remove(at: try pr.effectIndex(effect, on: c)) }
    }
}

public struct ReorderEffect: EditorCommand {
    public static let name = "effect.reorder"
    public static let spec = CommandSpec("Move an effect to another place in its clip's list; effects run first to last.", [
        Parameter("clip", .id, "Clip id", required: true),
        Parameter("effect", .id, "Effect instance id", required: true),
        Parameter("index", .integer, "New position, 0 is first", required: true),
    ])

    public var clip: EntityID
    public var effect: EntityID
    public var index: Int

    public init(clip: EntityID, effect: EntityID, index: Int) {
        self.clip = clip
        self.effect = effect
        self.index = index
    }

    public func apply(to p: inout Project) throws {
        let pr = p
        try p.editClip(clip) { c in
            let i = try pr.effectIndex(effect, on: c)
            guard (0..<c.effects.count).contains(index) else {
                throw EditorError.invalid("index must be 0 to \(c.effects.count - 1)", parameter: "index")
            }
            c.effects.insert(c.effects.remove(at: i), at: index)
        }
    }
}

// MARK: keyframes

/// Converts timeline times into the clip's source time, the base keyframes
/// are stored in.
private func sourceTime(_ t: Time, clip c: Clip, project p: Project, parameter: String) throws -> Time {
    let s = try p.snap(t, parameter)
    guard s >= c.start, s <= c.end else {
        throw EditorError.invalid("\(parameter) \(s.seconds) s is outside clip \(c.id) (\(c.start.seconds) to \(c.end.seconds) s)", parameter: parameter)
    }
    return c.sourceTime(at: s)
}

public struct SetKeyframes: EditorCommand {
    public static let name = "clip.setKeyframes"
    public static let spec = CommandSpec("Replace the keyframes of one transform property of a clip, for zoom and moves (E-7). An empty list removes the animation and the clip's fixed transform applies again.", [
        Parameter("clip", .id, "Clip id", required: true),
        Parameter("property", .oneOf(KeyframeProperty.allCases.map(\.rawValue)), "x and y: centre as a fraction of the canvas; scale: 1 is the fitted size; rotation: degrees clockwise; opacity: 0 to 1", required: true),
        Parameter("keyframes", .array(.object), "[{\"time\", \"value\", \"easing\"}]: time in seconds (timeline time unless timeBase is source), easing linear, ease (default) or hold toward the next keyframe", required: true),
        Parameter("timeBase", .oneOf(["timeline", "source"]), "What the times count: timeline (default) or seconds into the source file. Stored as source, so keyframes stay on the same picture through trims, splits and speed changes"),
    ])

    public var clip: EntityID
    public var property: KeyframeProperty
    public var keyframes: [Keyframe]
    public var timeBase: String?

    public init(clip: EntityID, property: KeyframeProperty, keyframes: [Keyframe], timeBase: String? = nil) {
        self.clip = clip
        self.property = property
        self.keyframes = keyframes
        self.timeBase = timeBase
    }

    public mutating func prepare(in p: Project) throws {
        let (ti, ci) = try p.locate(clip: clip)
        let c = p.tracks[ti].clips[ci]
        if timeBase != "source" {
            keyframes = try keyframes.map { k in
                var k = k
                k.time = try sourceTime(k.time, clip: c, project: p, parameter: "keyframes.time")
                return k
            }
            timeBase = "source"
        }
        keyframes.sort { $0.time < $1.time }
    }

    public func apply(to p: inout Project) throws {
        guard timeBase == "source" else { throw EditorError.invalid("stored keyframes must be in source time", parameter: "timeBase") }
        for k in keyframes {
            guard k.value.isFinite else { throw EditorError.invalid("keyframe values must be numbers", parameter: "keyframes") }
            switch property {
            case .scale where k.value <= 0: throw EditorError.invalid("scale must be above 0", parameter: "keyframes")
            case .opacity where k.value < 0 || k.value > 1: throw EditorError.invalid("opacity is 0 to 1", parameter: "keyframes")
            default: break
            }
        }
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where a.time == b.time {
            throw EditorError.invalid("two keyframes at \(a.time.seconds) s (source time)", parameter: "keyframes")
        }
        try p.editClip(clip) { c in
            c.keyframes[property.rawValue] = keyframes.isEmpty ? nil : keyframes
        }
    }
}

public struct RemoveKeyframes: EditorCommand {
    public static let name = "clip.removeKeyframes"
    public static let spec = CommandSpec("Remove a clip's keyframes, for one property or all, optionally only between two times.", [
        Parameter("clip", .id, "Clip id", required: true),
        Parameter("property", .oneOf(KeyframeProperty.allCases.map(\.rawValue)), "Only this property; default all"),
        Parameter("from", .seconds, "Only keyframes at or after this time"),
        Parameter("to", .seconds, "Only keyframes at or before this time"),
        Parameter("timeBase", .oneOf(["timeline", "source"]), "What from and to count: timeline (default) or source seconds"),
    ])

    public var clip: EntityID
    public var property: KeyframeProperty?
    public var from: Time?
    public var to: Time?
    public var timeBase: String?

    public init(clip: EntityID, property: KeyframeProperty? = nil, from: Time? = nil, to: Time? = nil, timeBase: String? = nil) {
        self.clip = clip
        self.property = property
        self.from = from
        self.to = to
        self.timeBase = timeBase
    }

    public mutating func prepare(in p: Project) throws {
        guard timeBase != "source" else { return }
        let (ti, ci) = try p.locate(clip: clip)
        let c = p.tracks[ti].clips[ci]
        if let f = from { from = try sourceTime(f, clip: c, project: p, parameter: "from") }
        if let t = to { to = try sourceTime(t, clip: c, project: p, parameter: "to") }
        timeBase = "source"
    }

    public func apply(to p: inout Project) throws {
        try p.editClip(clip) { c in
            for name in property.map({ [$0.rawValue] }) ?? Array(c.keyframes.keys) {
                guard var ks = c.keyframes[name] else { continue }
                ks.removeAll { k in (from.map { k.time >= $0 } ?? true) && (to.map { k.time <= $0 } ?? true) }
                c.keyframes[name] = ks.isEmpty ? nil : ks
            }
        }
    }
}
