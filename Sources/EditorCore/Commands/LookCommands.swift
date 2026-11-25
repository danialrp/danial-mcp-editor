// Commands for colour looks (requirements C-1 to C-3).

private func sliderParameters() -> [Parameter] {
    Look.sliders.map { s in
        Parameter(s.name, .number, "\(s.tab): \(Int(s.range.lowerBound)) to \(Int(s.range.upperBound)), 0 leaves the picture as it is")
    }
}

private let hslParameter = Parameter("hsl", .object,
    "HSL changes per band, for example {\"orange\": {\"saturation\": -10, \"luminance\": 5}}. Bands: \(HSLBand.allCases.map(\.rawValue).joined(separator: ", ")); values hue, saturation, luminance from -100 to 100. Omitted values stay as they are.")

/// The slider values a create or update command carries.
private protocol LookValues {
    var exposure: Double? { get }
    var clarity: Double? { get }
    var highlights: Double? { get }
    var shadows: Double? { get }
    var contrast: Double? { get }
    var brightness: Double? { get }
    var whites: Double? { get }
    var blacks: Double? { get }
    var saturation: Double? { get }
    var vibrance: Double? { get }
    var temperature: Double? { get }
    var tint: Double? { get }
    var sharpen: Double? { get }
    var noiseReduction: Double? { get }
    var fade: Double? { get }
    var vignette: Double? { get }
    var grain: Double? { get }
    var hsl: [String: PartialHSL]? { get }
}

public struct PartialHSL: Codable, Equatable, Sendable {
    public var hue: Double?
    public var saturation: Double?
    public var luminance: Double?
}

extension LookValues {
    func write(into l: inout Look) throws {
        let given: [(String, Double?)] = [
            ("exposure", exposure), ("clarity", clarity), ("highlights", highlights), ("shadows", shadows),
            ("contrast", contrast), ("brightness", brightness), ("whites", whites), ("blacks", blacks),
            ("saturation", saturation), ("vibrance", vibrance), ("temperature", temperature), ("tint", tint),
            ("sharpen", sharpen), ("noiseReduction", noiseReduction), ("fade", fade), ("vignette", vignette), ("grain", grain),
        ]
        for (name, value) in given {
            guard let value else { continue }
            let range = Look.sliders.first { $0.name == name }!.range
            guard range.contains(value) else {
                throw EditorError.invalid("\(name) must be between \(Int(range.lowerBound)) and \(Int(range.upperBound))", parameter: name)
            }
            l[slider: name] = value
        }
        for (band, change) in hsl ?? [:] {
            guard HSLBand(rawValue: band) != nil else {
                throw EditorError.invalid("no HSL band \(band); bands are \(HSLBand.allCases.map(\.rawValue).joined(separator: ", "))", parameter: "hsl")
            }
            var b = l.hsl[band] ?? HSLAdjust()
            for (v, key) in [(change.hue, "hue"), (change.saturation, "saturation"), (change.luminance, "luminance")] {
                if let v, !(-100...100).contains(v) { throw EditorError.invalid("hsl.\(band).\(key) must be between -100 and 100", parameter: "hsl") }
            }
            if let v = change.hue { b.hue = v }
            if let v = change.saturation { b.saturation = v }
            if let v = change.luminance { b.luminance = v }
            l.hsl[band] = b.isZero ? nil : b
        }
    }
}

extension Project {
    func lookIndex(_ id: EntityID) throws -> Int {
        guard let i = looks.firstIndex(where: { $0.id == id }) else { throw EditorError.notFound("look", id) }
        return i
    }
}

public struct CreateLook: EditorCommand, LookValues {
    public static let name = "look.create"
    public static let spec = CommandSpec("Create a colour look with any starting values. It changes nothing until assigned to clips or tracks.", [
        Parameter("name", .string, "Look name"),
        Parameter("id", .id, "Id for the new look; one is made if omitted"),
    ] + sliderParameters() + [hslParameter])

    public var name: String?
    public var id: EntityID?
    public var exposure, clarity, highlights, shadows, contrast, brightness, whites, blacks, saturation, vibrance: Double?
    public var temperature, tint: Double?
    public var sharpen, noiseReduction, fade, vignette, grain: Double?
    public var hsl: [String: PartialHSL]?

    public init(name: String? = nil, id: EntityID? = nil) {
        self.name = name
        self.id = id
    }

    public mutating func prepare(in p: Project) throws {
        if let id { try requireUnusedID(id, in: p) } else { id = .random("look") }
    }

    public func apply(to p: inout Project) throws {
        var l = Look(id: id!, name: name ?? "Look \(p.looks.count + 1)")
        try write(into: &l)
        p.looks.append(l)
    }
}

