import EditorCore
import Foundation

/// How a clip is shown to callers: both ranges, plus end and speed.
struct ClipView: Encodable {
    var id: EntityID
    var track: EntityID
    var asset: EntityID
    var start: Time
    var end: Time
    var duration: Time
    var sourceStart: Time
    var sourceEnd: Time
    var speed: Double

    init(_ c: Clip, track: EntityID) {
        id = c.id
        self.track = track
        asset = c.asset
        start = c.start
        end = c.end
        duration = c.duration
        sourceStart = c.sourceStart
        sourceEnd = c.sourceEnd
        speed = (c.speed * 1_000_000).rounded() / 1_000_000
    }
}

extension ToolCatalog {
    static let mediaTools: [Tool] = [
        Tool("media.import", .write, "Add files to the media pool by reference. Files are read where they are and never copied. A file already in the pool is not added twice.", [
            Parameter("paths", .array(.string), "File paths", required: true),
        ] + writeOptions) { editor, args in
            let s = try await editor.requireSession()
            let paths = try args.strings("paths") ?? []
            guard !paths.isEmpty else { throw EditorError.invalid("paths must not be empty", parameter: "paths") }
            let existing = await s.project.media
            var assets: [MediaAsset] = []
            var already: [JSONValue] = []
            var failed: [JSONValue] = []
            for raw in paths {
                let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
                if let a = existing.first(where: { $0.path == url.path }) ?? assets.first(where: { $0.path == url.path }) {
                    already.append(.object(["path": .string(url.path), "id": .string(a.id.raw)]))
                    continue
                }
                do {
                    guard FileManager.default.isReadableFile(atPath: url.path) else {
                        throw EditorError(.notFound, "cannot read \(url.path)")
                    }
                    let info = try await editor.prober.probe(url)
                    assets.append(MediaAsset(id: .random("media"), path: url.path, name: url.lastPathComponent,
                                             fingerprint: try Editor.fingerprint(url), info: info,
                                             kind: info.video?.codec.hasPrefix("image/") == true ? .image : .file))
                } catch {
                    failed.append(.object(["path": .string(url.path), "error": .string("\(error)")]))
                }
            }
            var revision = await s.revision
            if !assets.isEmpty {
                let r = try await s.apply([AddMedia(assets: assets)], ifRevision: try args.int("ifRevision"),
                                          dryRun: try args.bool("dryRun") ?? false)
                revision = r.revision
            }
            return .object([
                "revision": .number(Double(revision)),
                "added": try JSONValue(encoding: assets),
                "alreadyInPool": .array(already),
                "failed": .array(failed),
            ])
        },
        Tool("media.list", .read, "Assets in the media pool.", [
            Parameter("limit", .integer, "Default 100"),
            Parameter("cursor", .integer, "Index to start from, from a previous nextCursor"),
        ]) { editor, args in
            let media = await (try await editor.requireSession()).project.media
            return try page(media, limit: try args.int("limit") ?? 100, cursor: try args.int("cursor") ?? 0, key: "media")
        },
        Tool("media.get", .read, "One media asset, with the clips that use it.", [
            Parameter("id", .id, "Media asset id", required: true),
        ]) { editor, args in
            let p = await (try await editor.requireSession()).project
            let a = try p.asset(EntityID(try args.requiredString("id")))
            let users = p.tracks.flatMap { t in t.clips.filter { $0.asset == a.id }.map { $0.id } }
            return .object(["asset": try JSONValue(encoding: a), "usedByClips": try JSONValue(encoding: users)])
        },
        Tool("media.probe", .read, "Read a file's properties without adding it.", [
            Parameter("path", .string, "File path", required: true),
        ]) { editor, args in
            let url = URL(fileURLWithPath: (try args.requiredString("path") as NSString).expandingTildeInPath)
            return try JSONValue(encoding: try await editor.prober.probe(url))
        },
        Tool("media.relink", .write, "Point a media asset at a moved or replaced file.", [
            Parameter("id", .id, "Media asset id", required: true),
            Parameter("path", .string, "New file path", required: true),
        ] + writeOptions) { editor, args in
            let s = try await editor.requireSession()
            let url = URL(fileURLWithPath: (try args.requiredString("path") as NSString).expandingTildeInPath).standardizedFileURL
            let info = try await editor.prober.probe(url)
            let cmd = SetMediaPath(id: EntityID(try args.requiredString("id")), path: url.path, name: url.lastPathComponent,
                                   fingerprint: try Editor.fingerprint(url), info: info)
            return try JSONValue(encoding: try await s.apply([cmd], ifRevision: try args.int("ifRevision"),
                                                             dryRun: try args.bool("dryRun") ?? false))
        },
    ]

