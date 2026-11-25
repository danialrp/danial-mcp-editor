import Foundation

/// The owner's accent colour for motion graphics (the hyperframes skill's
/// colour gate, made native): a solid colour, a two-stop gradient or three
/// free colours for the cinematic scenes, picked by the owner on his own
/// frames. The values derived from it (ink, light variant, contrast) follow
/// the skill's picker exactly.
public struct Accent: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case solid, gradient, three }

    public var mode: Mode
    /// "#RRGGBB"; one for solid, two for a gradient, three for three colours.
    public var stops: [String]
    /// Gradient angle in degrees (CSS linear-gradient).
    public var angle: Double
    /// `--acc-hi` is the first stop mixed this far towards white (30 to 95),
    /// unless the owner picked it by hand.
    public var hiPercent: Double
    /// `--acc-hi` picked by hand; nil mixes it from the first stop.
    public var hiColor: String?

    public init(mode: Mode, stops: [String], angle: Double = 135, hiPercent: Double = 72, hiColor: String? = nil) {
        self.mode = mode
        self.stops = stops
        self.angle = angle
        self.hiPercent = hiPercent
        self.hiColor = hiColor
    }

    public static let dark = "#0A0A12", white = "#FFFFFF", glass = "#0C0D14"

    /// How many stops a mode uses.
    public static func count(_ m: Mode) -> Int { m == .three ? 3 : m == .gradient ? 2 : 1 }

    /// The stops in use: one for solid, two for a gradient, three for three colours.
    public var used: [String] { Array(stops.prefix(Self.count(mode))) }
    public var acc: String { used.first ?? "#FF0000" }
    public var acc2: String { used.count > 1 ? used[1] : acc }
    /// The three colours of the cinematic scenes (--c1 --c2 --c3).
    public var c1: String { acc }
    public var c2: String { acc2 }
    public var c3: String { used.count > 2 ? used[2] : acc2 }
    public var hiManual: Bool { hiColor != nil }
    public var accHi: String { hiColor ?? Self.mixWhite(acc, hiPercent) }
    /// Dark or white text, whichever has the higher contrast on every stop.
    public var ink: String { inkContrasts.dark >= inkContrasts.white ? Self.dark : Self.white }
    public var inkContrast: Double { max(inkContrasts.dark, inkContrasts.white) }
    public var inkContrasts: (dark: Double, white: Double) {
        (used.map { Self.contrast($0, Self.dark) }.min() ?? 1, used.map { Self.contrast($0, Self.white) }.min() ?? 1)
    }
    /// The colour on the dark glass of the kit.
    public var glassContrast: Double { used.map { Self.contrast($0, Self.glass) }.min() ?? 1 }

    /// The CSS variables, as the skill's picker writes them.
    public var css: String {
        var lines = ["--acc: \(acc);", "--acc2: \(acc2);", "--acc-hi: \(accHi);", "--acc-ink: \(ink);"]
        switch mode {
        case .gradient: lines.append("--acc-grad: linear-gradient(\(Self.number(angle))deg, var(--acc), var(--acc2));")
        case .three: lines.append("--c1: \(c1); --c2: \(c2); --c3: \(c3);")
        case .solid: lines.append("/* solid: --acc2 = --acc */")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: colour maths (WCAG 2)

    public static func rgb(_ hex: String) -> (Double, Double, Double)? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xFF), Double(v >> 8 & 0xFF), Double(v & 0xFF))
    }

    public static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func c(_ v: Double) -> String { String(format: "%02X", Int(min(255, max(0, v.rounded())))) }
        return "#" + c(r) + c(g) + c(b)
    }

    public static func luminance(_ hex: String) -> Double {
        guard let (r, g, b) = rgb(hex) else { return 0 }
        func lin(_ v: Double) -> Double { let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public static func contrast(_ a: String, _ b: String) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    public static func mixWhite(_ hex: String, _ percent: Double) -> String {
        guard let (r, g, b) = rgb(hex) else { return hex }
        let p = percent / 100
        return Self.hex(r + (255 - r) * p, g + (255 - g) * p, b + (255 - b) * p)
    }

    static func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    /// Checks the values and normalises the hex codes.
    public func validated() throws -> Accent {
        let need = Self.count(mode)
        guard stops.count >= need else {
            throw EditorError.invalid("a \(mode.rawValue) accent needs \(need) colour\(need > 1 ? "s" : "") in stops", parameter: "stops")
        }
        var out = self
        out.stops = try stops.prefix(need).map { s in
            guard let (r, g, b) = Self.rgb(s) else { throw EditorError.invalid("\(s) is not a colour; give #RRGGBB", parameter: "stops") }
            return Self.hex(r, g, b)
        }
        if let h = hiColor {
            guard let (r, g, b) = Self.rgb(h) else { throw EditorError.invalid("\(h) is not a colour; give #RRGGBB or auto", parameter: "hiColor") }
            out.hiColor = Self.hex(r, g, b)
        }
        guard (0...360).contains(angle) else { throw EditorError.invalid("angle is 0 to 360 degrees", parameter: "angle") }
        guard (30...95).contains(hiPercent) else { throw EditorError.invalid("hiPercent is 30 to 95", parameter: "hiPercent") }
        return out
    }
}

public struct SetAccent: EditorCommand {
    public static let name = "project.setAccent"
    public static let spec = CommandSpec("Set the project's accent colour for motion graphics, as the owner picked it: solid, a two-stop gradient with an angle, or three colours (--c1 --c2 --c3 for cinematic scenes). The light variant --acc-hi is mixed from the first colour, or picked by hand. Agents never choose or propose a colour themselves: this records the owner's pick. mode none clears it.", [
        Parameter("mode", .oneOf(["none"] + Accent.Mode.allCases.map(\.rawValue)), "solid, gradient, three or none", required: true),
        Parameter("stops", .array(.string), "Colours as #RRGGBB: one for solid, two for a gradient, three for three"),
        Parameter("angle", .number, "Gradient angle in degrees; default 135"),
        Parameter("hiPercent", .number, "How far --acc-hi mixes the first colour towards white, 30 to 95; default 72. Giving it alone goes back to the mix"),
        Parameter("hiColor", .string, "--acc-hi picked by hand as #RRGGBB, or auto to mix it from the first colour"),
    ])

    public var mode: String
    public var stops: [String]?
    public var angle: Double?
    public var hiPercent: Double?
    public var hiColor: String?

    public init(mode: String, stops: [String]? = nil, angle: Double? = nil, hiPercent: Double? = nil, hiColor: String? = nil) {
        self.mode = mode
        self.stops = stops
        self.angle = angle
        self.hiPercent = hiPercent
        self.hiColor = hiColor
    }

    public func apply(to p: inout Project) throws {
        if mode == "none" { p.accent = nil; return }
        guard let m = Accent.Mode(rawValue: mode) else { throw EditorError.invalid("mode is solid, gradient, three or none", parameter: "mode") }
        var hi = p.accent?.hiColor
        if let h = hiColor { hi = h.lowercased() == "auto" ? nil : h } else if hiPercent != nil { hi = nil }
        p.accent = try Accent(mode: m, stops: stops ?? p.accent?.stops ?? [], angle: angle ?? p.accent?.angle ?? 135,
                              hiPercent: hiPercent ?? p.accent?.hiPercent ?? 72, hiColor: hi).validated()
    }
}