public struct UpdateLook: EditorCommand, LookValues {
    public static let name = "look.update"
    public static let spec = CommandSpec("Change a look's values; every clip and track using it changes with it. Omitted values stay as they are.", [
        Parameter("id", .id, "Look id", required: true),
        Parameter("name", .string, "New name"),
        Parameter("enabled", .boolean, "Switch the whole look on or off"),
    ] + sliderParameters() + [hslParameter])

    public var id: EntityID
    public var name: String?
    public var enabled: Bool?
    public var exposure, clarity, highlights, shadows, contrast, brightness, whites, blacks, saturation, vibrance: Double?
    public var temperature, tint: Double?
    public var sharpen, noiseReduction, fade, vignette, grain: Double?
    public var hsl: [String: PartialHSL]?

    public init(id: EntityID) { self.id = id }

    public func apply(to p: inout Project) throws {
        let i = try p.lookIndex(id)
        var l = p.looks[i]
        if let name { l.name = name }
        if let enabled { l.enabled = enabled }
        try write(into: &l)
        p.looks[i] = l
    }
}

/// Puts a whole look into the project at once, for example from a saved
/// profile. Created by `look.loadProfile`.
public struct PutLook: EditorCommand {
    public static let name = "look.put"
    public static let spec = CommandSpec("Add a complete look to the project.", exposedAsTool: false)

    public var look: Look

    public init(look: Look) { self.look = look }

    public func apply(to p: inout Project) throws {
        if p.looks.contains(where: { $0.id == look.id }) { throw EditorError(.conflict, "look id \(look.id) already exists") }
        try requireUnusedID(look.id, in: p)
        // A profile is a file that may have been edited by hand: the same
        // rules as for the sliders and colours set one by one.
        for s in Look.sliders where !s.range.contains(look[slider: s.name]) {
            throw EditorError.invalid("\(s.name) must be between \(Int(s.range.lowerBound)) and \(Int(s.range.upperBound))", parameter: s.name)
        }
        for (band, b) in look.hsl {
            guard HSLBand(rawValue: band) != nil else {
                throw EditorError.invalid("no HSL band \(band); bands are \(HSLBand.allCases.map(\.rawValue).joined(separator: ", "))", parameter: "hsl")
            }
            for v in [b.hue, b.saturation, b.luminance] where !(-100...100).contains(v) {
                throw EditorError.invalid("hsl.\(band) values must be between -100 and 100", parameter: "hsl")
            }
        }
        guard look.picked.count <= 4 else { throw EditorError.invalid("a look holds at most 4 picked colours") }
        var seen = Set<EntityID>()
        for c in look.picked {
            try validate(c)
            guard seen.insert(c.id).inserted else { throw EditorError(.conflict, "picked colour id \(c.id) appears twice", parameter: "id") }
            try requireUnusedID(c.id, in: p)
        }
        p.looks.append(look)
    }
}

public struct AssignLook: EditorCommand {
    public static let name = "look.assign"
    public static let spec = CommandSpec("Use a look on clips or whole tracks, or clear it (omit look). A clip's own look wins over its track's. Graphics tracks are left alone unless named.", [
        Parameter("look", .id, "Look id; omit to remove looks from the given clips or tracks"),
        Parameter("clips", .array(.id), "Clip ids"),
        Parameter("tracks", .array(.id), "Track ids"),
    ])

    public var look: EntityID?
    public var clips: [EntityID]?
    public var tracks: [EntityID]?

    public init(look: EntityID?, clips: [EntityID]? = nil, tracks: [EntityID]? = nil) {
        self.look = look
        self.clips = clips
        self.tracks = tracks
    }

    public func apply(to p: inout Project) throws {
        if let look { _ = try p.lookIndex(look) }
        guard !(clips ?? []).isEmpty || !(tracks ?? []).isEmpty else {
            throw EditorError.invalid("give clips or tracks")
        }
        for id in tracks ?? [] {
            let ti = try p.trackIndex(id)
            guard p.tracks[ti].kind != .audio else { throw EditorError.invalid("track \(id) has no picture") }
            p.tracks[ti].look = look
        }
        for id in clips ?? [] {
            let (ti, ci) = try p.locate(clip: id)
            guard p.tracks[ti].kind != .audio else { throw EditorError.invalid("clip \(id) has no picture") }
            p.tracks[ti].clips[ci].look = look
        }
    }
}

public struct RemoveLook: EditorCommand {
    public static let name = "look.remove"
    public static let spec = CommandSpec("Delete a look from the project; clips and tracks using it go back to no look.", [
        Parameter("id", .id, "Look id", required: true),
    ])

