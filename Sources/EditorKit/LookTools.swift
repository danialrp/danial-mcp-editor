import EditorCore
import Foundation

/// Reading looks and the owner's saved look profiles (C-2). Profiles live in
/// `looks/` next to the settings file, one JSON file each, so a look made once
/// can be loaded into any project.
extension ToolCatalog {
    static func profileFolder(_ editor: Editor) -> URL {
        editor.settings.directory.appendingPathComponent("looks", isDirectory: true)
    }

    /// A saved profile, with an error an agent can act on when the file is
    /// damaged (profiles are plain files that can be edited by hand).
    static func readProfile(_ url: URL, _ name: String) throws -> Look {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw EditorError(.notFound, "no profile named \(name); see look.listProfiles")
        }
        do {
            return try JSONDecoder().decode(Look.self, from: data)
        } catch let e as DecodingError {
            throw EditorError.invalid("profile \(name) is damaged (\(describe(e))); save it again or delete it")
        }
    }

    static func profileURL(_ editor: Editor, _ name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains("/"), !clean.hasPrefix(".") else {
            throw EditorError.invalid("profile names cannot be empty, start with a dot or contain /", parameter: "name")
        }
        return profileFolder(editor).appendingPathComponent(clean + ".json")
    }

    static let lookTools: [Tool] = [
        Tool("look.list", .read, "Looks in the project, with the clips and tracks that use them.") { editor, _ in
            let p = await (try await editor.requireSession()).project
            return .object(["looks": .array(try p.looks.map { l in
                var o = try JSONValue(encoding: l).objectValue ?? [:]
                o["tracks"] = .array(p.tracks.filter { $0.look == l.id }.map { .string($0.id.raw) })
                o["clips"] = .number(Double(p.tracks.reduce(0) { $0 + $1.clips.filter { $0.look == l.id }.count }))
                return .object(o)
            })])
        },
        Tool("look.get", .read, "One look with all its values.", [
            Parameter("id", .id, "Look id", required: true),
        ]) { editor, args in
            let p = await (try await editor.requireSession()).project
            guard let l = p.looks.first(where: { $0.id.raw == (try? args.requiredString("id")) }) else {
                throw EditorError.notFound("look", EntityID(try args.requiredString("id")))
            }
            return try JSONValue(encoding: l)
        },
        Tool("look.saveProfile", .manage, "Save a look as a profile to load later into any project.", [
            Parameter("look", .id, "Look id", required: true),
            Parameter("name", .string, "Profile name; default the look's name"),
            Parameter("replace", .boolean, "Overwrite a profile of the same name"),
        ]) { editor, args in
            let p = await (try await editor.requireSession()).project
            guard var l = p.looks.first(where: { $0.id.raw == (try? args.requiredString("look")) }) else {
                throw EditorError.notFound("look", EntityID(try args.requiredString("look")))
            }
            let name = try args.string("name") ?? l.name
            let url = try profileURL(editor, name)
            if FileManager.default.fileExists(atPath: url.path), try args.bool("replace") != true {
                throw EditorError(.conflict, "a profile named \(name) exists; pass replace true to overwrite it")
            }
            try FileManager.default.createDirectory(at: profileFolder(editor), withIntermediateDirectories: true)
            l.name = name
            try JSON.prettyEncoder.encode(l).write(to: url, options: .atomic)
            return .object(["saved": .string(name), "file": .string(url.path)])
        },
        Tool("look.listProfiles", .read, "Saved look profiles.") { editor, _ in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: profileFolder(editor).path)) ?? []
            return .object(["profiles": .array(files.filter { $0.hasSuffix(".json") }.sorted().map { .string(String($0.dropLast(5))) })])
        },
        Tool("look.renameProfile", .manage, "Rename a saved look profile.", [
            Parameter("name", .string, "Profile name", required: true),
            Parameter("newName", .string, "New name", required: true),
        ]) { editor, args in
            let from = try profileURL(editor, try args.requiredString("name"))
            let to = try profileURL(editor, try args.requiredString("newName"))
            guard FileManager.default.fileExists(atPath: from.path) else {
                throw EditorError(.notFound, "no profile named \(try args.requiredString("name")); see look.listProfiles")
            }
            guard from != to else { return .object(["renamed": .string(try args.requiredString("newName"))]) }
            if FileManager.default.fileExists(atPath: to.path) {
                throw EditorError(.conflict, "a profile named \(try args.requiredString("newName")) exists; delete it or choose another name")
            }
            var l = try readProfile(from, try args.requiredString("name"))
            l.name = try args.requiredString("newName").trimmingCharacters(in: .whitespaces)
            try JSON.prettyEncoder.encode(l).write(to: to, options: .atomic)
            try FileManager.default.trashItem(at: from, resultingItemURL: nil)
            return .object(["renamed": .string(l.name)])
        },
        Tool("look.deleteProfile", .manage, "Move a saved look profile to the Trash. Looks already in projects are not touched.", [
            Parameter("name", .string, "Profile name", required: true),
        ]) { editor, args in
            let url = try profileURL(editor, try args.requiredString("name"))
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EditorError(.notFound, "no profile named \(try args.requiredString("name")); see look.listProfiles")
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return .object(["deleted": .string(try args.requiredString("name"))])
        },
        Tool("look.loadProfile", .write, "Bring a saved profile into the project as a new look, and optionally use it on clips or tracks in the same step.", [
            Parameter("name", .string, "Profile name", required: true),
            Parameter("clips", .array(.id), "Use it on these clips"),
            Parameter("tracks", .array(.id), "Use it on these tracks"),
        ] + writeOptions) { editor, args in
            let session = try await editor.requireSession()
            let url = try profileURL(editor, try args.requiredString("name"))
            var l = try readProfile(url, try args.requiredString("name"))
            l.id = .random("look")
            // Every id in a project is unique, so a profile loaded twice
            // needs new ids for its picked colours too.
            for i in l.picked.indices { l.picked[i].id = .random("color") }
            var commands: [any EditorCommand] = [PutLook(look: l)]
            let clips = try args.strings("clips")?.map { EntityID($0) }
            let tracks = try args.strings("tracks")?.map { EntityID($0) }
            if !(clips ?? []).isEmpty || !(tracks ?? []).isEmpty {
                commands.append(AssignLook(look: l.id, clips: clips, tracks: tracks))
            }
            let r = try await session.apply(commands, ifRevision: try args.int("ifRevision"), dryRun: try args.bool("dryRun") ?? false)
            return .object(["look": .string(l.id.raw), "revision": .number(Double(r.revision))])
        },
    ]
}