    static let readTools: [Tool] = [
        Tool("timeline.get", .read, "Tracks and the clips in a time range, in time order per track.", [
            Parameter("start", .seconds, "Range start; default 0"),
            Parameter("end", .seconds, "Range end; default the end of the project"),
            Parameter("tracks", .array(.id), "Only these tracks"),
            Parameter("limit", .integer, "Most clips to return; default 500"),
            Parameter("cursor", .integer, "From a previous nextCursor"),
        ]) { editor, args in
            let s = try await editor.requireSession()
            let p = await s.project
            let clips = try selectClips(p, args)
            var out = try page(clips, limit: try args.int("limit") ?? 500, cursor: try args.int("cursor") ?? 0, key: "clips")
            if case .object(var o) = out, case .object(let summary) = try await projectSummary(s) {
                o["revision"] = summary["revision"]
                o["duration"] = summary["duration"]
                o["tracks"] = summary["tracks"]
                out = .object(o)
            }
            return out
        },
        Tool("clip.list", .read, "Clips matching a filter, in time order per track.", [
            Parameter("tracks", .array(.id), "Only these tracks"),
            Parameter("asset", .id, "Only clips of this media asset"),
            Parameter("start", .seconds, "Only clips ending after this time"),
            Parameter("end", .seconds, "Only clips starting before this time"),
            Parameter("limit", .integer, "Default 500"),
            Parameter("cursor", .integer, "From a previous nextCursor"),
        ]) { editor, args in
            let p = await (try await editor.requireSession()).project
            return try page(try selectClips(p, args), limit: try args.int("limit") ?? 500,
                            cursor: try args.int("cursor") ?? 0, key: "clips")
        },
        Tool("clip.get", .read, "One clip with everything set on it: timing, speed, sound (gain, mute, fades), transform, opacity, look, effects and keyframes.", [
            Parameter("id", .id, "Clip id", required: true),
        ]) { editor, args in
            let p = await (try await editor.requireSession()).project
            let (t, c) = try p.locate(clip: EntityID(try args.requiredString("id")))
            let clip = p.tracks[t].clips[c]
            guard case .object(var full) = try JSONValue(encoding: clip),
                  case .object(let view) = try JSONValue(encoding: ClipView(clip, track: p.tracks[t].id)) else {
                return try JSONValue(encoding: ClipView(clip, track: p.tracks[t].id))
            }
            for (k, v) in view { full[k] = v }
            return .object(full)
        },
        Tool("marker.list", .read, "Markers in time order.") { editor, _ in
            let p = await (try await editor.requireSession()).project
            return .object(["markers": try JSONValue(encoding: p.markers)])
        },
    ]

    static func selectClips(_ p: Project, _ args: Args) throws -> [ClipView] {
        let trackFilter = try args.strings("tracks").map { Set($0.map { EntityID($0) }) }
        if let trackFilter { for id in trackFilter { _ = try p.trackIndex(id) } }
        let asset = try args.string("asset").map { EntityID($0) }
        let start = try args.time("start") ?? .zero
        let end = try args.time("end") ?? Time(ticks: .max)
        var out: [ClipView] = []
        for t in p.tracks where trackFilter?.contains(t.id) ?? true {
            var i = t.firstClipIndex(endingAfter: start)
            while i < t.clips.count, t.clips[i].start < end {
                let c = t.clips[i]
                if asset == nil || c.asset == asset { out.append(ClipView(c, track: t.id)) }
                i += 1
            }
        }
        return out
    }

    static func page<T: Encodable>(_ items: [T], limit: Int, cursor: Int, key: String) throws -> JSONValue {
        guard limit > 0 else { throw EditorError.invalid("limit must be positive", parameter: "limit") }
        guard cursor >= 0, cursor <= items.count else { throw EditorError.invalid("cursor is out of range", parameter: "cursor") }
        let end = min(items.count, cursor + limit)
        return .object([
            key: try JSONValue(encoding: Array(items[cursor..<end])),
            "total": .number(Double(items.count)),
            "nextCursor": end < items.count ? .number(Double(end)) : .null,
        ])
    }
}
