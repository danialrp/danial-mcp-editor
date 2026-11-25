import Foundation

/// A stable identifier such as `clip_3f9a1c2e7b40`. Encoded as a plain string.
public struct EntityID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.raw = value }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    public var description: String { raw }
    public static func < (a: EntityID, b: EntityID) -> Bool { a.raw < b.raw }

    /// A new random identifier with the given prefix.
    public static func random(_ prefix: String) -> EntityID {
        EntityID("\(prefix)_\(randomHex(12))")
    }
}

func randomHex(_ count: Int) -> String {
    var g = SystemRandomNumberGenerator()
    return String((0..<count).map { _ in "0123456789abcdef".randomElement(using: &g)! })
}

/// Makes identifiers for objects a command creates. The seed is chosen once,
/// when the command is prepared, and stored in the journal, so replaying the
/// command after a crash creates the same identifiers again.
public struct IDGenerator: Sendable {
    public let seed: String
    private var counter = 0

    public init(seed: String) { self.seed = seed }

    public mutating func next(_ prefix: String) -> EntityID {
        counter += 1
        return EntityID("\(prefix)_\(seed)_\(counter)")
    }

    public static func newSeed() -> String { randomHex(8) }
}

public enum DynamicRange: String, Codable, Sendable, CaseIterable {
    case sdr   // Rec.709
    case hlg   // Rec.2100 HLG
}

public struct ProjectSettings: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var dynamicRange: DynamicRange

    public init(width: Int, height: Int, frameRate: FrameRate, dynamicRange: DynamicRange) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.dynamicRange = dynamicRange
    }
}

public struct VideoInfo: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var codec: String
    public var bitDepth: Int?
    public var transfer: String?
    public var primaries: String?

    public init(width: Int, height: Int, frameRate: Double, codec: String,
                bitDepth: Int? = nil, transfer: String? = nil, primaries: String? = nil) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.bitDepth = bitDepth
        self.transfer = transfer
        self.primaries = primaries
    }
}

public struct AudioInfo: Codable, Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var codec: String

    public init(sampleRate: Int, channels: Int, codec: String) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.codec = codec
    }
}

/// Properties of a media file, read once on import.
public struct MediaInfo: Codable, Equatable, Sendable {
    public var duration: Time
    public var video: VideoInfo?
    public var audio: AudioInfo?

    public init(duration: Time, video: VideoInfo?, audio: AudioInfo?) {
        self.duration = duration
        self.video = video
        self.audio = audio
    }
}

/// What a media asset is.
public enum MediaKind: String, Codable, Sendable {
    /// A media file, referenced where it is.
    case file
    /// A HyperFrames composition: a folder inside the project package
    /// (`path` is relative to the package), rendered in slices (H-1).
    case hyperframes
    /// A still picture (PNG, JPEG, HEIC...), referenced where it is. Its
    /// clips last as long as they are placed: the source is endless.
    case image
}

/// Where the person matte of a footage file comes from (X-3, phase 8).
public enum MatteSource: String, Codable, Sendable, CaseIterable {
    /// Made inside the editor by Apple Vision person segmentation.
    case vision
    /// Masks made elsewhere (for example SAM 3 in Edits), copied into the
    /// project package under `mattes/<asset id>/`, one PNG per source
    /// millisecond (the file name).
    case imported
}

/// A file in the media pool. The file is referenced where it is, never copied.
public struct MediaAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var path: String
    public var name: String
    /// File size and modification time, used to notice a changed or replaced file.
    public var fingerprint: String
    public var info: MediaInfo
    public var kind: MediaKind
    /// The person matte of this footage, if one is wanted.
    public var matte: MatteSource?

    public init(id: EntityID, path: String, name: String, fingerprint: String, info: MediaInfo, kind: MediaKind = .file,
                matte: MatteSource? = nil) {
        self.id = id
        self.path = path
        self.name = name
        self.fingerprint = fingerprint
        self.info = info
        self.kind = kind
        self.matte = matte
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        info = try c.decode(MediaInfo.self, forKey: .info)
        kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .file
        matte = try c.decodeIfPresent(MatteSource.self, forKey: .matte)
    }

    public var isHyperFrames: Bool { kind == .hyperframes }
    public var isImage: Bool { kind == .image }

    /// How long a still picture's source is: long enough for any clip.
    public static let stillDuration = Time(seconds: 86_400)
    /// A still placed without a length lasts this long.
    public static let stillDefaultSeconds: Double = 5
}

