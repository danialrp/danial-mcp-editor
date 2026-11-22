import Foundation

// MARK: effects

/// When an effect runs on its clip (architecture section 7).
public enum EffectKind: String, Codable, Sendable, CaseIterable {
    /// For the whole clip.
    case filter
    /// At the clip start, driven by a progress value from 0 to 1 over its duration.
    case `in`
    /// At the clip end, progress 0 to 1 over its duration, ending with the clip.
    case out
}

/// One use of an effect plug-in on a clip. Parameters are stored in full when
/// the effect is added, so the picture does not change if a plug-in's
/// defaults change later.
public struct EffectInstance: Codable, Equatable, Sendable, Identifiable {
    public var id: EntityID
    /// Plug-in id, for example `blur.gaussian`.
    public var effect: String
    public var kind: EffectKind
    public var enabled: Bool
    public var params: [String: Double]
    /// Length of an `in` or `out` effect on the timeline; nil for filters.
    public var duration: Time?

    public init(id: EntityID, effect: String, kind: EffectKind, enabled: Bool = true,
                params: [String: Double] = [:], duration: Time? = nil) {
        self.id = id
        self.effect = effect
        self.kind = kind
        self.enabled = enabled
        self.params = params
        self.duration = duration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        effect = try c.decode(String.self, forKey: .effect)
        kind = try c.decodeIfPresent(EffectKind.self, forKey: .kind) ?? .filter
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        params = try c.decodeIfPresent([String: Double].self, forKey: .params) ?? [:]
        duration = try c.decodeIfPresent(Time.self, forKey: .duration)
    }

    /// Progress of an `in` or `out` effect at `offset` into a clip of length
    /// `clipDuration`: nil when it does not run at that moment. Filters run
    /// with progress set to how far into the clip `offset` is.
    public func progress(at offset: Time, clipDuration: Time) -> Double? {
        let len = max(1, clipDuration.ticks)
        switch kind {
        case .filter:
            return min(1, max(0, Double(offset.ticks) / Double(len)))
        case .in:
            let d = min(len, max(1, duration?.ticks ?? 0))
            guard offset.ticks < d else { return nil }
            return Double(max(0, offset.ticks)) / Double(d)
        case .out:
            let d = min(len, max(1, duration?.ticks ?? 0))
            let from = len - d
            guard offset.ticks >= from else { return nil }
            return min(1, Double(offset.ticks - from) / Double(d))
        }
    }
}

// MARK: effect plug-in manifests

/// A control an effect offers; generates both the MCP schema and the inspector.
public struct EffectParameter: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case number, boolean, choice }

    public var name: String
    public var label: String?
    public var summary: String?
    public var type: Kind
    public var min: Double?
    public var max: Double?
    public var `default`: Double?
    /// For `choice`: the names, stored as their index.
    public var choices: [String]?
    public var unit: String?

    public var defaultValue: Double {
        if let d = `default` { return d }
        switch type {
        case .number: return min ?? 0
        case .boolean, .choice: return 0
        }
    }

    /// The value as stored, or an error that says what to send instead.
    public func check(_ v: Double) throws -> Double {
        guard v.isFinite else { throw EditorError.invalid("\(name) must be a number", parameter: name) }
        switch type {
        case .number:
            if let lo = min, v < lo { throw EditorError.invalid("\(name) must be at least \(lo)", parameter: name) }
            if let hi = max, v > hi { throw EditorError.invalid("\(name) must be at most \(hi)", parameter: name) }
            return v
        case .boolean:
            guard v == 0 || v == 1 else { throw EditorError.invalid("\(name) is true or false", parameter: name) }
            return v
        case .choice:
            let n = choices?.count ?? 0
            guard v == v.rounded(), v >= 0, Int(v) < n else {
                throw EditorError.invalid("\(name) is one of \((choices ?? []).joined(separator: ", "))", parameter: name)
            }
            return v
        }
    }
}

/// `manifest.json` of an effect plug-in folder.
public struct EffectManifest: Codable, Equatable, Sendable {
    public struct Duration: Codable, Equatable, Sendable {
        public var `default`: Double
        public var min: Double?
        public var max: Double?
    }

