public struct AddTrack: EditorCommand {
    public static let name = "track.add"
    public static let spec = CommandSpec("Add a track. A project has at most one main track.", [
        Parameter("kind", .oneOf(TrackKind.allCases.map(\.rawValue)), "main, overlay or audio", required: true),
        Parameter("name", .string, "Track name"),
        Parameter("index", .integer, "Position from the bottom; default is the top"),
        Parameter("id", .id, "Id for the new track; one is made if omitted"),
    ])

    public var kind: TrackKind
    public var name: String?
    public var index: Int?
    public var id: EntityID?

    public init(kind: TrackKind, name: String? = nil, index: Int? = nil, id: EntityID? = nil) {
        self.kind = kind
        self.name = name
        self.index = index
        self.id = id
    }

    public mutating func prepare(in p: Project) throws {
        if let id { try requireUnusedID(id, in: p) } else { id = .random("track") }
    }

    public func apply(to p: inout Project) throws {
        if kind == .main, p.tracks.contains(where: { $0.kind == .main }) {
            throw EditorError(.conflict, "the project already has a main track")
        }
        let i = index ?? p.tracks.count
        guard (0...p.tracks.count).contains(i) else {
            throw EditorError.invalid("index must be between 0 and \(p.tracks.count)", parameter: "index")
        }
        let n = p.tracks.filter { $0.kind == kind }.count + 1
        p.tracks.insert(Track(id: id!, kind: kind, name: name ?? "\(kind.rawValue.capitalized) \(n)"), at: i)
    }
}

public struct RemoveTrack: EditorCommand {
    public static let name = "track.remove"
    public static let spec = CommandSpec("Remove a track. A track with clips is removed only with force.", [
        Parameter("id", .id, "Track id", required: true),
        Parameter("force", .boolean, "Also remove the track's clips"),
    ])

    public var id: EntityID
    public var force: Bool?

    public init(id: EntityID, force: Bool? = nil) {
        self.id = id
        self.force = force
    }

    public func apply(to p: inout Project) throws {
        let i = try p.trackIndex(id)
        try p.tracks[i].ensureUnlocked()
        if !p.tracks[i].clips.isEmpty, force != true {
            throw EditorError(.conflict, "track \(id) has \(p.tracks[i].clips.count) clips; pass force to remove them too")
        }
        p.tracks.remove(at: i)
    }
}

public struct ReorderTrack: EditorCommand {
    public static let name = "track.reorder"
    public static let spec = CommandSpec("Move a track to another position, counted from the bottom.", [
        Parameter("id", .id, "Track id", required: true),
        Parameter("index", .integer, "New position from the bottom", required: true),
    ])

    public var id: EntityID
    public var index: Int

    public init(id: EntityID, index: Int) {
        self.id = id
        self.index = index
    }

    public func apply(to p: inout Project) throws {
        let i = try p.trackIndex(id)
        guard p.tracks.indices.contains(index) else {
            throw EditorError.invalid("index must be between 0 and \(p.tracks.count - 1)", parameter: "index")
        }
        let t = p.tracks.remove(at: i)
        p.tracks.insert(t, at: index)
    }
}

public struct SetTrack: EditorCommand {
    public static let name = "track.set"
    public static let spec = CommandSpec("Rename, mute, hide, lock or unlock a track.", [
        Parameter("id", .id, "Track id", required: true),
        Parameter("name", .string, "New name"),
        Parameter("muted", .boolean, "Silence the track"),
        Parameter("hidden", .boolean, "Hide the track's pictures"),
        Parameter("locked", .boolean, "Refuse edits to the track"),
    ])

    public var id: EntityID
    public var name: String?
    public var muted: Bool?
    public var hidden: Bool?
    public var locked: Bool?

    public init(id: EntityID, name: String? = nil, muted: Bool? = nil, hidden: Bool? = nil, locked: Bool? = nil) {
        self.id = id
        self.name = name
        self.muted = muted
        self.hidden = hidden
        self.locked = locked
    }

    public func apply(to p: inout Project) throws {
        let i = try p.trackIndex(id)
        if let name { p.tracks[i].name = name }
        if let muted { p.tracks[i].muted = muted }
        if let hidden { p.tracks[i].hidden = hidden }
        if let locked { p.tracks[i].locked = locked }
    }
}
