import EditorCore
import Foundation

/// Every tool the editor offers. Write tools are generated from
/// `CommandRegistry`, so a new command is a new tool with no extra code.
public enum ToolCatalog {
    public static let all: [Tool] = appTools + projectTools + historyTools + settingsTools + noteTools
        + mediaTools + readTools + transcriptTools + lookTools + commandTools

    public static func named(_ name: String) -> Tool? { byName[name] }
    private static let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static let writeOptions = [
        Parameter("ifRevision", .integer, "Fail unless the project is still at this revision"),
        Parameter("dryRun", .boolean, "Check and show the change without making it"),
    ]

    // MARK: commands

    static let commandTools: [Tool] = CommandRegistry.all.filter { $0.spec.exposedAsTool }.map { type in
        let name = type.name
        return Tool(name, .write, type.spec.summary, type.spec.parameters + writeOptions) { editor, args in
            let session = try await editor.requireSession()
            let command = try CommandRegistry.decode(
                name: name, arguments: args.json(removing: ["ifRevision", "dryRun"]).data())
            let r = try await session.apply([command], ifRevision: try args.int("ifRevision"),
                                            dryRun: try args.bool("dryRun") ?? false)
            return try JSONValue(encoding: r)
        }
    }

    // MARK: app

    static let appTools: [Tool] = [
        Tool("app.info", .read, "Editor version, settings location, open project and the number of tools.") { editor, _ in
            let s = await editor.session
            return .object([
                "name": .string("Danial MCP Editor"),
                "version": .string(Editor.version),
                "settingsFile": .string(editor.settings.fileURL.path),
                "openProject": s.map { .string($0.url.path) } ?? .null,
                "toolCount": .number(Double(ToolCatalog.all.count)),
                "commands": .array(CommandRegistry.all.map { .string($0.name) }),
            ])
        },
    ]

    // MARK: projects