public enum TrackKind: String, Codable, Sendable, CaseIterable {
    /// The camera footage. Deleting on it closes the gap.
    case main
    /// Pictures layered above the main track.
    case overlay
    /// Music, sound effects and other sound.
    case audio
}

/// Where and how a clip's picture sits on the canvas.
public struct Transform: Codable, Equatable, Sendable {
    public enum Fit: String, Codable, Sendable, CaseIterable {
        /// The whole picture is visible; bars where the shapes differ.
        case fit
        /// The canvas is covered; edges are cut where the shapes differ.
        case fill
    }

    /// Centre of the picture, as a fraction of the canvas (0.5, 0.5 is the middle).
    public var x: Double = 0.5
    public var y: Double = 0.5
    /// 1 is the size given by `fit`.
    public var scale: Double = 1
    /// Degrees, clockwise.
    public var rotation: Double = 0
    public var fit: Fit = .fit
    /// Fractions of the source cut from each edge, 0 to 1.
    public var cropLeft: Double = 0
    public var cropTop: Double = 0
    public var cropRight: Double = 0
    public var cropBottom: Double = 0

    public init() {}

    public static let identity = Transform()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Transform()
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? d.x
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? d.y
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? d.rotation
        fit = try c.decodeIfPresent(Fit.self, forKey: .fit) ?? d.fit
        cropLeft = try c.decodeIfPresent(Double.self, forKey: .cropLeft) ?? 0
        cropTop = try c.decodeIfPresent(Double.self, forKey: .cropTop) ?? 0
        cropRight = try c.decodeIfPresent(Double.self, forKey: .cropRight) ?? 0
        cropBottom = try c.decodeIfPresent(Double.self, forKey: .cropBottom) ?? 0
    }
}

/// A piece of a media file placed on a track.
///
/// The timeline range (`start`, `duration`) and the source range
/// (`sourceStart`, `sourceDuration`) are both stored; speed is their ratio.
/// Timeline values are exact on the frame grid; when a clip is split, the
/// source side absorbs any rounding, so the timeline never drifts.
public struct Clip: Codable, Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var asset: EntityID
    public var start: Time
    public var duration: Time
    public var sourceStart: Time
    public var sourceDuration: Time

    // Sound
    public var gainDB: Double = 0
    public var muted: Bool = false
    public var fadeIn: Time = .zero
    public var fadeOut: Time = .zero

    // Picture
    public var transform: Transform = .identity
    public var opacity: Double = 1
    /// Colour look for this clip; nil uses the track's look, if any.
    public var look: EntityID?
    /// Effects in the order they run (architecture section 7).
    public var effects: [EffectInstance] = []
    /// Transform keyframes by property name (`KeyframeProperty`), each list
    /// sorted by source time.
    public var keyframes: [String: [Keyframe]] = [:]

    public init(id: EntityID, asset: EntityID, start: Time, duration: Time,
                sourceStart: Time, sourceDuration: Time) {
        self.id = id
        self.asset = asset
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
    }

    // Fields added after the first format version are optional in files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        asset = try c.decode(EntityID.self, forKey: .asset)
        start = try c.decode(Time.self, forKey: .start)
        duration = try c.decode(Time.self, forKey: .duration)
        sourceStart = try c.decode(Time.self, forKey: .sourceStart)
        sourceDuration = try c.decode(Time.self, forKey: .sourceDuration)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        fadeIn = try c.decodeIfPresent(Time.self, forKey: .fadeIn) ?? .zero
        fadeOut = try c.decodeIfPresent(Time.self, forKey: .fadeOut) ?? .zero
        transform = try c.decodeIfPresent(Transform.self, forKey: .transform) ?? .identity
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        look = try c.decodeIfPresent(EntityID.self, forKey: .look)
        effects = try c.decodeIfPresent([EffectInstance].self, forKey: .effects) ?? []
        keyframes = try c.decodeIfPresent([String: [Keyframe]].self, forKey: .keyframes) ?? [:]
    }

    public var end: Time { start + duration }
    public var sourceEnd: Time { sourceStart + sourceDuration }

    /// Keeps the fades inside the clip: when it gets shorter than its two
    /// fades together (a trim, a cut, a faster speed), both shrink in
    /// proportion.
    public mutating func fitFades() {
        let total = fadeIn.ticks + fadeOut.ticks
        guard total > duration.ticks, total > 0 else { return }
        let inTicks = Int64((Double(fadeIn.ticks) * Double(duration.ticks) / Double(total)).rounded(.down))
        fadeIn = Time(ticks: inTicks)
        fadeOut = Time(ticks: min(fadeOut.ticks, duration.ticks - inTicks))
    }
    /// New ids for the effects of a copy: every id in a project is unique.
    mutating func renewEffectIDs(_ gen: inout IDGenerator) {
        for i in effects.indices { effects[i].id = gen.next("fx") }
    }
    public var range: TimeRange { TimeRange(start: start, duration: duration) }
    public var speed: Double { Double(sourceDuration.ticks) / Double(duration.ticks) }

    /// Source position shown at timeline time `t`.
    public func sourceTime(at t: Time) -> Time {
        let offset = Double((t - start).ticks) * speed
        return sourceStart + Time(ticks: Int64(offset.rounded()))
    }
}

