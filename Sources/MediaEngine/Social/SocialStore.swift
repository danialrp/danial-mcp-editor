import EditorCore
import EditorKit
import Foundation
import UniformTypeIdentifiers

/// One downloaded file of a post.
public struct SocialFile: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case video, audio, image, subtitles, other }
    public var name: String
    public var kind: Kind
    public var bytes: Int
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    /// Subtitle language, from the file name (`id.en.vtt`).
    public var language: String?

    public init(name: String, kind: Kind, bytes: Int) {
        self.name = name
        self.kind = kind
        self.bytes = bytes
    }

    public static func kind(of name: String) -> Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["vtt", "srt", "ass", "ssa", "ttml", "srv1", "srv2", "srv3", "json3", "lrc"].contains(ext) { return .subtitles }
        guard let t = UTType(filenameExtension: ext) else { return .other }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .movie) || t.conforms(to: .video) || t.conforms(to: .audiovisualContent) { return .video }
        return .other
    }
}

/// The sidecar of a download (`info.json` in its folder).
public struct SocialItem: Codable, Equatable, Sendable {
    public var id: String
    public var url: String
    public var platform: String
    public var downloadedAt: Date
    public var what: String
    /// yt-dlp, yt-dlp thumbnails, or page tags (og:image, og:video).
    public var source: String
    public var metadata: SocialMetadata
    public var files: [SocialFile]
    public var warnings: [String]

    public init(id: String, url: String, platform: String, downloadedAt: Date, what: String, source: String,
                metadata: SocialMetadata, files: [SocialFile], warnings: [String] = []) {
        self.id = id
        self.url = url
        self.platform = platform
        self.downloadedAt = downloadedAt
        self.what = what
        self.source = source
        self.metadata = metadata
        self.files = files
        self.warnings = warnings
    }
}

/// Where downloads live and how they are listed and cleaned up. Each
/// download is a folder named `<platform>-<post key>` holding the files,
/// `info.json`, and `inspect/` for frames and sheets.
public enum SocialStore {
    public static let sidecar = "info.json"
    public static let inspectFolder = "inspect"

    public enum Location: String, Codable, Sendable { case project, cache }

