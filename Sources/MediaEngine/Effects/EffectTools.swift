import EditorCore
import EditorKit
import Foundation

/// Effect tools (X-2). Parameters are checked against the plug-in's manifest
/// here; the stored change is an `effect.put` command.
public enum EffectTools {
    static func params(_ args: Args) throws -> [String: Double] {
        guard let o = args.values["params"], o != .null else { return [:] }
        guard let obj = o.objectValue else { throw EditorError.invalid("params is an object of name: value", parameter: "params") }
        var out: [String: Double] = [:]
        for (k, v) in obj {
            if let d = v.doubleValue { out[k] = d }
            else if let b = v.boolValue { out[k] = b ? 1 : 0 }
            else if case .string = v { continue }   // a choice by name; see `choices`
            else { throw EditorError.invalid("\(k) must be a number or true/false", parameter: k) }
        }
        return out
    }

    /// Choice parameters may also be given by name.
    static func choices(_ args: Args, _ m: EffectManifest, into p: inout [String: Double]) throws {
        guard let obj = args.values["params"]?.objectValue else { return }
        for (k, v) in obj {
            guard case .string(let s) = v else { continue }
            guard let q = m.parameters.first(where: { $0.name == k }), q.type == .choice, let i = q.choices?.firstIndex(of: s) else {
                let q = m.parameters.first { $0.name == k }
                throw EditorError.invalid(q?.type == .choice ? "\(k) is one of \((q?.choices ?? []).joined(separator: ", "))" : "\(k) must be a number or true/false", parameter: k)
            }
            p[k] = Double(i)
        }
    }

    static func manifest(_ id: String) throws -> EffectManifest {
        guard let e = EffectCatalog.shared.entry(id) else {
            let names = EffectCatalog.shared.all.map(\.manifest.id).joined(separator: ", ")
            throw EditorError(.notFound, "no effect \(id); installed: \(names)")
        }
        return e.manifest
    }

    static func describe(_ e: EffectCatalog.Entry) throws -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(e.manifest.id), "name": .string(e.manifest.name), "kind": .string(e.manifest.kind.rawValue),
            "builtIn": .bool(e.builtIn), "folder": .string(e.folder.path),
            "parameters": try JSONValue(encoding: e.manifest.parameters),
        ]
        if let s = e.manifest.summary { o["summary"] = .string(s) }
        if let d = e.manifest.duration { o["duration"] = try JSONValue(encoding: d) }
        return .object(o)
    }

    public static func make(_ media: MediaContext) -> [Tool] {
        [
            Tool("effect.catalog", .read, "Installed effects with their kinds and parameters, plus plug-in folders that failed to load and why.") { _, _ in
                let c = EffectCatalog.shared
                return .object([
                    "effects": .array(try c.all.map(describe)),
                    "problems": .array(c.currentProblems.map { .object(["folder": .string($0.folder), "message": .string($0.message)]) }),
                    "userFolder": c.userEffectsFolder.map { .string($0.path) } ?? .null,
                ])
            },
            Tool("effect.reload", .manage, "Rescan the effect folders, for example after a plug-in folder was added or changed.") { _, _ in
                let (fx, bad) = EffectCatalog.shared.reload()
                await media.invalidate()
                return .object([
                    "effects": .array(fx.map { .string($0.manifest.id) }),
                    "problems": .array(bad.map { .object(["folder": .string($0.folder), "message": .string($0.message)]) }),
                ])
            },
            Tool("effect.add", .write, "Add an effect to clips. in effects run at the clip start, out effects at its end, filters for the whole clip. Parameters left out take the plug-in's defaults.", [
                Parameter("clips", .array(.id), "Clip ids", required: true),
                Parameter("effect", .string, "Effect id from effect.catalog, for example blur.gaussian", required: true),
                Parameter("params", .object, "Parameter values by name; a choice may be given by name or index"),
                Parameter("duration", .seconds, "Length of an in or out effect; default from the plug-in"),
                Parameter("index", .integer, "Position in each clip's effect list; default last"),
            ] + ToolCatalog.writeOptions) { editor, args in
                let session = try await editor.requireSession()
                let m = try manifest(try args.requiredString("effect"))
                var given = try params(args)
                try choices(args, m, into: &given)
                let resolved = try m.resolve(given)
                let duration = try m.checkDuration(try args.double("duration"))
                guard let clips = try args.strings("clips"), !clips.isEmpty else { throw EditorError.invalid("clips must not be empty", parameter: "clips") }
                var ids: [JSONValue] = []
                let commands: [any EditorCommand] = clips.map { c in
                    let fx = EffectInstance(id: .random("fx"), effect: m.id, kind: m.kind, params: resolved, duration: duration)
                    ids.append(.object(["clip": .string(c), "effect": .string(fx.id.raw)]))
                    return PutEffect(clip: EntityID(c), instance: fx, index: try? args.int("index"))
                }
                let r = try await session.apply(commands, ifRevision: try args.int("ifRevision"), dryRun: try args.bool("dryRun") ?? false)
                return .object(["added": .array(ids), "revision": .number(Double(r.revision))])
            },
            Tool("effect.set", .write, "Change an effect on a clip: parameters (others stay), duration, on or off, or swap it for another effect of the same kind.", [
                Parameter("clip", .id, "Clip id", required: true),
                Parameter("effect", .id, "Effect instance id (from clip.get or effect.add)", required: true),
                Parameter("params", .object, "Parameter values to change"),
                Parameter("duration", .seconds, "New length of an in or out effect"),
                Parameter("enabled", .boolean, "Switch the effect on or off"),
                Parameter("swapTo", .string, "Another effect id of the same kind; parameters with the same name are kept"),
            ] + ToolCatalog.writeOptions) { editor, args in
                let session = try await editor.requireSession()
                let p = await session.project
                let clip = EntityID(try args.requiredString("clip"))
                let (ti, ci) = try p.locate(clip: clip)
                let fxID = EntityID(try args.requiredString("effect"))
                guard var fx = p.tracks[ti].clips[ci].effects.first(where: { $0.id == fxID }) else {
                    throw EditorError.invalid("clip \(clip) has no effect \(fxID)", parameter: "effect")
                }
                var m = try manifest(try args.string("swapTo") ?? fx.effect)
                if let to = try args.string("swapTo") {
                    m = try manifest(to)
                    guard m.kind == fx.kind else { throw EditorError.invalid("\(to) is a \(m.kind.rawValue) effect; \(fx.effect) is \(fx.kind.rawValue)", parameter: "swapTo") }
                    let names = Set(m.parameters.map(\.name))
                    fx.params = fx.params.filter { names.contains($0.key) }
                    fx.effect = to
                }
                var given = try params(args)
                try choices(args, m, into: &given)
                fx.params = try m.resolve(given, over: fx.params)
                if let d = try args.double("duration") { fx.duration = try m.checkDuration(d) }
                if let e = try args.bool("enabled") { fx.enabled = e }
                let r = try await session.apply([PutEffect(clip: clip, instance: fx)], ifRevision: try args.int("ifRevision"),
                                                dryRun: try args.bool("dryRun") ?? false)
                return .object(["effect": try JSONValue(encoding: fx), "revision": .number(Double(r.revision))])
            },
        ]
    }
}