public struct Track: Codable, Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var kind: TrackKind
    public var name: String
    public var muted: Bool
    public var hidden: Bool
    public var locked: Bool
    /// Length of the short sound fade on each side of every cut between two
    /// touching clips. Zero turns it off.
    public var joinFade: Time
    /// Colour look for every clip on the track that has none of its own.
    public var look: EntityID?
    /// Sorted by start time and never overlapping.
    public var clips: [Clip]

    public init(id: EntityID, kind: TrackKind, name: String, muted: Bool = false,
                hidden: Bool = false, locked: Bool = false, joinFade: Time = .zero, clips: [Clip] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.muted = muted
        self.hidden = hidden
        self.locked = locked
        self.joinFade = joinFade
        self.clips = clips
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        kind = try c.decode(TrackKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        joinFade = try c.decodeIfPresent(Time.self, forKey: .joinFade) ?? .zero
        look = try c.decodeIfPresent(EntityID.self, forKey: .look)
        clips = try c.decode([Clip].self, forKey: .clips)
    }

    public var end: Time { clips.last?.end ?? .zero }
}

public struct Marker: Codable, Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var time: Time
    public var name: String

    public init(id: EntityID, time: Time, name: String) {
        self.id = id
        self.time = time
        self.name = name
    }
}

/// One spoken word, at its place in the media file.
public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Time
    public var end: Time

    public init(text: String, start: Time, end: Time) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// The words of a media file (or part of it), in file time. Timeline
/// positions are worked out from the clips, so a transcript follows every cut
/// and speed change without being rewritten (T-4).
public struct Transcript: Codable, Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var asset: EntityID
    public var language: String
    /// Where the words came from, for example "edits" or "import".
    public var engine: String
    public var sourceStart: Time
    public var sourceEnd: Time
    public var words: [TranscriptWord]

    public init(id: EntityID, asset: EntityID, language: String, engine: String,
                sourceStart: Time, sourceEnd: Time, words: [TranscriptWord]) {
        self.id = id
        self.asset = asset
        self.language = language
        self.engine = engine
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.words = words
    }
}

