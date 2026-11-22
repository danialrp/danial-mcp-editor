import EditorCore
import Foundation

/// Markdown notes kept inside the project package (`notes/*.md`), for agents
/// and the owner: the spec of the edit, progress, decisions, notes on clips.
/// Each file starts with a small header:
///
///     ---
///     title: Spec
///     clips: clip_a, clip_b
///     from: 12.5
///     to: 40
///     revision: 118
///     updated: 2026-11-20T10:00:00Z
///     ---
///
/// `revision` is the project revision when the note was written, so a reader
/// can ask `history_list` for what changed since.
public struct Note: Sendable {
    public var name: String
    public var title: String?
    public var clips: [String] = []
    public var from: Double?
    public var to: Double?
    public var revision: Int?
    public var updated: String?
    public var body: String

    static let fields = ["title", "clips", "from", "to", "revision", "updated"]

    public init(name: String, body: String) {
        self.name = name
        self.body = body
    }

    public init(name: String, file text: String) {
        self.name = name
        var body = text
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let header = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            body = String(text[end.upperBound...])
            for line in header.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let k = line[..<colon].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch k {
                case "title": title = v
                case "clips": clips = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                case "from": from = Double(v)
                case "to": to = Double(v)
                case "revision": revision = Int(v)
                case "updated": updated = v
                default: break
                }
            }
        }
        self.body = body
    }

    public var file: String {
        var h = ["---"]
        if let title { h.append("title: \(title)") }
        if !clips.isEmpty { h.append("clips: \(clips.joined(separator: ", "))") }
        if let from { h.append("from: \(from)") }
        if let to { h.append("to: \(to)") }
        if let revision { h.append("revision: \(revision)") }
        if let updated { h.append("updated: \(updated)") }
        h.append("---")
        return h.joined(separator: "\n") + "\n" + body
    }

    /// The first line of text that is not a heading, shortened.
    public var summary: String {
        let line = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        return line.count > 160 ? String(line.prefix(157)) + "..." : line
    }

    // MARK: sections

    /// Heading level and text of a line, or nil.
    static func heading(_ line: Substring) -> (Int, String)? {
        let level = line.prefix { $0 == "#" }.count
        guard level > 0, level <= 6, line.dropFirst(level).first == " " else { return nil }
        return (level, line.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    /// Line range of the section under `title` (heading included), up to the
    /// next heading of the same or a higher level.
    static func section(_ lines: [Substring], _ title: String) -> Range<Int>? {
        let want = title.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard let start = lines.firstIndex(where: { heading($0)?.1.lowercased() == want }), let (level, _) = heading(lines[start]) else { return nil }
        var end = start + 1
        while end < lines.count, (heading(lines[end]).map { $0.0 > level } ?? true) { end += 1 }
        return start..<end
    }

    public func section(_ title: String) -> String? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        return Self.section(lines, title).map { lines[$0].joined(separator: "\n") }
    }

    /// Replaces the text under a heading, or adds the section at the end.
    public mutating func replaceSection(_ title: String, with text: String) {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let clean = title.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if let r = Self.section(lines, clean) {
            let head = lines[r.lowerBound]
            lines.replaceSubrange(r, with: [head] + text.split(separator: "\n", omittingEmptySubsequences: false) + [""])
            body = lines.joined(separator: "\n")
        } else {
            if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
            body += "\n## \(clean)\n\(text)\n"
        }
    }

    public var headings: [String] {
        body.split(separator: "\n").compactMap { Self.heading($0).map { String(repeating: "#", count: $0.0) + " " + $0.1 } }
    }
}

/// Reading and writing notes in the open project's package.
public enum NoteStore {
    private static let lock = NSLock()

    public static func folder(_ session: EditorSession) -> URL {
        session.url.appendingPathComponent("notes", isDirectory: true)
    }

    public static func cleanName(_ raw: String) throws -> String {
        var n = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if n.hasSuffix(".md") { n.removeLast(3) }
        guard n.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            throw EditorError.invalid("note names are lower-case letters, digits, dots, dashes or underscores, for example spec or clip-intro", parameter: "name")
        }
        return n
    }

    public static func all(_ session: EditorSession) -> [Note] {
        let dir = folder(session)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".md") }.sorted().compactMap { f in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) else { return nil }
            return Note(name: String(f.dropLast(3)), file: text)
        }
    }

    public static func read(_ session: EditorSession, _ name: String) throws -> Note {
        let n = try cleanName(name)
        guard let text = try? String(contentsOf: folder(session).appendingPathComponent(n + ".md"), encoding: .utf8) else {
            throw EditorError(.notFound, "no note named \(n); notes_list shows the notes")
        }
        return Note(name: n, file: text)
    }

    public static func write(_ session: EditorSession, _ note: Note) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: folder(session), withIntermediateDirectories: true)
            try Data(note.file.utf8).write(to: folder(session).appendingPathComponent(note.name + ".md"), options: .atomic)
        }
    }

    /// Moves a note to the Trash.
    public static func remove(_ session: EditorSession, _ name: String) throws {
        let n = try cleanName(name)
        let url = folder(session).appendingPathComponent(n + ".md")
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditorError(.notFound, "no note named \(n)") }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    static func index(_ n: Note, project p: Project) -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(n.name), "summary": .string(n.summary), "bytes": .number(Double(n.body.utf8.count))]
        if let t = n.title { o["title"] = .string(t) }
        if !n.clips.isEmpty {
            o["clips"] = .array(n.clips.map { .string($0) })
            let gone = n.clips.filter { !p.containsID(EntityID($0)) }
            if !gone.isEmpty { o["clipsNoLongerInProject"] = .array(gone.map { .string($0) }) }
        }
        if let f = n.from { o["from"] = .number(f) }
        if let t = n.to { o["to"] = .number(t) }
        if let r = n.revision { o["revision"] = .number(Double(r)) }
        if let u = n.updated { o["updated"] = .string(u) }
        return .object(o)
    }
}

