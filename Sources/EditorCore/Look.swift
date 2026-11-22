/// The eight colour bands of the HSL panel, by centre hue in degrees.
public enum HSLBand: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, cyan, blue, purple, magenta

    public var hue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .cyan: 180
        case .blue: 240
        case .purple: 270
        case .magenta: 300
        }
    }
}

/// Hue, saturation and luminance changes for one colour, each -100 to 100.
public struct HSLAdjust: Codable, Equatable, Sendable {
    public var hue: Double = 0
    public var saturation: Double = 0
    public var luminance: Double = 0

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public var isZero: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

/// A colour chosen by the user (for example skin), changed on its own (C-1a).
public struct PickedColor: Codable, Equatable, Sendable, Identifiable {
    public var id: EntityID
    /// "#RRGGBB" as seen in the picture.
    public var color: String
    /// How far in hue, in degrees, the change reaches (5 to 90).
    public var range: Double
    public var adjust: HSLAdjust

    public init(id: EntityID, color: String, range: Double = 25, adjust: HSLAdjust = HSLAdjust()) {
        self.id = id
        self.color = color
        self.range = range
        self.adjust = adjust
    }

    /// Red, green and blue from 0 to 1, or nil when `color` is not #RRGGBB.
    public var rgb: (Double, Double, Double)? {
        var s = color.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// A colour and light setting: the Adjust, White Balance, HSL and Style tabs
/// of the owner's Edits panel (C-1). Stored once in the project and used by
/// clips or whole tracks (C-3).
public struct Look: Codable, Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var name: String
    public var enabled = true

    // Adjust, each -100 to 100
    public var exposure = 0.0
    public var clarity = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var contrast = 0.0
    public var brightness = 0.0
    public var whites = 0.0
    public var blacks = 0.0
    public var saturation = 0.0
    public var vibrance = 0.0
    // White balance, each -100 to 100
    public var temperature = 0.0
    public var tint = 0.0
    // HSL
    public var hsl: [String: HSLAdjust] = [:]
    public var picked: [PickedColor] = []
    // Style, each 0 to 100
    public var sharpen = 0.0
    public var noiseReduction = 0.0
    public var fade = 0.0
    public var vignette = 0.0
    public var grain = 0.0

    public init(id: EntityID, name: String) {
        self.id = id
        self.name = name
    }

    /// Slider names, ranges and tab, in panel order.
    public static let sliders: [(name: String, range: ClosedRange<Double>, tab: String)] = [
        ("exposure", -100...100, "Adjust"), ("clarity", -100...100, "Adjust"), ("highlights", -100...100, "Adjust"),
        ("shadows", -100...100, "Adjust"), ("contrast", -100...100, "Adjust"), ("brightness", -100...100, "Adjust"),
        ("whites", -100...100, "Adjust"), ("blacks", -100...100, "Adjust"), ("saturation", -100...100, "Adjust"),
        ("vibrance", -100...100, "Adjust"),
        ("temperature", -100...100, "White Balance"), ("tint", -100...100, "White Balance"),
        ("sharpen", 0...100, "Style"), ("noiseReduction", 0...100, "Style"), ("fade", 0...100, "Style"),
        ("vignette", 0...100, "Style"), ("grain", 0...100, "Style"),
    ]

    nonisolated(unsafe) public static let sliderPaths: [String: WritableKeyPath<Look, Double>] = [
        "exposure": \.exposure, "clarity": \.clarity, "highlights": \.highlights, "shadows": \.shadows,
        "contrast": \.contrast, "brightness": \.brightness, "whites": \.whites, "blacks": \.blacks,
        "saturation": \.saturation, "vibrance": \.vibrance, "temperature": \.temperature, "tint": \.tint,
        "sharpen": \.sharpen, "noiseReduction": \.noiseReduction, "fade": \.fade, "vignette": \.vignette, "grain": \.grain,
    ]

    public subscript(slider name: String) -> Double {
        get { Self.sliderPaths[name].map { self[keyPath: $0] } ?? 0 }
        set { if let p = Self.sliderPaths[name] { self[keyPath: p] = newValue } }
    }

    public func band(_ b: HSLBand) -> HSLAdjust { hsl[b.rawValue] ?? HSLAdjust() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hsl = try c.decodeIfPresent([String: HSLAdjust].self, forKey: .hsl) ?? [:]
        picked = try c.decodeIfPresent([PickedColor].self, forKey: .picked) ?? []
        let values = try decoder.container(keyedBy: AnyKey.self)
        for (name, path) in Self.sliderPaths {
            self[keyPath: path] = try values.decodeIfPresent(Double.self, forKey: AnyKey(name)) ?? 0
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
