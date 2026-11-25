import EditorCore
import Foundation
import Testing
@testable import EditorKit

/// Every command the editor has, in random order with random arguments, as
/// agents and the app send them: arguments built from each command's own
/// spec as JSON and decoded the way a tool call is, ids mostly real and
/// sometimes wrong, times on and off the frame grid, values in and out of
/// range, single commands, batches, dry runs, undo and redo. After every
/// step:
///
/// - a refused step changes nothing, and only `EditorError` refuses;
/// - a dry run changes nothing;
/// - the project keeps its rules (`problems`);
/// - the project survives a JSON round trip unchanged;
/// - the step's journal entries, applied to the project before it, give
///   exactly the project after it (what a reopen does);
///
/// and at the end the package reopens to exactly the final project.
@Suite("Every command in random order keeps the project sound", .serialized)
struct FullPropertyTests {
    static let fps = FrameRate.fps60

    static func project() -> Project {
        var p = Project(id: "project_t", name: "t", settings: ProjectSettings(width: 1080, height: 1920, frameRate: fps, dynamicRange: .sdr))
        p.tracks = [Track(id: "main", kind: .main, name: "Main"),
                    Track(id: "over", kind: .overlay, name: "Overlay"),
                    Track(id: "music", kind: .audio, name: "Music")]
        p.media = [
            MediaAsset(id: "cam", path: "/x/cam.mov", name: "cam.mov", fingerprint: "1",
                       info: MediaInfo(duration: Time(seconds: 600), video: VideoInfo(width: 1080, height: 1920, frameRate: 60, codec: "hvc1"),
                                       audio: AudioInfo(sampleRate: 48000, channels: 2, codec: "aac"))),
            MediaAsset(id: "broll", path: "/x/broll.mov", name: "broll.mov", fingerprint: "2",
                       info: MediaInfo(duration: Time(seconds: 12.5), video: VideoInfo(width: 1920, height: 1080, frameRate: 30, codec: "avc1"), audio: nil)),
            MediaAsset(id: "song", path: "/x/song.wav", name: "song.wav", fingerprint: "3",
                       info: MediaInfo(duration: Time(seconds: 200), video: nil, audio: AudioInfo(sampleRate: 48000, channels: 2, codec: "lpcm"))),
            MediaAsset(id: "still", path: "/x/still.png", name: "still.png", fingerprint: "4",
                       info: MediaInfo(duration: MediaAsset.stillDuration, video: VideoInfo(width: 800, height: 800, frameRate: 0, codec: "png"), audio: nil),
                       kind: .image),
        ]
        return p
    }

    // MARK: the rules

