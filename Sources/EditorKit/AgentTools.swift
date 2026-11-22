import EditorCore
import Foundation

/// Onboarding for agents: one call that says how the editor works, what the
/// open project looks like, what notes exist and what changed since they
/// were written, so an agent can start without reading the whole timeline.
public enum AgentTools {
    /// Where the full agent guide lives: in the app bundle, or in the source
    /// tree when run from a build folder.
    static var guideURL: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("agent-guide.md"), FileManager.default.fileExists(atPath: r.path) { return r }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/agent-guide.md")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    static let start = [
        "Read this answer, then notes_read spec (what the edit must become) and progress (where the last session stopped), if they exist.",
        "If notes are older than the project (changesSinceNotes), history_list since their revision shows what changed.",
        "Look with timeline_get, clip_list, frame_sheet and frame_capture; read speech with transcript_find and transcript_get instead of watching the video.",
        "Edit with the write tools; use batch_apply for many edits (one step, one undo); dryRun checks, ifRevision refuses stale state.",
        "Before you stop: notes_write progress (done, next, open questions) and keep spec current. Next time you start from there.",
    ]

    static let rules = [
        "Times are timeline seconds, snapped to the project frame rate. Every write returns the new revision and the commands as applied, with new ids.",
        "Colour is the owner's work: change looks only when asked. Looks go on camera clips or the main track, never on graphics.",
        "Errors say what to change; fix the arguments and call again.",
        "Tool names use _ over MCP (clip_add) and . inside the editor (clip.add).",
        "agent_guide returns the full guide.",
    ]

    static let notesConvention: JSONValue = .object([
        "spec": .string("What this edit must become: goal, format, style, the owner's rules for it. Read first, keep current."),
        "progress": .string("What is done, what is next, open questions. Rewrite at the end of every work session."),
        "other names": .string("Decisions, notes on clips (pass clips and from/to), anything worth keeping. notes_list shows each in one line."),
        "sections": .string("notes_read and notes_write take a section heading, so a long note is read and changed one part at a time."),
    ])

    static func projectSummary(_ p: Project, revision: Int, path: String, canUndo: Bool) throws -> JSONValue {
        var effects: [String: Int] = [:]
        var keyframed = 0, clips = 0
        for t in p.tracks {
            clips += t.clips.count
            for c in t.clips {
                for e in c.effects { effects[e.effect, default: 0] += 1 }
                if !c.keyframes.isEmpty { keyframed += 1 }
            }
        }
        return .object([
            "name": .string(p.name), "path": .string(path), "revision": .number(Double(revision)),
            "settings": try JSONValue(encoding: p.settings),
            "duration": .number(p.duration.seconds), "clips": .number(Double(clips)), "canUndo": .bool(canUndo),
            "tracks": .array(p.tracks.map { t in
                var o: [String: JSONValue] = ["id": .string(t.id.raw), "kind": .string(t.kind.rawValue), "name": .string(t.name),
                                              "clips": .number(Double(t.clips.count)), "end": .number(t.end.seconds)]
                if t.locked { o["locked"] = .bool(true) }
                if t.muted { o["muted"] = .bool(true) }
                if t.hidden { o["hidden"] = .bool(true) }
                if let l = t.look { o["look"] = .string(l.raw) }
                return .object(o)
            }),
            "media": .number(Double(p.media.count)),
            "transcripts": .array(p.transcripts.map {
                .object(["id": .string($0.id.raw), "asset": .string($0.asset.raw), "language": .string($0.language), "words": .number(Double($0.words.count))])
            }),
            "looks": .array(p.looks.map { .object(["id": .string($0.id.raw), "name": .string($0.name), "enabled": .bool($0.enabled)]) }),
            "effectsUsed": .object(effects.mapValues { .number(Double($0)) }),
            "clipsWithKeyframes": .number(Double(keyframed)),
            "markers": .array(p.markers.prefix(50).map { .object(["time": .number($0.time.seconds), "name": .string($0.name)]) }),
        ])
    }

    /// `tools` is every tool of the process, for the tool map.
    public static func make(tools: [Tool]) -> [Tool] {
        let all = tools.map(\.name) + ["agent.onboard", "agent.guide"]
        var groups: [String: [JSONValue]] = [:]
        for n in all.sorted() {
            let g = String(n.split(separator: ".").first ?? Substring(n))
            groups[g, default: []].append(.string(n.replacingOccurrences(of: ".", with: "_")))
        }
        let toolMap = JSONValue.object(groups.mapValues { .array($0) })
        return [
            Tool("agent.onboard", .read, "Start here. How the editor works, the tool map, the open project in brief, its notes (spec and progress in full) and what changed since the notes were written. One call instead of reading the whole project.") { editor, _ in
                var o: [String: JSONValue] = [
                    "editor": .object(["name": .string("Danial MCP Editor"), "version": .string(Editor.version)]),
                    "start": .array(start.map { .string($0) }),
                    "rules": .array(rules.map { .string($0) }),
                    "notesConvention": notesConvention,
                    "tools": toolMap,
                ]
                guard let session = await editor.session else {
                    o["project"] = .null
                    o["next"] = .string("No project is open: project_list shows recent ones, then project_open; or project_create.")
                    return .object(o)
                }
                let (p, rev, undo) = await (session.project, session.revision, session.canUndo)
                o["project"] = try projectSummary(p, revision: rev, path: session.url.path, canUndo: undo)
                let notes = NoteStore.all(session)
                o["notes"] = .array(notes.map { NoteStore.index($0, project: p) })
                for key in ["spec", "progress"] {
                    if let n = notes.first(where: { $0.name == key }) { o[key] = .string(n.body) }
                }
                if let newest = notes.compactMap(\.revision).max(), newest < rev {
                    let since = await session.history(since: newest, limit: 1000)
                    var change: [String: JSONValue] = ["notesRevision": .number(Double(newest)), "projectRevision": .number(Double(rev))]
                    if since.first?.revision == newest + 1 {
                        var counts: [String: Int] = [:]
                        for r in since {
                            if r.op == .undo { counts["undo", default: 0] += 1; continue }
                            for c in r.commands ?? [] { counts[c.name, default: 0] += 1 }
                        }
                        change["commands"] = .object(counts.mapValues { .number(Double($0)) })
                    } else {
                        change["commands"] = .string("not known in this session (the project was reopened); compare with timeline_get")
                    }
                    o["changesSinceNotes"] = .object(change)
                }
                if notes.isEmpty {
                    o["next"] = .string("This project has no notes yet. Ask the owner what the edit must become, then notes_write spec.")
                }
                return .object(o)
            },
            Tool("agent.guide", .read, "The full agent guide (markdown): workflows, cutting rules, colour, effects, notes.", [
                Parameter("section", .string, "Only the part under this heading"),
            ]) { _, args in
                guard let url = guideURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
                    throw EditorError(.notFound, "the agent guide is not installed with this build")
                }
                if let s = try args.string("section") {
                    let n = Note(name: "guide", body: text)
                    guard let part = n.section(s) else {
                        throw EditorError.invalid("no section \(s); headings: \(n.headings.joined(separator: " | "))", parameter: "section")
                    }
                    return .object(["content": .string(part)])
                }
                return .object(["content": .string(text)])
            },
        ]
    }
}