    static let projectTools: [Tool] = [
        Tool("project.list", .read, "Recently opened projects.") { editor, _ in
            .object(["projects": .array(editor.settings.current.recentProjects.map { path in
                .object(["path": .string(path), "exists": .bool(FileManager.default.fileExists(atPath: path))])
            })])
        },
        Tool("project.create", .manage, "Create a project and open it. Settings come from a preset, overridden by any size, frame rate or dynamic range given.", [
            Parameter("path", .string, "Where to create the project package (.dmeproj is added)", required: true),
            Parameter("name", .string, "Project name; default the file name"),
            Parameter("preset", .string, "Preset from settings.projectPresets, for example reel, youtube or lesson"),
            Parameter("width", .integer, "Canvas width"),
            Parameter("height", .integer, "Canvas height"),
            Parameter("frameRate", .integer, "Frames per second"),
            Parameter("dynamicRange", .oneOf(DynamicRange.allCases.map(\.rawValue)), "sdr or hlg"),
        ]) { editor, args in
            let presets = editor.settings.current.projectPresets
            var ps: ProjectSettings
            if let name = try args.string("preset") {
                guard let p = presets[name] else {
                    throw EditorError.invalid("no preset \(name); presets are \(presets.keys.sorted().joined(separator: ", "))", parameter: "preset")
                }
                ps = p
            } else {
                guard args.has("width"), args.has("height"), args.has("frameRate") else {
                    throw EditorError.invalid("give a preset, or width, height and frameRate")
                }
                ps = ProjectSettings(width: 2, height: 2, frameRate: .fps60, dynamicRange: .sdr)
            }
            let change = SetProjectSettings(width: try args.int("width"), height: try args.int("height"),
                                            frameRate: try args.int("frameRate"),
                                            dynamicRange: try args.string("dynamicRange").map {
                                                guard let d = DynamicRange(rawValue: $0) else { throw EditorError.invalid("dynamicRange must be sdr or hlg", parameter: "dynamicRange") }
                                                return d
                                            })
            var probe = Project(id: "probe", name: "", settings: ps)
            try change.apply(to: &probe)
            ps = probe.settings
            let s = try await editor.createProject(at: try args.requiredString("path"), name: try args.string("name"), settings: ps)
            return try await projectSummary(s)
        },
        Tool("project.open", .manage, "Open a project. A project left open by a crash is recovered from its journal.", [
            Parameter("path", .string, "Project package path", required: true),
        ]) { editor, args in
            try await projectSummary(try await editor.openProject(at: try args.requiredString("path")))
        },
        Tool("project.close", .manage, "Save and close the open project.") { editor, _ in
            try await editor.closeProject()
            return .object(["closed": .bool(true)])
        },
        Tool("project.get", .read, "The open project: settings, revision, length, tracks and counts.") { editor, _ in
            try await projectSummary(try await editor.requireSession())
        },
        Tool("project.duplicate", .manage, "Save a copy of the open project under a new path, with a new id. The open project stays open.", [
            Parameter("path", .string, "Path for the copy", required: true),
            Parameter("name", .string, "Name for the copy"),
        ]) { editor, args in
            let s = try await editor.requireSession()
            var p = await s.project
            p.id = .random("project")
            let url = Editor.packageURL(try args.requiredString("path"))
            p.name = try args.string("name") ?? url.deletingPathExtension().lastPathComponent
            let copy = try EditorSession.create(at: url, project: p)
            try await copy.close()
            return .object(["path": .string(url.path), "id": .string(p.id.raw)])
        },
        Tool("project.trash", .manage, "Move a project package to the Trash. It must not be open.", [
            Parameter("path", .string, "Project package path", required: true),
        ]) { editor, args in
            let url = Editor.packageURL(try args.requiredString("path"))
            if let s = await editor.session, s.url.standardizedFileURL == url {
                throw EditorError(.conflict, "close the project before moving it to the Trash")
            }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) else {
                throw EditorError(.notFound, "\(url.path) is not a project")
            }
            var out: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &out)
            return .object(["trashed": .string(url.path), "trashPath": out?.path.map { .string($0) } ?? .null])
        },
    ]

    // MARK: history

    static let historyTools: [Tool] = [
        Tool("history.list", .read, "Changes made since the project was opened, oldest first.", [
            Parameter("since", .integer, "Only changes after this revision"),
            Parameter("limit", .integer, "Most recent changes to return; default 50"),
            Parameter("detail", .boolean, "Include each command's arguments"),
        ]) { editor, args in
            let s = try await editor.requireSession()
            let recs = await s.history(since: try args.int("since") ?? 0, limit: try args.int("limit") ?? 50)
            let detail = try args.bool("detail") ?? false
            return .object([
                "revision": .number(Double(await s.revision)),
                "changes": .array(try recs.map { r in
                    var o: [String: JSONValue] = [
                        "revision": .number(Double(r.revision)), "op": .string(r.op.rawValue),
                        "at": .string(ISO8601DateFormatter().string(from: r.at)),
                        "commands": .array((r.commands ?? []).map { .string($0.name) }),
                    ]
                    if detail { o["detail"] = try JSONValue(encoding: r.commands ?? []) }
                    return .object(o)
                }),
            ])
        },
        Tool("history.undo", .write, "Undo the last change.") { editor, _ in
            let s = try await editor.requireSession()
            return .object(["revision": .number(Double(try await s.undo()))])
        },
        Tool("history.redo", .write, "Redo the last undone change.") { editor, _ in
            let s = try await editor.requireSession()
            return .object(["revision": .number(Double(try await s.redo()))])
        },
        Tool("history.revertTo", .write, "Undo changes until the project is as it was at a revision.", [
            Parameter("revision", .integer, "Target revision", required: true),
        ]) { editor, args in
            let s = try await editor.requireSession()
            return .object(["revision": .number(Double(try await s.revert(to: try args.int("revision")!)))])
        },
        Tool("batch.apply", .write, "Apply several commands as one atomic, single-undo step. If one fails, none is applied.", [
            Parameter("commands", .array(.object), "List of {\"name\": command, \"args\": {...}}, for example {\"name\": \"clip_add\", \"args\": {...}}. Only write commands.", required: true),
        ] + writeOptions) { editor, args in
            let s = try await editor.requireSession()
            guard let list = args.values["commands"]?.arrayValue, !list.isEmpty else {
                throw EditorError.invalid("commands must be a non-empty list", parameter: "commands")
            }
            let commands: [any EditorCommand] = try list.enumerated().map { i, item in
                guard var name = item["name"]?.stringValue else {
                    throw EditorError.invalid("commands[\(i)] needs a name", parameter: "commands")
                }
                // Accept MCP spellings too: clip_add is clip.add.
                if !name.contains("."), let r = name.range(of: "_") { name.replaceSubrange(r, with: ".") }
                guard let t = CommandRegistry.type(named: name), t.spec.exposedAsTool else {
                    throw EditorError.invalid("commands[\(i)]: \(name) is not a write command", parameter: "commands")
                }
                let raw = item["args"] ?? .object([:])
                let known = Set(t.spec.parameters.map(\.name))
                if let bad = raw.objectValue?.keys.sorted().first(where: { !known.contains($0) }) {
                    throw EditorError.invalid("commands[\(i)] (\(name)) has no parameter \"\(bad)\"", parameter: "commands")
                }
                return try CommandRegistry.decode(name: name, arguments: raw.data())
            }
            let r = try await s.apply(commands, ifRevision: try args.int("ifRevision"), dryRun: try args.bool("dryRun") ?? false)
            return try JSONValue(encoding: r)
        },
    ]

    // MARK: settings

    static let settingsTools: [Tool] = [
        Tool("settings.get", .read, "User settings: presets, cut rules, undo depth, MCP port. The MCP token is never returned.") { editor, _ in
            try editor.settings.publicJSON()
        },
        Tool("settings.set", .manage, "Change one user setting by dotted key, for example cutRules.minPause. New project presets can be added under projectPresets.", [
            Parameter("key", .string, "Dotted settings key", required: true),
            Parameter("value", .any, "New value, of the same type as the current one", required: true),
        ]) { editor, args in
            try editor.settings.set(key: try args.requiredString("key"), value: args.values["value"]!)
            return try editor.settings.publicJSON()
        },
    ]

    static func projectSummary(_ s: EditorSession) async throws -> JSONValue {
        let p = await s.project
        return .object([
            "path": .string(s.url.path),
            "id": .string(p.id.raw),
            "name": .string(p.name),
            "settings": try JSONValue(encoding: p.settings),
            "revision": .number(Double(await s.revision)),
            "duration": .number(p.duration.seconds),
            "canUndo": .bool(await s.canUndo),
            "canRedo": .bool(await s.canRedo),
            "tracks": .array(p.tracks.map { t in
                .object([
                    "id": .string(t.id.raw), "kind": .string(t.kind.rawValue), "name": .string(t.name),
                    "muted": .bool(t.muted), "hidden": .bool(t.hidden), "locked": .bool(t.locked),
                    "clipCount": .number(Double(t.clips.count)), "end": .number(t.end.seconds),
                ])
            }),
            "mediaCount": .number(Double(p.media.count)),
            "markerCount": .number(Double(p.markers.count)),
        ])
    }
}
