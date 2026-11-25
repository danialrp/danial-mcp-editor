// Commands on project settings, the media pool and markers.

public struct SetProjectSettings: EditorCommand {
    public static let name = "project.setSettings"
    public static let spec = CommandSpec("Change the project name, canvas size, frame rate or dynamic range. Frame rate can only change while the timeline is empty.", [
        Parameter("name", .string, "Project name"),
        Parameter("width", .integer, "Canvas width in pixels, even"),
        Parameter("height", .integer, "Canvas height in pixels, even"),
        Parameter("frameRate", .integer, "Frames per second, for example 30 or 60"),
        Parameter("dynamicRange", .oneOf(DynamicRange.allCases.map(\.rawValue)), "sdr (Rec.709) or hlg (Rec.2100 HLG)"),
    ])

    public var name: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Int?
    public var dynamicRange: DynamicRange?

    public init(name: String? = nil, width: Int? = nil, height: Int? = nil, frameRate: Int? = nil, dynamicRange: DynamicRange? = nil) {
        self.name = name
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.dynamicRange = dynamicRange
    }

    public func apply(to p: inout Project) throws {
        if let name { p.name = name }
        for (v, key) in [(width, "width"), (height, "height")] {
            if let v, v <= 0 || v % 2 != 0 || v > 16384 {
                throw EditorError.invalid("\(key) must be an even number of pixels between 2 and 16384", parameter: key)
            }
        }
        if let width { p.settings.width = width }
        if let height { p.settings.height = height }
        if let frameRate {
            guard let r = FrameRate(fps: frameRate) else {
                throw EditorError.invalid("frame rate \(frameRate) is not supported", parameter: "frameRate")
            }
            if r != p.settings.frameRate, p.tracks.contains(where: { !$0.clips.isEmpty }) {
                throw EditorError.invalid("frame rate can only change while the timeline is empty", parameter: "frameRate")
            }
            p.settings.frameRate = r
        }
        if let dynamicRange { p.settings.dynamicRange = dynamicRange }
    }
}

/// Adds probed files to the media pool. Created by the `media.import` tool.
public struct AddMedia: EditorCommand {
    public static let name = "media.add"
    public static let spec = CommandSpec("Add already probed files to the media pool.", exposedAsTool: false)

    public var assets: [MediaAsset]

    public init(assets: [MediaAsset]) { self.assets = assets }

    public func apply(to p: inout Project) throws {
        var known = Set(p.media.map(\.id))
        for a in assets {
            guard known.insert(a.id).inserted else { throw EditorError(.conflict, "media id \(a.id) already exists") }
            p.media.append(a)
        }
    }
}

/// Points an asset at another file. Created by the `media.relink` tool.
public struct SetMediaPath: EditorCommand {
    public static let name = "media.setPath"
    public static let spec = CommandSpec("Point a media asset at another file.", exposedAsTool: false)

    public var id: EntityID
    public var path: String
    public var name: String
    public var fingerprint: String
    public var info: MediaInfo

    public init(id: EntityID, path: String, name: String, fingerprint: String, info: MediaInfo) {
        self.id = id
        self.path = path
        self.name = name
        self.fingerprint = fingerprint
        self.info = info
    }

    public func apply(to p: inout Project) throws {
        guard let i = p.media.firstIndex(where: { $0.id == id }) else { throw EditorError.notFound("media asset", id) }
        var relinked = p.media[i]
        relinked.info = info
        for t in p.tracks {
            for c in t.clips where c.asset == id {
                if c.sourceEnd > info.duration {
                    throw EditorError(.conflict, "the new file is shorter than clip \(c.id) needs (\(c.sourceEnd.seconds) s)")
                }
                do { try p.checkAsset(relinked, fits: t.kind) } catch let e as EditorError {
                    throw EditorError(.conflict, "the new file cannot serve clip \(c.id) on track \(t.id): \(e.message)")
                }
            }
        }
        p.media[i].path = path
        p.media[i].name = name
        p.media[i].fingerprint = fingerprint
        p.media[i].info = info
    }
}