    /// The cache folder used when no project is open.
    public static func cacheRoot(_ settings: UserSettingsStore) -> URL {
        let s = settings.current.downloader.cacheFolder
        if !s.isEmpty { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true) }
        return settings.directory.appendingPathComponent("downloads", isDirectory: true)
    }

    /// The downloads folder inside a project package.
    public static func projectRoot(_ package: URL, _ settings: UserSettingsStore) throws -> URL {
        let rel = settings.current.downloader.projectFolder
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.split(separator: "/").contains("..") else {
            throw EditorError.invalid("downloader.projectFolder must be a folder name inside the project, such as \"downloads\"")
        }
        return package.appendingPathComponent(rel, isDirectory: true)
    }

    /// Where a new download goes: the open project, else the cache.
    public static func root(_ editor: Editor) async throws -> (URL, Location) {
        if let s = await editor.session { return (try projectRoot(s.url, editor.settings), .project) }
        return (cacheRoot(editor.settings), .cache)
    }

    /// All roots that may hold downloads, the open project's first.
    public static func roots(_ editor: Editor) async throws -> [(URL, Location)] {
        var r: [(URL, Location)] = []
        if let s = await editor.session { r.append((try projectRoot(s.url, editor.settings), .project)) }
        r.append((cacheRoot(editor.settings), .cache))
        return r
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func write(_ item: SocialItem, in folder: URL) throws {
        try encoder.encode(item).write(to: folder.appendingPathComponent(sidecar), options: .atomic)
    }

    public static func read(_ folder: URL) -> SocialItem? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent(sidecar)) else { return nil }
        return try? decoder.decode(SocialItem.self, from: d)
    }

    /// The media files of a download folder, by name: everything but the
    /// sidecar, the inspect folder and unfinished parts.
    public static func mediaFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().filter { n in
            n != sidecar && n != inspectFolder && !n.hasPrefix(".") && !n.hasSuffix(".part") && !n.hasSuffix(".ytdl")
                && !n.contains(".part-Frag") && !n.hasSuffix(".temp")
        }.map { folder.appendingPathComponent($0) }
    }

    /// File entries for the folder's media, probed for length and size.
    public static func describe(_ folder: URL, prober: any MediaProber) async -> [SocialFile] {
        var out: [SocialFile] = []
        for url in mediaFiles(in: folder) {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var f = SocialFile(name: url.lastPathComponent, kind: SocialFile.kind(of: url.lastPathComponent), bytes: bytes)
            switch f.kind {
            case .video, .audio, .image:
                if let info = try? await prober.probe(url) {
                    if f.kind != .image { f.duration = info.duration.seconds }
                    f.width = info.video?.width
                    f.height = info.video?.height
                    // An "mp4" with no picture is sound only.
                    if f.kind == .video, info.video == nil, info.audio != nil { f.kind = .audio }
                }
            case .subtitles:
                let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".")
                if parts.count >= 2 { f.language = String(parts.last!) }
            case .other: break
            }
            out.append(f)
        }
        return out
    }

    /// Bytes under a folder.
    public static func size(_ folder: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var n = 0
        for case let u as URL in e {
            if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { n += v.fileSize ?? 0 }
        }
        return n
    }

    public struct Entry: Sendable {
        public var folder: URL
        public var location: Location
        public var item: SocialItem
    }

    /// Every download folder with a sidecar.
    public static func list(_ editor: Editor) async throws -> [Entry] {
        var out: [Entry] = []
        for (root, loc) in try await roots(editor) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for n in names.sorted() {
                let f = root.appendingPathComponent(n, isDirectory: true)
                if let item = read(f) { out.append(Entry(folder: f, location: loc, item: item)) }
            }
        }
        return out
    }

    /// The download with this id, from the open project first.
    public static func find(_ id: String, _ editor: Editor) async throws -> Entry {
        let all = try await list(editor)
        guard let e = all.first(where: { $0.item.id == id }) else {
            let known = all.map(\.item.id)
            throw EditorError(.notFound, "no download \(id); " + (known.isEmpty ? "there are none, use social.download first" : "downloads are \(known.joined(separator: ", "))"), parameter: "id")
        }
        return e
    }

    /// Media assets of the open project whose file is in the folder, and
    /// the clips that use them.
    public static func usage(_ folder: URL, in project: Project?) -> (assets: [MediaAsset], clips: [EntityID]) {
        guard let project else { return ([], []) }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let assets = project.media.filter {
            URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base)
        }
        let ids = Set(assets.map(\.id))
        let clips = project.tracks.flatMap(\.clips).filter { ids.contains($0.asset) }.map(\.id)
        return (assets, clips)
    }

    public struct CleanupResult: Sendable {
        public var trashed: [JSONValue] = []
        public var refused: [JSONValue] = []
        public var bytesFreed = 0
        public var removedFromPool: [EntityID] = []
    }

    /// Moves downloads to the Trash. A download whose files are used by
    /// clips of the open project is refused unless `force`. Pool entries
    /// that no clip uses are removed first, so the pool points at no
    /// trashed file.
    public static func cleanup(ids: [String]?, all: Bool, force: Bool, editor: Editor) async throws -> CleanupResult {
        let entries = try await list(editor)
        var chosen: [Entry]
        if all {
            chosen = entries
        } else {
            guard let ids, !ids.isEmpty else { throw EditorError.invalid("give ids, or all: true", parameter: "ids") }
            chosen = []
            for id in ids {
                let m = entries.filter { $0.item.id == id }
                guard !m.isEmpty else {
                    throw EditorError(.notFound, "no download \(id); downloads are \(entries.map(\.item.id).joined(separator: ", "))", parameter: "ids")
                }
                chosen += m
            }
        }
        var r = CleanupResult()
        let session = await editor.session
        for e in chosen {
            let project = await session?.project
            let (assets, clips) = usage(e.folder, in: project)
            if !clips.isEmpty && !force {
                r.refused.append(.object([
                    "id": .string(e.item.id), "location": .string(e.location.rawValue),
                    "reason": .string("used by \(clips.count) clip(s) in the open project (\(clips.prefix(10).map(\.raw).joined(separator: ", "))); remove those clips first, or pass force: true to trash it anyway (the clips then show missing media)"),
                ]))
                continue
            }
            var removed: [EntityID] = []
            if let session, !assets.isEmpty, clips.isEmpty {
                _ = try await session.apply([RemoveMedia(ids: assets.map(\.id))], ifRevision: nil, dryRun: false)
                removed = assets.map(\.id)
            }
            let bytes = size(e.folder)
            var out: NSURL?
            try FileManager.default.trashItem(at: e.folder, resultingItemURL: &out)
            r.bytesFreed += bytes
            r.removedFromPool += removed
            var o: [String: JSONValue] = [
                "id": .string(e.item.id), "location": .string(e.location.rawValue), "folder": .string(e.folder.path),
                "bytes": .number(Double(bytes)), "trashPath": out?.path.map { .string($0) } ?? .null,
            ]
            if !removed.isEmpty { o["removedFromPool"] = .array(removed.map { .string($0.raw) }) }
            if !clips.isEmpty { o["clipsLeftWithoutMedia"] = .array(clips.map { .string($0.raw) }) }
            r.trashed.append(.object(o))
        }
        return r
    }
}