    public var id: String
    public var name: String
    public var summary: String?
    public var kind: EffectKind
    /// Fragment functions in `effect.metal`, run one after another.
    public var passes: [String]
    public var parameters: [EffectParameter]
    /// Default and limits, in seconds, for `in` and `out` effects.
    public var duration: Duration?
    /// The GPU builds mipmaps of each pass's input, for wide blurs.
    public var mipmaps: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        kind = try c.decodeIfPresent(EffectKind.self, forKey: .kind) ?? .filter
        passes = try c.decode([String].self, forKey: .passes)
        parameters = try c.decodeIfPresent([EffectParameter].self, forKey: .parameters) ?? []
        duration = try c.decodeIfPresent(Duration.self, forKey: .duration)
        mipmaps = try c.decodeIfPresent(Bool.self, forKey: .mipmaps)
    }

    /// Problems that make the manifest unusable, worded for whoever wrote it.
    public func problems() -> [String] {
        var out: [String] = []
        if id.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) == nil {
            out.append("id \"\(id)\" must be lower-case letters, digits, dots, dashes or underscores")
        }
        if passes.isEmpty { out.append("passes must name at least one fragment function") }
        if parameters.count > 16 { out.append("at most 16 parameters") }
        if Set(parameters.map(\.name)).count != parameters.count { out.append("parameter names repeat") }
        for p in parameters {
            if p.type == .choice, (p.choices ?? []).isEmpty { out.append("choice parameter \(p.name) needs choices") }
            if let lo = p.min, let hi = p.max, lo > hi { out.append("parameter \(p.name): min is above max") }
        }
        if kind != .filter, duration == nil { out.append("\(kind.rawValue) effects need a duration {default, min, max}") }
        return out
    }

    /// Full stored parameters: defaults, overridden by `given`, all checked.
    public func resolve(_ given: [String: Double], over base: [String: Double]? = nil) throws -> [String: Double] {
        let known = Set(parameters.map(\.name))
        if let bad = given.keys.first(where: { !known.contains($0) }) {
            throw EditorError.invalid("\(id) has no parameter \(bad); it has \(parameters.map(\.name).joined(separator: ", "))", parameter: bad)
        }
        var out: [String: Double] = [:]
        for p in parameters { out[p.name] = try p.check(given[p.name] ?? base?[p.name] ?? p.defaultValue) }
        return out
    }

    public func checkDuration(_ seconds: Double?) throws -> Time? {
        guard kind != .filter else {
            if seconds != nil { throw EditorError.invalid("\(id) runs for the whole clip and takes no duration", parameter: "duration") }
            return nil
        }
        let d = duration!
        let s = seconds ?? d.default
        if s <= 0 || (d.min.map { s < $0 } ?? false) || (d.max.map { s > $0 } ?? false) {
            throw EditorError.invalid("duration of \(id) must be between \(d.min ?? 0) and \(d.max ?? 3600) seconds", parameter: "duration")
        }
        return Time(seconds: s)
    }
}

// MARK: keyframes

/// A transform property that keyframes can animate (E-7).
public enum KeyframeProperty: String, Codable, Sendable, CaseIterable {
    case x, y, scale, rotation, opacity
}

public struct Keyframe: Codable, Equatable, Sendable {
    public enum Easing: String, Codable, Sendable, CaseIterable {
        /// Straight line to the next keyframe.
        case linear
        /// Slow at both ends.
        case ease
        /// Keeps this value until the next keyframe.
        case hold
    }

    /// Position in the clip's source file, so a keyframe stays on the same
    /// picture through trims, splits and speed changes.
    public var time: Time
    public var value: Double
    /// How the value moves from this keyframe to the next.
    public var easing: Easing

    public init(time: Time, value: Double, easing: Easing = .ease) {
        self.time = time
        self.value = value
        self.easing = easing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Time.self, forKey: .time)
        value = try c.decode(Double.self, forKey: .value)
        easing = try c.decodeIfPresent(Easing.self, forKey: .easing) ?? .ease
    }

    /// Value of sorted keyframes `ks` at source time `t`.
    public static func value(_ ks: [Keyframe], at t: Time) -> Double? {
        guard let first = ks.first else { return nil }
        if t <= first.time { return first.value }
        guard let last = ks.last, t < last.time else { return ks.last!.value }
        // Last keyframe at or before t.
        var lo = 0, hi = ks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ks[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        let a = ks[lo], b = ks[lo + 1]
        let f = Double((t - a.time).ticks) / Double(max(1, (b.time - a.time).ticks))
        let e: Double = switch a.easing {
        case .linear: f
        case .ease: f * f * (3 - 2 * f)
        case .hold: 0
        }
        return a.value + (b.value - a.value) * e
    }
}

extension Clip {
    /// Transform and opacity at timeline time `t`, with keyframes applied.
    public func animated(at t: Time) -> (transform: Transform, opacity: Double) {
        var tr = transform, op = opacity
        guard !keyframes.isEmpty else { return (tr, op) }
        let s = sourceTime(at: t)
        for (name, ks) in keyframes {
            guard let p = KeyframeProperty(rawValue: name), let v = Keyframe.value(ks, at: s) else { continue }
            switch p {
            case .x: tr.x = v
            case .y: tr.y = v
            case .scale: tr.scale = v
            case .rotation: tr.rotation = v
            case .opacity: op = min(1, max(0, v))
            }
        }
        return (tr, op)
    }
}
