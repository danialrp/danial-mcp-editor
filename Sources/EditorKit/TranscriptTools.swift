import EditorCore
import Foundation

extension ToolCatalog {
    static let transcriptTools: [Tool] = [
        Tool("transcript.list", .read, "Stored transcripts: which file, which part of it, how many words.") { editor, _ in
            let p = await (try await editor.requireSession()).project
            return .object(["transcripts": .array(p.transcripts.map { t in
                .object(["id": .string(t.id.raw), "asset": .string(t.asset.raw), "language": .string(t.language),
                         "engine": .string(t.engine), "sourceStart": .number(t.sourceStart.seconds),
                         "sourceEnd": .number(t.sourceEnd.seconds), "words": .number(Double(t.words.count))])
            })])
        },
        Tool("transcript.get", .read, "Words of a transcript at their current timeline places, so they follow every cut and speed change. Words that were cut out are left out.", [
            Parameter("id", .id, "Transcript id; default the newest transcript of the asset"),
            Parameter("asset", .id, "Media asset id, when no transcript id is given"),
            Parameter("start", .seconds, "Only words from this timeline time"),
            Parameter("end", .seconds, "Only words before this timeline time"),
            Parameter("tracks", .array(.id), "Only clips on these tracks; default every track"),
            Parameter("source", .boolean, "Return the words in file time instead, cut or not"),
            Parameter("limit", .integer, "Most words to return; default 2000"),
            Parameter("cursor", .integer, "From a previous nextCursor"),
        ]) { editor, args in
            let p = await (try await editor.requireSession()).project
            let t = try pick(p, args)
            if try args.bool("source") ?? false {
                return try page(t.words, limit: try args.int("limit") ?? 2000, cursor: try args.int("cursor") ?? 0, key: "words")
            }
            let start = try args.time("start") ?? .zero
            let end = try args.time("end") ?? Time(ticks: .max)
            let only = try args.strings("tracks").map { Set($0.map { EntityID($0) }) }
            let words = p.timelineWords(t, tracks: only).filter { $0.start >= start && $0.start < end }.map {
                TimelineWord(text: $0.word.text, start: $0.start, end: $0.end, sourceStart: $0.word.start, clip: $0.clip)
            }
            var out = try page(words, limit: try args.int("limit") ?? 2000, cursor: try args.int("cursor") ?? 0, key: "words")
            if case .object(var o) = out {
                o["transcript"] = .string(t.id.raw)
                o["text"] = .string(words.map(\.text).joined(separator: " "))
                out = .object(o)
            }
            return out
        },
        Tool("transcript.find", .read, "Find a word or phrase in a transcript; returns each match with its timeline time (and file time).", [
            Parameter("text", .string, "Word or phrase to find", required: true),
            Parameter("id", .id, "Transcript id; default the newest transcript of the asset"),
            Parameter("asset", .id, "Media asset id, when no transcript id is given"),
        ]) { editor, args in
            let p = await (try await editor.requireSession()).project
            let t = try pick(p, args)
            let needle = try args.requiredString("text").split(separator: " ").map { String($0) }
            guard !needle.isEmpty else { throw EditorError.invalid("text is empty", parameter: "text") }
            let placed = p.timelineWords(t)
            let words = t.words
            var matches: [JSONValue] = []
            for i in 0..<max(0, words.count - needle.count + 1) {
                guard (0..<needle.count).allSatisfy({ words[i + $0].text.contains(needle[$0]) }) else { continue }
                let w0 = words[i], w1 = words[i + needle.count - 1]
                let onTimeline = placed.first { $0.word == w0 }
                matches.append(.object([
                    "text": .string(words[i..<(i + needle.count)].map(\.text).joined(separator: " ")),
                    "sourceStart": .number(w0.start.seconds), "sourceEnd": .number(w1.end.seconds),
                    "start": onTimeline.map { .number($0.start.seconds) } ?? .null,
                    "clip": onTimeline.map { .string($0.clip.raw) } ?? .null,
                ]))
            }
            return .object(["matches": .array(matches)])
        },
        Tool("transcript.import", .write, "Store a transcript from a JSON file: either {\"words\": [{\"text\" or \"word\", \"start\", \"end\"}]} or {\"segments\": [{\"words\": [...]}]} (the shape the Edits transcription tool writes). Times are seconds in the media file.", [
            Parameter("path", .string, "JSON file", required: true),
            Parameter("asset", .id, "Media asset the words belong to", required: true),
            Parameter("offset", .seconds, "Add this to every time, when the file was transcribed from a later start"),
            Parameter("language", .string, "Language code; default from the file or en"),
        ] + writeOptions) { editor, args in
            let session = try await editor.requireSession()
            let url = URL(fileURLWithPath: (try args.requiredString("path") as NSString).expandingTildeInPath)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw EditorError(.notFound, "cannot read \(url.path); give the path of a transcript JSON file")
            }
            let json: JSONValue
            do { json = try JSONValue.parse(data) } catch {
                throw EditorError.invalid("\(url.lastPathComponent) is not JSON; give a transcript with words (text, start, end)", parameter: "path")
            }
            let raw = json["words"]?.arrayValue ?? (json["segments"]?.arrayValue ?? []).flatMap { $0["words"]?.arrayValue ?? [] }
            let offset = try args.time("offset") ?? .zero
            let words: [TranscriptWord] = raw.compactMap { w in
                guard let text = (w["text"] ?? w["word"])?.stringValue, let s = w["start"]?.doubleValue, let e = w["end"]?.doubleValue,
                      abs(s) <= Time.maxSeconds, abs(e) <= Time.maxSeconds else { return nil }
                return TranscriptWord(text: text.trimmingCharacters(in: .whitespaces), start: Time(seconds: s) + offset, end: Time(seconds: e) + offset)
            }.sorted { $0.start < $1.start }
            guard let first = words.first, let last = words.last else { throw EditorError.invalid("no words found in \(url.path)") }
            let t = Transcript(id: .random("transcript"), asset: EntityID(try args.requiredString("asset")),
                               language: try args.string("language") ?? json["language"]?.stringValue ?? "en",
                               engine: json["engine"]?.stringValue ?? "import", sourceStart: first.start, sourceEnd: last.end, words: words)
            let r = try await session.apply([AddTranscript(transcript: t)], ifRevision: try args.int("ifRevision"),
                                            dryRun: try args.bool("dryRun") ?? false)
            return .object(["transcript": .string(t.id.raw), "words": .number(Double(words.count)), "revision": .number(Double(r.revision))])
        },
    ]

    static func pick(_ p: Project, _ args: Args) throws -> Transcript {
        if let id = try args.string("id") {
            guard let t = p.transcripts.first(where: { $0.id.raw == id }) else { throw EditorError.notFound("transcript", EntityID(id)) }
            return t
        }
        guard let a = try args.string("asset") else { throw EditorError.invalid("give id or asset") }
        guard let t = p.transcripts.last(where: { $0.asset.raw == a }) else {
            throw EditorError(.notFound, "media \(a) has no transcript; make one with transcript.create or transcript.import")
        }
        return t
    }
}

struct TimelineWord: Encodable {
    var text: String
    var start: Time
    var end: Time
    var sourceStart: Time
    var clip: EntityID
}