    public var id: EntityID

    public init(id: EntityID) { self.id = id }

    public func apply(to p: inout Project) throws {
        let i = try p.lookIndex(id)
        p.looks.remove(at: i)
        for t in p.tracks.indices {
            if p.tracks[t].look == id { p.tracks[t].look = nil }
            for c in p.tracks[t].clips.indices where p.tracks[t].clips[c].look == id { p.tracks[t].clips[c].look = nil }
        }
    }
}

public struct AddPickedColor: EditorCommand {
    public static let name = "look.addPickedColor"
    public static let spec = CommandSpec("Add a custom HSL colour to a look (for example skin or eyes) and change only that colour.", [
        Parameter("look", .id, "Look id", required: true),
        Parameter("color", .string, "The colour as #RRGGBB, for example from color.sample", required: true),
        Parameter("range", .number, "How far in hue the change reaches, 5 to 90 degrees; default 25"),
        Parameter("hue", .number, "-100 to 100"),
        Parameter("saturation", .number, "-100 to 100"),
        Parameter("luminance", .number, "-100 to 100"),
        Parameter("id", .id, "Id for the colour; one is made if omitted"),
    ])

    public var look: EntityID
    public var color: String
    public var range: Double?
    public var hue, saturation, luminance: Double?
    public var id: EntityID?

    public init(look: EntityID, color: String) {
        self.look = look
        self.color = color
    }

    public mutating func prepare(in p: Project) throws {
        if let id { try requireUnusedID(id, in: p) } else { id = .random("color") }
    }

    public func apply(to p: inout Project) throws {
        let i = try p.lookIndex(look)
        let c = PickedColor(id: id!, color: color, range: range ?? 25,
                            adjust: HSLAdjust(hue: hue ?? 0, saturation: saturation ?? 0, luminance: luminance ?? 0))
        try validate(c)
        guard p.looks[i].picked.count < 4 else { throw EditorError.invalid("a look holds at most 4 picked colours") }
        p.looks[i].picked.append(c)
    }
}

public struct UpdatePickedColor: EditorCommand {
    public static let name = "look.updatePickedColor"
    public static let spec = CommandSpec("Change a picked colour or how it is adjusted.", [
        Parameter("look", .id, "Look id", required: true),
        Parameter("id", .id, "Picked colour id", required: true),
        Parameter("color", .string, "#RRGGBB"),
        Parameter("range", .number, "5 to 90 degrees"),
        Parameter("hue", .number, "-100 to 100"),
        Parameter("saturation", .number, "-100 to 100"),
        Parameter("luminance", .number, "-100 to 100"),
    ])

    public var look: EntityID
    public var id: EntityID
    public var color: String?
    public var range, hue, saturation, luminance: Double?

    public init(look: EntityID, id: EntityID) {
        self.look = look
        self.id = id
    }

    public func apply(to p: inout Project) throws {
        let i = try p.lookIndex(look)
        guard let k = p.looks[i].picked.firstIndex(where: { $0.id == id }) else { throw EditorError.notFound("picked colour", id) }
        var c = p.looks[i].picked[k]
        if let color { c.color = color }
        if let range { c.range = range }
        if let hue { c.adjust.hue = hue }
        if let saturation { c.adjust.saturation = saturation }
        if let luminance { c.adjust.luminance = luminance }
        try validate(c)
        p.looks[i].picked[k] = c
    }
}

public struct RemovePickedColor: EditorCommand {
    public static let name = "look.removePickedColor"
    public static let spec = CommandSpec("Remove a picked colour from a look.", [
        Parameter("look", .id, "Look id", required: true),
        Parameter("id", .id, "Picked colour id", required: true),
    ])

    public var look: EntityID
    public var id: EntityID

    public init(look: EntityID, id: EntityID) {
        self.look = look
        self.id = id
    }

    public func apply(to p: inout Project) throws {
        let i = try p.lookIndex(look)
        guard p.looks[i].picked.contains(where: { $0.id == id }) else { throw EditorError.notFound("picked colour", id) }
        p.looks[i].picked.removeAll { $0.id == id }
    }
}

private func validate(_ c: PickedColor) throws {
    guard c.rgb != nil else { throw EditorError.invalid("color must be #RRGGBB", parameter: "color") }
    guard (5...90).contains(c.range) else { throw EditorError.invalid("range must be 5 to 90 degrees", parameter: "range") }
    for (v, k) in [(c.adjust.hue, "hue"), (c.adjust.saturation, "saturation"), (c.adjust.luminance, "luminance")] where !(-100...100).contains(v) {
        throw EditorError.invalid("\(k) must be between -100 and 100", parameter: k)
    }
}