extension ToolCatalog {
    static let noteTools: [Tool] = [
        Tool("notes.list", .read, "The project's notes (spec, progress, decisions, notes on clips) with a one-line summary each, the clips and times they are about, and the revision they were written at. Cheap: call it instead of reading every note.", [
            Parameter("clip", .id, "Only notes about this clip"),
        ]) { editor, args in
            let session = try await editor.requireSession()
            let (p, rev) = await (session.project, session.revision)
            var notes = NoteStore.all(session)
            if let c = try args.string("clip") { notes = notes.filter { $0.clips.contains(c) } }
            return .object(["notes": .array(notes.map { NoteStore.index($0, project: p) }), "projectRevision": .number(Double(rev))])
        },
        Tool("notes.read", .read, "Read a note, or one section of it by heading to save tokens.", [
            Parameter("name", .string, "Note name, for example spec", required: true),
            Parameter("section", .string, "Only the part under this heading"),
        ]) { editor, args in
            let session = try await editor.requireSession()
            let n = try NoteStore.read(session, try args.requiredString("name"))
            var o = NoteStore.index(n, project: await session.project).objectValue ?? [:]
            if let s = try args.string("section") {
                guard let text = n.section(s) else {
                    throw EditorError.invalid("\(n.name) has no section \(s); its headings: \(n.headings.joined(separator: " | "))", parameter: "section")
                }
                o["content"] = .string(text)
            } else {
                o["content"] = .string(n.body)
                o["headings"] = .array(n.headings.map { .string($0) })
            }
            return .object(o)
        },
        Tool("notes.write", .manage, "Write a note in the project. mode replace (default) writes the whole text, append adds to the end, section replaces the text under one heading (or adds that section). The note records the current project revision.", [
            Parameter("name", .string, "Note name: spec for what the edit must become, progress for what is done and next, or any other name", required: true),
            Parameter("content", .string, "Markdown text", required: true),
            Parameter("mode", .oneOf(["replace", "append", "section"]), "How to write; default replace"),
            Parameter("section", .string, "Heading to replace, for mode section"),
            Parameter("title", .string, "Title shown in notes_list"),
            Parameter("clips", .array(.id), "Clips the note is about"),
            Parameter("from", .seconds, "Start of the timeline range the note is about"),
            Parameter("to", .seconds, "End of that range"),
        ]) { editor, args in
            let session = try await editor.requireSession()
            let name = try NoteStore.cleanName(try args.requiredString("name"))
            let content = try args.requiredString("content")
            var n = (try? NoteStore.read(session, name)) ?? Note(name: name, body: "")
            switch try args.string("mode") ?? "replace" {
            case "append":
                if !n.body.isEmpty, !n.body.hasSuffix("\n") { n.body += "\n" }
                n.body += content + (content.hasSuffix("\n") ? "" : "\n")
            case "section":
                guard let s = try args.string("section") else { throw EditorError.invalid("mode section needs section", parameter: "section") }
                n.replaceSection(s, with: content)
            default:
                n.body = content + (content.hasSuffix("\n") ? "" : "\n")
            }
            if let t = try args.string("title") { n.title = t }
            if let c = try args.strings("clips") { n.clips = c }
            if args.has("from") { n.from = try args.double("from") }
            if args.has("to") { n.to = try args.double("to") }
            n.revision = await session.revision
            n.updated = ISO8601DateFormatter().string(from: Date())
            try NoteStore.write(session, n)
            return NoteStore.index(n, project: await session.project)
        },
        Tool("notes.find", .read, "Search all notes for text; returns matching lines with their note and heading.", [
            Parameter("query", .string, "Text to find, case-insensitive", required: true),
        ]) { editor, args in
            let session = try await editor.requireSession()
            let q = try args.requiredString("query").lowercased()
            var hits: [JSONValue] = []
            for n in NoteStore.all(session) {
                var heading = ""
                for line in n.body.split(separator: "\n") {
                    if let h = Note.heading(line) { heading = h.1 }
                    if line.lowercased().contains(q) {
                        hits.append(.object(["note": .string(n.name), "heading": .string(heading), "line": .string(String(line))]))
                    }
                }
            }
            return .object(["matches": .array(Array(hits.prefix(200)))])
        },
        Tool("notes.remove", .manage, "Move a note to the Trash.", [
            Parameter("name", .string, "Note name", required: true),
        ]) { editor, args in
            let session = try await editor.requireSession()
            try NoteStore.remove(session, try args.requiredString("name"))
            return .object(["removed": .string(try NoteStore.cleanName(try args.requiredString("name")))])
        },
    ]
}