public struct Project: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var id: EntityID
    public var name: String
    public var settings: ProjectSettings
    public var media: [MediaAsset]
    /// From bottom to top: the order in which pictures are layered.
    public var tracks: [Track]
    public var markers: [Marker]
    public var transcripts: [Transcript]
    public var looks: [Look]
    /// The owner's accent colour for motion graphics, when picked.
    public var accent: Accent?

    public init(id: EntityID, name: String, settings: ProjectSettings) {
        self.formatVersion = Self.formatVersion
        self.id = id
        self.name = name
        self.settings = settings
        self.media = []
        self.tracks = []
        self.markers = []
        self.transcripts = []
        self.looks = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        id = try c.decode(EntityID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        settings = try c.decode(ProjectSettings.self, forKey: .settings)
        media = try c.decode([MediaAsset].self, forKey: .media)
        tracks = try c.decode([Track].self, forKey: .tracks)
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        transcripts = try c.decodeIfPresent([Transcript].self, forKey: .transcripts) ?? []
        looks = try c.decodeIfPresent([Look].self, forKey: .looks) ?? []
        accent = try c.decodeIfPresent(Accent.self, forKey: .accent)
    }

    /// The look that applies to a clip: its own, else its track's.
    public func effectiveLook(_ c: Clip, on t: Track) -> Look? {
        guard let id = c.look ?? t.look, let l = looks.first(where: { $0.id == id }), l.enabled else { return nil }
        return l
    }

    /// Words of a transcript at their current timeline places, for the clips
    /// of the given tracks (default: every track). A word is placed when it
    /// lies inside a clip's source range; cut-out words are left out.
    public func timelineWords(_ t: Transcript, tracks only: Set<EntityID>? = nil)
        -> [(word: TranscriptWord, start: Time, end: Time, clip: EntityID, track: EntityID)] {
        var out: [(TranscriptWord, Time, Time, EntityID, EntityID)] = []
        for track in tracks where only?.contains(track.id) ?? true {
            for c in track.clips where c.asset == t.asset {
                var lo = 0, hi = t.words.count
                while lo < hi { let m = (lo + hi) / 2; if t.words[m].start < c.sourceStart { lo = m + 1 } else { hi = m } }
                var i = lo
                while i < t.words.count, t.words[i].start < c.sourceEnd {
                    let w = t.words[i]
                    if w.end <= c.sourceEnd + Time(seconds: 0.02) {
                        let s = c.start + Time(ticks: Int64((Double((w.start - c.sourceStart).ticks) / c.speed).rounded()))
                        let e = c.start + Time(ticks: Int64((Double((Time.min(w.end, c.sourceEnd) - c.sourceStart).ticks) / c.speed).rounded()))
                        out.append((w, s, e, c.id, track.id))
                    }
                    i += 1
                }
            }
        }
        return out.sorted { $0.1 < $1.1 }
    }

    public var duration: Time { tracks.map(\.end).max() ?? .zero }

    /// Refuses a project whose timeline runs past `Time.maxTimelineSeconds`,
    /// checked once after every step.
    public func checkLimits() throws {
        let limit = Time(seconds: Time.maxTimelineSeconds)
        if duration > limit || markers.contains(where: { $0.time > limit }) {
            throw EditorError.invalid("the timeline would run past \(Int(Time.maxTimelineSeconds)) s; use shorter clips, holds or times")
        }
    }

    public func trackIndex(_ id: EntityID) throws -> Int {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else {
            throw EditorError.notFound("track", id)
        }
        return i
    }

    public func asset(_ id: EntityID) throws -> MediaAsset {
        guard let a = media.first(where: { $0.id == id }) else { throw EditorError.notFound("media asset", id) }
        return a
    }

    /// Track index and clip index of a clip.
    public func locate(clip id: EntityID) throws -> (track: Int, clip: Int) {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) { return (t, c) }
        }
        throw EditorError.notFound("clip", id)
    }

    /// The main track, which ripple edits default to.
    public func mainTrackIndex() throws -> Int {
        guard let i = tracks.firstIndex(where: { $0.kind == .main }) else {
            throw EditorError.invalid("the project has no main track")
        }
        return i
    }

    /// Whether any object in the project has this id. A plain scan, no allocation.
    public func containsID(_ x: EntityID) -> Bool {
        if id == x { return true }
        if media.contains(where: { $0.id == x }) || markers.contains(where: { $0.id == x }) || transcripts.contains(where: { $0.id == x }) || looks.contains(where: { $0.id == x || $0.picked.contains { $0.id == x } }) { return true }
        for t in tracks where t.id == x || t.clips.contains(where: { $0.id == x || $0.effects.contains { $0.id == x } }) { return true }
        return false
    }

    public var allIDs: Set<EntityID> {
        var s = Set<EntityID>()
        s.insert(id)
        for m in media { s.insert(m.id) }
        for t in tracks { s.insert(t.id); for c in t.clips { s.insert(c.id); for e in c.effects { s.insert(e.id) } } }
        for m in markers { s.insert(m.id) }
        for t in transcripts { s.insert(t.id) }
        for l in looks { s.insert(l.id); for c in l.picked { s.insert(c.id) } }
        return s
    }
}