    static func problems(_ p: Project) -> [String] {
        var out: [String] = []
        let frame = p.settings.frameRate.frameDuration
        var ids = Set<EntityID>()
        func unique(_ id: EntityID, _ what: String) {
            if !ids.insert(id).inserted { out.append("\(what) \(id) uses an id that is already taken") }
        }
        let media = Dictionary(p.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let looks = Set(p.looks.map(\.id))
        for a in p.media { unique(a.id, "media") }
        for l in p.looks {
            unique(l.id, "look")
            for sl in Look.sliders where !sl.range.contains(l[slider: sl.name]) { out.append("look \(l.id) \(sl.name) \(l[slider: sl.name])") }
            if l.picked.count > 4 { out.append("look \(l.id) holds \(l.picked.count) picked colours") }
            for c in l.picked where !(5...90).contains(c.range) { out.append("picked colour \(c.id) range \(c.range)") }
            for c in l.picked {
                unique(c.id, "picked colour")
                if Accent.rgb(c.color) == nil { out.append("picked colour \(c.id) is not a colour: \(c.color)") }
            }
        }
        for m in p.markers {
            unique(m.id, "marker")
            if m.time.ticks < 0 { out.append("marker \(m.id) before 0") }
        }
        for t in p.transcripts {
            unique(t.id, "transcript")
            if media[t.asset] == nil { out.append("transcript \(t.id) belongs to missing media \(t.asset)") }
        }
        if p.settings.width <= 0 || p.settings.height <= 0 || p.settings.width % 2 != 0 || p.settings.height % 2 != 0 {
            out.append("canvas \(p.settings.width)x\(p.settings.height)")
        }
        if p.tracks.filter({ $0.kind == .main }).count > 1 { out.append("\(p.tracks.filter { $0.kind == .main }.count) main tracks") }
        if let a = p.accent {
            if (try? a.validated()) != a { out.append("the accent breaks its own rules: \(a)") }
        }
        for t in p.tracks {
            unique(t.id, "track")
            if let l = t.look, !looks.contains(l) { out.append("track \(t.id) uses missing look \(l)") }
            if t.joinFade.ticks < 0 || t.joinFade > Time(seconds: 1) { out.append("track \(t.id) join fade \(t.joinFade.seconds) s") }
            for (i, c) in t.clips.enumerated() {
                unique(c.id, "clip")
                guard let a = media[c.asset] else { out.append("\(c.id) uses missing media \(c.asset)"); continue }
                if t.kind == .audio, a.info.audio == nil { out.append("\(c.id) on sound track \(t.id) has no sound (\(a.id))") }
                if t.kind != .audio, a.info.video == nil, !a.isHyperFrames { out.append("\(c.id) on picture track \(t.id) has no picture (\(a.id))") }
                if let l = c.look, !looks.contains(l) { out.append("\(c.id) uses missing look \(l)") }
                if c.start.ticks < 0 { out.append("\(c.id) starts before 0") }
                if c.duration < frame { out.append("\(c.id) is shorter than a frame (\(c.duration.ticks) ticks)") }
                if c.start.ticks % frame.ticks != 0 { out.append("\(c.id) starts off the frame grid (\(c.start.ticks))") }
                if c.duration.ticks % frame.ticks != 0 { out.append("\(c.id) lasts off the frame grid (\(c.duration.ticks))") }
                if c.sourceStart.ticks < 0 { out.append("\(c.id) reads before its file starts") }
                if c.sourceDuration.ticks <= 0 { out.append("\(c.id) reads nothing from its file") }
                if a.info.video != nil || a.info.audio != nil, c.sourceEnd > a.info.duration + frame {
                    out.append("\(c.id) reads past the end of its file (\(c.sourceEnd.seconds) > \(a.info.duration.seconds))")
                }
                if c.fadeIn.ticks < 0 || c.fadeOut.ticks < 0 { out.append("\(c.id) has a negative fade") }
                if c.fadeIn + c.fadeOut > c.duration { out.append("\(c.id) fades are longer than the clip") }
                if !(-60...24).contains(c.gainDB) { out.append("\(c.id) gain \(c.gainDB) dB") }
                if !(0...1).contains(c.opacity) { out.append("\(c.id) opacity \(c.opacity)") }
                let tr = c.transform
                for (n, v) in [("x", tr.x), ("y", tr.y), ("scale", tr.scale), ("rotation", tr.rotation)] where !v.isFinite {
                    out.append("\(c.id) transform \(n) is not a number")
                }
                if tr.scale <= 0 { out.append("\(c.id) scale \(tr.scale)") }
                for v in [tr.cropLeft, tr.cropTop, tr.cropRight, tr.cropBottom] where !(0...1).contains(v) {
                    out.append("\(c.id) crop \(v) outside 0 to 1")
                }
                if tr.cropLeft + tr.cropRight >= 1 || tr.cropTop + tr.cropBottom >= 1 { out.append("\(c.id) crops away the whole picture") }
                for e in c.effects {
                    unique(e.id, "effect")
                    if e.kind != .filter, (e.duration?.ticks ?? 0) <= 0 { out.append("\(c.id) \(e.kind) effect \(e.id) has no length") }
                    for (k, v) in e.params where !v.isFinite { out.append("\(c.id) effect \(e.id) \(k) is not a number") }
                }
                for (prop, ks) in c.keyframes {
                    if KeyframeProperty(rawValue: prop) == nil { out.append("\(c.id) keyframes for unknown property \(prop)") }
                    if ks.isEmpty { out.append("\(c.id) keeps an empty keyframe list for \(prop)") }
                    for (j, k) in ks.enumerated() {
                        if !k.value.isFinite { out.append("\(c.id) keyframe value is not a number") }
                        if j > 0, ks[j - 1].time >= k.time { out.append("\(c.id) \(prop) keyframes out of order or doubled") }
                    }
                }
                if i > 0 {
                    let b = t.clips[i - 1]
                    if b.start > c.start { out.append("\(t.id) clips out of order at \(c.id)") }
                    if b.end > c.start { out.append("\(t.id): \(b.id) overlaps \(c.id) (\(b.end.seconds) > \(c.start.seconds))") }
                }
            }
        }
        return out
    }

    // MARK: random arguments

    struct Gen {
        /// Tools with a weight each: clip and timeline edits most, removals
        /// of whole tracks and media seldom, so timelines grow and get edited.
        static let tools: [(String, [Parameter])] = CommandRegistry.all.flatMap { t -> [(String, [Parameter])] in
            guard t.spec.exposedAsTool else { return [] }
            let n = t.name
            let w = ["track.remove", "media.remove"].contains(n) ? 1
                : n == "clip.add" ? 12
                : n.hasPrefix("clip.") || n.hasPrefix("timeline.") || n.hasPrefix("effect.") ? 5 : 2
            return Array(repeating: (n, t.spec.parameters), count: w)
        }
        var g: SplitMix64
        let p: Project

        mutating func chance(_ x: Double) -> Bool { Double.random(in: 0..<1, using: &g) < x }
        mutating func pick<T>(_ a: [T]) -> T? { a.randomElement(using: &g) }

        var clips: [Clip] { p.tracks.flatMap(\.clips) }
        var end: Double { max(p.duration.seconds, 1) }

        /// Ids of the kind a parameter names, usually real, sometimes not.
        mutating func id(_ param: String, _ command: String) -> String {
            let all: [EntityID] = p.media.map(\.id) + p.tracks.map(\.id) + clips.map(\.id) + p.markers.map(\.id)
                + p.looks.map(\.id) + p.transcripts.map(\.id)
            if chance(0.04) { return "nope_\(Int.random(in: 0..<9, using: &g))" }
            if chance(0.04), let any = pick(all) { return any.raw }
            let pool: [EntityID]
            let family = command.split(separator: ".").first.map(String.init) ?? ""
            switch param {
            case "track", "tracks": pool = p.tracks.map(\.id)
            case "asset": pool = p.media.map(\.id)
            case "look": pool = p.looks.map(\.id)
            case "clip", "clips": pool = clips.map(\.id)
            case "effect": pool = clips.flatMap(\.effects).map(\.id)
            default:
                switch family {
                case "track": pool = p.tracks.map(\.id)
                case "media": pool = p.media.map(\.id)
                case "marker": pool = p.markers.map(\.id)
                case "transcript": pool = p.transcripts.map(\.id)
                case "look" where command.contains("PickedColor"): pool = p.looks.flatMap(\.picked).map(\.id)
                case "look": pool = p.looks.map(\.id)
                default: pool = clips.map(\.id)
                }
            }
            // A new id for a command that creates something.
            if param == "id", ["clip.add", "track.add", "marker.add", "look.create", "look.addPickedColor"].contains(command) {
                return chance(0.6) ? "made_\(Int.random(in: 0..<40, using: &g))" : (pick(all)?.raw ?? "made_0")
            }
            return pick(pool)?.raw ?? "nope_x"
        }

        mutating func seconds() -> Double {
            let f = 1.0 / Double(FullPropertyTests.fps.fps)
            switch Int.random(in: 0..<10, using: &g) {
            case 0: return 0
            case 1: return -Double.random(in: 0...3, using: &g)
            case 2: return Double.random(in: 0...end, using: &g)                       // off the grid
            case 3: return end + Double.random(in: 0...20, using: &g)
            case 4: return f * Double(Int.random(in: 0...3, using: &g))                // tiny
            case 5: return [1e15, 9e11, 9.9e8].randomElement(using: &g)! * (chance(0.5) ? 1 : Double.random(in: 0.5...1, using: &g))
            case 6: return [0.05, 0.1, 0.5, 1, 2, 5].randomElement(using: &g)!
            default: return (Double.random(in: 0...end, using: &g) * 60).rounded() / 60
            }
        }

        mutating func number(_ name: String) -> Double {
            switch Int.random(in: 0..<12, using: &g) {
            case 0: return 0
            case 1: return -Double.random(in: 0...200, using: &g)
            case 2: return Double.random(in: 0...1, using: &g)
            case 3: return Double.random(in: 1...5, using: &g)
            case 4: return [0.25, 0.5, 1, 1.22, 2, 4].randomElement(using: &g)!
            case 5: return Double.random(in: -100...100, using: &g)
            case 6: return [1e9, -1e9, 1e-9, 1e300].randomElement(using: &g)!
            case 7: return Double(Int.random(in: -400...400, using: &g))
            default: return Double.random(in: -2...2, using: &g)
            }
        }

        mutating func integer(_ name: String) -> Int {
            switch Int.random(in: 0..<6, using: &g) {
            case 0: return 0
            case 1: return Int.random(in: -40...40, using: &g)
            case 2: return [24, 25, 30, 50, 60, 1080, 1920, 1081, 7].randomElement(using: &g)!
            case 3: return [Int.max / 4, -1_000_000].randomElement(using: &g)!
            default: return Int.random(in: 0...5, using: &g)
            }
        }

        mutating func hex() -> String {
            if chance(0.08) { return ["red", "#12", "#GGGGGG", "", "#1234567"].randomElement(using: &g)! }
            return String(format: "#%06X", Int.random(in: 0...0xFFFFFF, using: &g))
        }

        mutating func string(_ name: String, _ command: String) -> String {
            switch name {
            case "color", "hiColor": return name == "hiColor" && chance(0.3) ? "auto" : hex()
            case "path": return "/x/\(["a", "b", "c"].randomElement(using: &g)!).mov"
            default: return chance(0.1) ? "" : ["Intro", "B-roll", "Take 2", "名", "a\"b\\c\nd"].randomElement(using: &g)!
            }
        }

        /// A value a careful caller would send, when the name says what fits.
        mutating func sane(_ prm: Parameter, _ command: String) -> JSONValue? {
            let r = { (a: Double, b: Double, g: inout SplitMix64) in JSONValue.number(Double.random(in: a...b, using: &g)) }
            switch prm.name {
            case "speed": return .number([0.25, 0.5, 1, 1.22, 1.5, 2, 4].randomElement(using: &g)!)
            case "gainDB": return r(-60, 24, &g)
            case "x", "y", "opacity": return r(0, 1, &g)
            case "scale": return r(0.1, 3, &g)
            case "rotation": return r(-360, 360, &g)
            case "cropLeft", "cropTop", "cropRight", "cropBottom": return r(0, 0.45, &g)
            case "range": return r(5, 90, &g)
            case "hue", "saturation", "luminance", "exposure", "clarity", "highlights", "shadows", "contrast", "brightness",
                 "whites", "blacks", "vibrance", "temperature", "tint": return r(-100, 100, &g)
            case "sharpen", "noiseReduction", "fade", "vignette", "grain": return r(0, 100, &g)
            case "angle": return r(0, 360, &g)
            case "hiPercent": return r(30, 95, &g)
            case "frames": return .number(Double(Int.random(in: -30...30, using: &g)))
            case "index": return .number(Double(Int.random(in: 0...3, using: &g)))
            case "width", "height": return .number(Double([720, 1080, 1920, 2160].randomElement(using: &g)!))
            case "frameRate": return .number(Double([24, 25, 30, 50, 60].randomElement(using: &g)!))
            case "duration" where command == "timeline.setJoinFades": return r(0, 1, &g)
            case "fadeIn", "fadeOut", "duration", "by": return .number((Double.random(in: 0...3, using: &g) * 60).rounded() / 60)
            case "start", "end", "time", "sourceStart", "from", "to":
                return .number((Double.random(in: 0...end, using: &g) * 60).rounded() / 60)
            case "sourceDuration": return .number((Double.random(in: 0.1...20, using: &g) * 60).rounded() / 60)
            case "asset" where command == "clip.add" || command == "clip.replaceMedia":
                return .string(["cam", "cam", "broll", "song", "still"].randomElement(using: &g)!)
            default: return nil
            }
        }

        mutating func value(_ prm: Parameter, _ kind: Parameter.Kind, _ command: String) -> JSONValue {
            if chance(0.7), let v = sane(prm, command) { return v }
            switch kind {
            case .string: return .string(string(prm.name, command))
            case .number: return .number(number(prm.name))
            case .integer: return .number(Double(integer(prm.name)))
            case .boolean: return .bool(chance(0.5))
            case .seconds: return .number(seconds())
            case .id: return .string(id(prm.name, command))
            case .oneOf(let v): return .string(chance(0.03) ? "bogus" : v.randomElement(using: &g)!)
            case .array(let k):
                if prm.name == "stops" {
                    return .array((0..<Int.random(in: 0...4, using: &g)).map { _ in .string(hex()) })
                }
                if case .object = k { return .array((0..<Int.random(in: 0...4, using: &g)).map { _ in keyframe() }) }
                let n = Int.random(in: chance(0.1) ? 0...0 : 1...3, using: &g)
                return .array((0..<n).map { _ in value(prm, k, command) })
            case .object:
                if prm.name == "hsl" {
                    var o: [String: JSONValue] = [:]
                    for _ in 0..<Int.random(in: 0...3, using: &g) {
                        let band = chance(0.05) ? "teal" : HSLBand.allCases.randomElement(using: &g)!.rawValue
                        var v: [String: JSONValue] = [:]
                        for k in ["hue", "saturation", "luminance"] where chance(0.5) { v[k] = .number(number(k)) }
                        o[band] = .object(v)
                    }
                    return .object(o)
                }
                return .object([:])
            case .any: return .null
            }
        }

        mutating func keyframe() -> JSONValue {
            var o: [String: JSONValue] = ["time": .number(seconds()), "value": .number(number("value"))]
            if chance(0.7) { o["easing"] = .string(chance(0.05) ? "bounce" : Keyframe.Easing.allCases.randomElement(using: &g)!.rawValue) }
            return .object(o)
        }

        /// A command made the way a tool call makes it: JSON from the spec,
        /// decoded by the registry. Nil when the JSON itself is refused.
        mutating func toolCommand() -> (String, Result<any EditorCommand, Error>) {
            let (name, params) = Self.tools[Int.random(in: 0..<Self.tools.count, using: &g)]
            var args: [String: JSONValue] = [:]
            for prm in params where prm.required || chance(0.45) {
                args[prm.name] = value(prm, prm.kind, name)
            }
            let json = JSONValue.object(args)
            let label = "\(name) \(text(json).prefix(220))"
            do {
                let c: any EditorCommand = try CommandRegistry.decode(name: name, arguments: json.data())
                return (label, .success(c))
            } catch {
                return (label, .failure(error))
            }
        }

        /// Commands only other tools make, built as those tools build them.
        mutating func internalCommand() -> (String, any EditorCommand) {
            switch Int.random(in: 0..<8, using: &g) {
            case 0:
                let id = EntityID(chance(0.8) ? "m\(Int.random(in: 0..<20, using: &g))" : (pick(p.media)?.id.raw ?? "cam"))
                let sound = chance(0.5)
                let a = MediaAsset(id: id, path: "/x/\(id).mov", name: "\(id).mov", fingerprint: "f",
                                   info: MediaInfo(duration: Time(seconds: Double.random(in: 0.5...90, using: &g)),
                                                   video: VideoInfo(width: 1080, height: 1920, frameRate: 30, codec: "hvc1"),
                                                   audio: sound ? AudioInfo(sampleRate: 48000, channels: 2, codec: "aac") : nil))
                return ("media.add \(id)", AddMedia(assets: [a]))
            case 1:
                let id = pick(p.media)?.id ?? "nope"
                let d = Time(seconds: [0.4, 12.5, 600, 3600].randomElement(using: &g)!)
                return ("media.setPath \(id) \(d.seconds)", SetMediaPath(id: id, path: "/y/\(id).mov", name: "\(id).mov", fingerprint: "g",
                                                                         info: MediaInfo(duration: d, video: VideoInfo(width: 1080, height: 1920, frameRate: 60, codec: "hvc1"),
                                                                                         audio: chance(0.5) ? AudioInfo(sampleRate: 48000, channels: 2, codec: "aac") : nil)))
            case 2:
                var l = Look(id: EntityID(chance(0.5) ? "look_p\(Int.random(in: 0..<5, using: &g))" : (pick(p.looks)?.id.raw ?? "look_p0")), name: "profile")
                l.exposure = number("exposure")
                l.picked = chance(0.5) ? [PickedColor(id: EntityID("pc_\(Int.random(in: 0..<5, using: &g))"), color: hex())] : []
                return ("look.put \(l.id) exposure \(l.exposure)", PutLook(look: l))
            case 3:
                let a = pick(p.media)?.id ?? "cam"
                let words = (0..<Int.random(in: 0...5, using: &g)).map { i in
                    TranscriptWord(text: "w\(i)", start: Time(seconds: Double(i)), end: Time(seconds: Double(i) + 0.5))
                }
                let t = Transcript(id: EntityID("tr_\(Int.random(in: 0..<6, using: &g))"), asset: a, language: "en", engine: "import",
                                   sourceStart: .zero, sourceEnd: Time(seconds: 10), words: words)
                return ("transcript.add \(t.id) on \(a)", AddTranscript(transcript: t))
            default:
                let c = pick(clips)?.id ?? "nope"
                let existing = clips.first { $0.id == c }?.effects.map(\.id) ?? []
                let kind = EffectKind.allCases.randomElement(using: &g)!
                let id: EntityID = chance(0.4) ? (existing.randomElement(using: &g) ?? "fx_0") : EntityID("fx_\(Int.random(in: 0..<30, using: &g))")
                let inst = EffectInstance(id: id, effect: "blur.gaussian", kind: kind, params: ["radius": number("radius")],
                                          duration: chance(0.7) ? Time(seconds: seconds()) : nil)
                let index: Int? = chance(0.5) ? Int.random(in: -1...4, using: &g) : nil
                return ("effect.put \(c) \(id) \(kind) d=\(inst.duration?.seconds ?? -1) at \(index ?? -9)", PutEffect(clip: c, instance: inst, index: index))
            }
        }
    }

    // MARK: the run

    @Test(arguments: 0..<160)
    func everyCommandInRandomOrder(_ seed: Int) async throws {
        // FP_SALT runs other random sequences; FP_STEPS longer ones.
        let salt = UInt64(ProcessInfo.processInfo.environment["FP_SALT"] ?? "") ?? 0
        var rng = SplitMix64(UInt64(seed) &* 104_729 &+ 31 &+ salt &* 7_919_000_003)
        let url = tempDir().appendingPathComponent("p.dmeproj")
        let s = try EditorSession.create(at: url, project: Self.project(), compactEvery: 13)
        let home = url.deletingLastPathComponent()
        let goodTranscript = home.appendingPathComponent("words.json"), badTranscript = home.appendingPathComponent("words.txt")
        try Data(#"{"language":"en","words":[{"text":"one","start":0.5,"end":0.9},{"text":"two","start":1.2,"end":1.1},{"word":"three","start":2,"end":2.6},{"text":"x"}]}"#.utf8).write(to: goodTranscript)
        try Data("not json".utf8).write(to: badTranscript)
        let editor = Editor(settings: try UserSettingsStore(directory: url.deletingLastPathComponent().appendingPathComponent("home")),
                            prober: RefusingProber())
        await editor.adoptForTesting(s)
        var log: [String] = []
        var wrong: [String] = []
        var applied = 0
        func fail(_ m: String) { wrong.append("seed \(seed) step \(log.count - 1): \(m)\n  " + log.suffix(3).joined(separator: "\n  ")) }

        let steps = Int(ProcessInfo.processInfo.environment["FP_STEPS"] ?? "") ?? 120
        for _ in 0..<steps where wrong.count < 3 {
            let before = await s.project, rev = await s.revision
            var gen = Gen(g: rng, p: before)
            defer { rng = gen.g }
            let roll = Int.random(in: 0..<100, using: &gen.g)
            var commands: [any EditorCommand] = []
            var dry = false
            if roll >= 84 && roll < 90 {
                // A write or manage tool that is not a plain command.
                let (name, params) = Self.otherTools[Int.random(in: 0..<Self.otherTools.count, using: &gen.g)]
                var args: [String: JSONValue] = [:]
                if name == "batch.apply" {
                    var list: [JSONValue] = []
                    for _ in 0..<Int.random(in: 1...3, using: &gen.g) {
                        let (tn, tp) = Gen.tools[Int.random(in: 0..<Gen.tools.count, using: &gen.g)]
                        var a: [String: JSONValue] = [:]
                        for prm in tp where prm.required || gen.chance(0.45) { a[prm.name] = gen.value(prm, prm.kind, tn) }
                        list.append(.object(["name": .string(tn), "args": .object(a)]))
                    }
                    args["commands"] = .array(list)
                } else {
                    for prm in params where prm.required || gen.chance(0.5) {
                        args[prm.name] = prm.name == "path" && name == "transcript.import"
                            ? .string([goodTranscript.path, goodTranscript.path, badTranscript.path, "/x/none.json"].randomElement(using: &gen.g)!)
                            : prm.name == "revision" ? .number(Double(rev - Int.random(in: -2...8, using: &gen.g)))
                            : prm.name == "name" && name.contains("Profile") ? .string(["skin", "night", "a/b", ""].randomElement(using: &gen.g)!)
                            : gen.value(prm, prm.kind, name)
                    }
                }
                log.append("tool \(name) \(text(.object(args)).prefix(260))")
                if let trace = ProcessInfo.processInfo.environment["FP_TRACE"] {
                    try? Data("seed \(seed): \(log.last!)\n".utf8).write(to: URL(fileURLWithPath: trace + "-\(seed)"))
                }
                do {
                    _ = try await ToolCatalog.named(name)!.call(editor, arguments: .object(args))
                } catch is EditorError {
                    let (np, nr) = (await s.project, await s.revision)
                    if np != before || nr != rev { fail("a refused tool changed the project: \(Self.diff(before, np))") }
                } catch {
                    fail("tool threw \(type(of: error)), not EditorError: \(error)")
                }
            } else if roll >= 90 {
                // A read tool with random arguments: it answers or refuses
                // with EditorError, and never changes the project.
                let (name, params) = Self.readTools[Int.random(in: 0..<Self.readTools.count, using: &gen.g)]
                var args: [String: JSONValue] = [:]
                for prm in params where prm.required || gen.chance(0.5) { args[prm.name] = gen.value(prm, prm.kind, name) }
                log.append("read \(name) \(text(.object(args)).prefix(200))")
                if let trace = ProcessInfo.processInfo.environment["FP_TRACE"] {
                    try? Data("seed \(seed): \(log.last!)\n".utf8).write(to: URL(fileURLWithPath: trace + "-\(seed)"))
                }
                do {
                    _ = try await ToolCatalog.named(name)!.call(editor, arguments: .object(args))
                } catch is EditorError {
                } catch {
                    fail("read tool threw \(type(of: error)), not EditorError: \(error)")
                }
                let (np, nr) = (await s.project, await s.revision)
                if np != before || nr != rev { fail("a read tool changed the project") }
                continue
            } else if roll < 6 {
                log.append("undo")
                _ = try? await s.undo()
            } else if roll < 10 {
                log.append("redo")
                _ = try? await s.redo()
            } else {
                let count = roll < 14 ? 2 : 1
                dry = roll >= 14 && roll < 18
                var names: [String] = []
                for _ in 0..<count {
                    if gen.chance(0.18) {
                        let (n, c) = gen.internalCommand()
                        names.append(n)
                        commands.append(c)
                    } else {
                        let (n, r) = gen.toolCommand()
                        names.append(n)
                        switch r {
                        case .success(let c): commands.append(c)
                        case .failure(let e):
                            if !(e is EditorError) { log.append(n); fail("decoding threw \(type(of: e)), not EditorError: \(e)") }
                        }
                    }
                }
                log.append((dry ? "dry " : "") + names.joined(separator: " + "))
                if let trace = ProcessInfo.processInfo.environment["FP_TRACE"] {
                    try? Data("seed \(seed): \(log.last!)\n".utf8).write(to: URL(fileURLWithPath: trace + "-\(seed)"))
                }
                guard commands.count == count else { continue }
                do {
                    let r = try await s.apply(commands, dryRun: dry)
                    if dry {
                        let (np, nr) = (await s.project, await s.revision)
                        if np != before || nr != rev { fail("a dry run changed the project") }
                    } else {
                        applied += 1
                        // What a reopen does: the stored commands, without prepare, on the project before.
                        var replayed = before
                        do {
                            for sc in r.applied { try sc.decoded(stored: true).apply(to: &replayed) }
                            let np = await s.project
                            if replayed != np { fail("the journal entry does not rebuild the step: \(Self.diff(replayed, np))") }
                        } catch {
                            fail("the journal entry does not replay: \(error)")
                        }
                    }
                } catch is EditorError {
                    let (np, nr) = (await s.project, await s.revision)
                    if np != before || nr != rev { fail("a refused step changed the project: \(Self.diff(before, np))") }
                } catch {
                    fail("refused with \(type(of: error)), not EditorError: \(error)")
                }
            }
            let now = await s.project
            let bad = Self.problems(now)
            if !bad.isEmpty { fail(bad.prefix(4).joined(separator: "; ")) }
            do {
                let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(now))
                if back != now { fail("the project changes in a JSON round trip: \(Self.diff(now, back))") }
            } catch {
                fail("the project does not read back: \(error)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n\n"))")
        #expect(applied > steps / 15, "most steps should apply (\(applied) of \(steps))")
        // Undo a few steps and redo them, so the journal holds undo and redo
        // of steps from before the last snapshot too; note each project.
        var undone: [Project] = []
        for _ in 0..<6 { if (try? await s.undo()) != nil { undone.append(await s.project) } }
        for _ in undone.indices { _ = try? await s.redo() }
        let final = await s.project
        await s.abandonForTesting()
        let reopened = try await EditorSession.open(at: url)
        let back = await reopened.project
        #expect(back == final, "seed \(seed): the package reopens to a different project: \(Self.diff(final, back))")
        // After a reopen, undo goes back through the same projects.
        for (k, want) in undone.enumerated() {
            guard (try? await reopened.undo()) != nil else { break }
            let got = await reopened.project
            if got != want { Issue.record("seed \(seed): undo \(k + 1) after reopening gives a different project: \(Self.diff(want, got))"); break }
        }
        try await reopened.close()
    }

    /// Every read tool except the one that waits for background jobs.
    static let readTools: [(String, [Parameter])] = ToolCatalog.all
        .filter { $0.access == .read && $0.name != "job.wait" }
        .map { ($0.name, $0.parameters) }

    /// Write and manage tools that are not plain commands, except those
    /// that open, close or replace the project or change the user's settings.
    static let otherTools: [(String, [Parameter])] = ["batch.apply", "history.undo", "history.redo", "history.revertTo",
        "look.loadProfile", "look.saveProfile", "look.renameProfile", "look.deleteProfile", "media.import", "media.relink",
        "transcript.import", "notes.write", "notes.remove"].map { n in
            guard let t = ToolCatalog.named(n) else { fatalError("no tool \(n)") }
            return (n, t.parameters)
        }

    /// Where two projects differ, briefly.
    static func diff(_ a: Project, _ b: Project) -> String {
        guard let x = try? JSONValue.parse(JSONEncoder().encode(a)), let y = try? JSONValue.parse(JSONEncoder().encode(b)) else { return "?" }
        var out: [String] = []
        func walk(_ x: JSONValue?, _ y: JSONValue?, _ path: String) {
            guard out.count < 4, x != y else { return }
            if case .object(let o)? = x, case .object(let q)? = y {
                for k in Set(o.keys).union(q.keys).sorted() { walk(o[k], q[k], path + "." + k) }
            } else if case .array(let o)? = x, case .array(let q)? = y, o.count == q.count {
                for i in o.indices { walk(o[i], q[i], path + "[\(i)]") }
            } else {
                out.append("\(path): \(x.map { String(text($0).prefix(80)) } ?? "nil") vs \(y.map { String(text($0).prefix(80)) } ?? "nil")")
            }
        }
        walk(x, y, "")
        return out.joined(separator: "; ")
    }
}

func text(_ v: JSONValue) -> String { (try? v.data()).flatMap { String(data: $0, encoding: .utf8) } ?? "?" }

/// No files exist in these tests.
struct RefusingProber: MediaProber {
    func probe(_ url: URL) async throws -> MediaInfo { throw EditorError(.notFound, "no file \(url.path)") }
}