public struct SetMediaMatte: EditorCommand {
    public static let name = "media.setMatte"
    public static let spec = CommandSpec("Turn the person matte of a footage file on or off and choose where it comes from: vision (made in the editor) or imported (masks copied in by matte.import). Clips of the file then hide whatever a depth composition puts behind the person.", [
        Parameter("id", .id, "Media asset id", required: true),
        Parameter("source", .oneOf(["none"] + MatteSource.allCases.map(\.rawValue)), "none, vision or imported", required: true),
    ])

    public var id: EntityID
    public var source: String

    public init(id: EntityID, source: String) {
        self.id = id
        self.source = source
    }

    public func apply(to p: inout Project) throws {
        guard let i = p.media.firstIndex(where: { $0.id == id }) else { throw EditorError.notFound("media asset", id) }
        guard p.media[i].kind == .file, p.media[i].info.video != nil else {
            throw EditorError.invalid("media \(id) has no camera picture; a matte is made for footage files", parameter: "id")
        }
        if source == "none" { p.media[i].matte = nil; return }
        guard let s = MatteSource(rawValue: source) else {
            throw EditorError.invalid("source is none, vision or imported", parameter: "source")
        }
        p.media[i].matte = s
    }
}

public struct RemoveMedia: EditorCommand {
    public static let name = "media.remove"
    public static let spec = CommandSpec("Remove media assets that no clip uses, with their transcripts. The files are not touched.", [
        Parameter("ids", .array(.id), "Media asset ids", required: true),
    ])

    public var ids: [EntityID]

    public init(ids: [EntityID]) { self.ids = ids }

    public func apply(to p: inout Project) throws {
        let set = Set(ids)
        for id in set where !p.media.contains(where: { $0.id == id }) { throw EditorError.notFound("media asset", id) }
        for t in p.tracks {
            if let c = t.clips.first(where: { set.contains($0.asset) }) {
                throw EditorError(.conflict, "media \(c.asset) is used by clip \(c.id); remove the clips first")
            }
        }
        p.media.removeAll { set.contains($0.id) }
        p.transcripts.removeAll { set.contains($0.asset) }
    }
}

public struct AddMarker: EditorCommand {
    public static let name = "marker.add"
    public static let spec = CommandSpec("Add a marker on the timeline.", [
        Parameter("time", .seconds, "Timeline time", required: true),
        Parameter("name", .string, "Marker text"),
        Parameter("id", .id, "Id for the new marker; one is made if omitted"),
    ])

    public var time: Time
    public var name: String?
    public var id: EntityID?

    public init(time: Time, name: String? = nil, id: EntityID? = nil) {
        self.time = time
        self.name = name
        self.id = id
    }

    public mutating func prepare(in p: Project) throws {
        time = try p.snap(time, "time")
        if let id { try requireUnusedID(id, in: p) } else { id = .random("marker") }
    }

    public func apply(to p: inout Project) throws {
        let m = Marker(id: id!, time: time, name: name ?? "")
        let i = p.markers.firstIndex { $0.time > time } ?? p.markers.count
        p.markers.insert(m, at: i)
    }
}

public struct RemoveMarkers: EditorCommand {
    public static let name = "marker.remove"
    public static let spec = CommandSpec("Remove markers.", [
        Parameter("ids", .array(.id), "Marker ids", required: true),
    ])

    public var ids: [EntityID]

    public init(ids: [EntityID]) { self.ids = ids }

    public func apply(to p: inout Project) throws {
        let set = Set(ids)
        for id in set where !p.markers.contains(where: { $0.id == id }) { throw EditorError.notFound("marker", id) }
        p.markers.removeAll { set.contains($0.id) }
    }
}

/// Fails when a caller-chosen id is already taken.
func requireUnusedID(_ id: EntityID, in p: Project) throws {
    guard !id.raw.isEmpty else { throw EditorError.invalid("id must not be empty", parameter: "id") }
    if p.containsID(id) { throw EditorError(.conflict, "id \(id) is already used", parameter: "id") }
}
