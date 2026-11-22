import EditorCore
import EditorKit
import Foundation

/// Social-media downloads (YouTube, Pinterest, Instagram, X) for agents
/// that need a reference: fetch, inspect, use, clean up.
public enum SocialTools {
    public static func make(_ media: MediaContext, jobs: JobCenter) -> [Tool] {
        let editor = media.editor

        @Sendable func fileJSON(_ files: [SocialFile]) throws -> JSONValue { try JSONValue(encoding: files) }

        @Sendable func entryJSON(_ e: SocialStore.Entry, project: Project?) -> JSONValue {
            let (assets, clips) = SocialStore.usage(e.folder, in: project)
            return .object([
                "id": .string(e.item.id), "location": .string(e.location.rawValue), "folder": .string(e.folder.path),
                "url": .string(e.item.url), "platform": .string(e.item.platform),
                "title": e.item.metadata.title.map { .string($0) } ?? .null,
                "downloadedAt": .string(ISO8601DateFormatter().string(from: e.item.downloadedAt)),
                "files": .array(e.item.files.map { .object(["name": .string($0.name), "kind": .string($0.kind.rawValue), "bytes": .number(Double($0.bytes))]) }),
                "bytes": .number(Double(SocialStore.size(e.folder))),
                "imported": .bool(!assets.isEmpty), "mediaIds": .array(assets.map { .string($0.id.raw) }),
                "usedByClips": .number(Double(clips.count)),
            ])
        }

        return [
            Tool("social.download", .manage, "Download a post from YouTube, Pinterest, Instagram or X (or another site yt-dlp knows) by link, as a job. Photo posts, carousels and image pins give their pictures. Files go to the open project's downloads folder, else the editor's cache; each download gets a folder with an info.json of its metadata. job.wait returns the files and metadata.", [
                Parameter("url", .string, "Link to the post, video, pin or tweet", required: true),
                Parameter("what", .oneOf(SocialDownloader.What.allCases.map(\.rawValue)), "video, audio, images (pictures only; a video gives its cover) or all (default: the video, and the pictures of items without video)"),
                Parameter("quality", .string, "A name from downloader.qualities (best, 1080, 720, 480) or a yt-dlp format; default downloader.defaultQuality"),
                Parameter("subtitles", .boolean, "Also download subtitles and automatic captions in downloader.subtitleLanguages; default false"),
                Parameter("import", .boolean, "Also add the files to the open project's media pool and return their media ids; default false"),
                Parameter("playlistLimit", .integer, "Items of a playlist, carousel or multi-video post at most; default downloader.playlistLimit"),
            ]) { _, args in
                let url = try SocialPlatform.link(try args.requiredString("url"))
                var r = SocialDownloader.Request(url: url)
                if let w = try args.string("what") {
                    guard let what = SocialDownloader.What(rawValue: w) else {
                        throw EditorError.invalid("what must be video, audio, images or all", parameter: "what")
                    }
                    r.what = what
                }
                let s = editor.settings.current.downloader
                r.quality = try args.string("quality")
                _ = try SocialDownloader.qualityArguments(r.quality, s)
                r.subtitles = try args.bool("subtitles") ?? false
                if let n = try args.int("playlistLimit") {
                    guard n >= 1 else { throw EditorError.invalid("playlistLimit must be 1 or more", parameter: "playlistLimit") }
                    r.playlistLimit = n
                }
                let wantsImport = try args.bool("import") ?? false
                if wantsImport, await editor.session == nil {
                    throw EditorError.invalid("import needs an open project; open or create one, or leave import off", parameter: "import")
                }
                _ = try YtDlp.command(s)   // a missing yt-dlp is reported now, not in the job
                let (root, location) = try await SocialStore.root(editor)
                let id = SocialPlatform.itemID(url)
                let folder = root.appendingPathComponent(id, isDirectory: true)
                let request = r
                let job = await jobs.start("social.download") { ctx in
                    let item = try await SocialDownloader.download(request, into: folder, settings: editor.settings, prober: editor.prober) { f, m in
                        await ctx.progress(f, m)
                    }
                    var o: [String: JSONValue] = [
                        "id": .string(item.id), "folder": .string(folder.path), "location": .string(location.rawValue),
                        "source": .string(item.source), "files": try fileJSON(item.files),
                        "paths": .array(item.files.map { .string(folder.appendingPathComponent($0.name).path) }),
                        "metadata": try JSONValue(encoding: item.metadata),
                    ]
                    if !item.warnings.isEmpty { o["warnings"] = .array(item.warnings.map { .string($0) }) }
                    if wantsImport {
                        let paths = item.files.filter { [.video, .audio, .image].contains($0.kind) }
                            .map { JSONValue.string(folder.appendingPathComponent($0.name).path) }
                        guard let tool = ToolCatalog.named("media.import") else { throw EditorError(.notFound, "media.import is missing") }
                        let r = try await tool.call(editor, arguments: .object(["paths": .array(paths)]))
                        var ids: [JSONValue] = (r["added"]?.arrayValue ?? []).compactMap { a in
                            a["id"].map { .object(["mediaId": $0, "path": a["path"] ?? .null]) }
                        }
                        ids += (r["alreadyInPool"]?.arrayValue ?? []).compactMap { a in
                            a["id"].map { .object(["mediaId": $0, "path": a["path"] ?? .null]) }
                        }
                        o["imported"] = .array(ids)
                        if let failed = r["failed"]?.arrayValue, !failed.isEmpty { o["importFailed"] = .array(failed) }
                        o["revision"] = r["revision"] ?? .null
                    }
                    return .object(o)
                }
                return .object(["jobId": .string(job), "id": .string(id), "folder": .string(folder.path), "location": .string(location.rawValue)])
            },
            Tool("social.info", .read, "Metadata of a post without downloading it: title, uploader, date, description, length, counts, the formats offered and the subtitle and automatic caption languages. A post without video lists its pictures.", [
                Parameter("url", .string, "Link to the post, video, pin or tweet", required: true),
                Parameter("playlistLimit", .integer, "Items of a playlist or carousel to describe at most; default downloader.playlistLimit"),
            ]) { _, args in
                let url = try SocialPlatform.link(try args.requiredString("url"))
                let r = try await SocialDownloader.info(url, playlistLimit: try args.int("playlistLimit"), settings: editor.settings)
                var o: [String: JSONValue] = ["id": .string(SocialPlatform.itemID(url)), "source": .string(r.source),
                                              "metadata": try JSONValue(encoding: r.metadata)]
                if !r.pictures.isEmpty { o["pictures"] = .array(r.pictures.map { .string($0) }) }
                if !r.videos.isEmpty { o["pageVideos"] = .array(r.videos.map { .string($0) }) }
                if let l = r.needsLogin { o["needsLogin"] = .string(l) }
                return .object(o)
            },
            Tool("social.inspect", .read, "Look at a download: a contact sheet of evenly spaced frames (or of its pictures), returned as an image and saved, single frames saved at given or evenly spaced times, the subtitle text, and the loudness. Files go to the download's inspect folder.", [
                Parameter("id", .string, "Download id from social.download or social.list", required: true),
                Parameter("file", .string, "One file of the download; default its video, else all its pictures"),
                Parameter("sheetFrames", .integer, "Frames in the contact sheet, 0 to 48 (0: none); default downloader.sheetFrames"),
                Parameter("columns", .integer, "Frames per row of the sheet; default downloader.sheetColumns"),
                Parameter("frameWidth", .integer, "Width of each sheet frame in pixels; default downloader.frameWidth"),
                Parameter("frames", .integer, "Single frames to save, evenly spaced; default downloader.frames"),
                Parameter("times", .array(.number), "Save single frames at these times in seconds instead"),
                Parameter("subtitles", .boolean, "Return the text of downloaded subtitles; default true"),
                Parameter("audio", .boolean, "Measure the loudness; default true"),
                Parameter("inline", .boolean, "Return the sheet as an image as well as its path; default true"),
            ]) { _, args in
                let e = try await SocialStore.find(try args.requiredString("id"), editor)
                let s = editor.settings.current.downloader
                let sheet = try args.int("sheetFrames") ?? s.sheetFrames
                guard (0...48).contains(sheet) else { throw EditorError.invalid("sheetFrames must be 0 to 48", parameter: "sheetFrames") }
                let frames = try args.int("frames") ?? s.frames
                guard (0...100).contains(frames) else { throw EditorError.invalid("frames must be 0 to 100", parameter: "frames") }
                var times: [Double]?
                if let list = args.values["times"], list != .null {
                    guard let a = list.arrayValue, a.allSatisfy({ $0.doubleValue != nil }) else {
                        throw EditorError.invalid("times must be a list of seconds", parameter: "times")
                    }
                    times = a.compactMap(\.doubleValue)
                }
                let o = SocialInspect.Options(file: try args.string("file"), sheetFrames: sheet,
                                              columns: try args.int("columns") ?? s.sheetColumns,
                                              frameWidth: max(64, min(1920, try args.int("frameWidth") ?? s.frameWidth)),
                                              frames: frames, times: times,
                                              subtitles: try args.bool("subtitles") ?? true, audio: try args.bool("audio") ?? true,
                                              maxText: s.maxTextCharacters, loudnessMaxSeconds: s.loudnessMaxSeconds)
                let (v, images) = try await SocialInspect.run(e, o)
                guard case .object(var out) = v else { return v }
                if try args.bool("inline") ?? true, !images.isEmpty {
                    out["images"] = .array(try images.map {
                        .object(["mimeType": .string("image/png"), "data": .string(try FrameCapture.png($0).base64EncodedString())])
                    })
                }
                return .object(out)
            },
            Tool("social.list", .read, "Downloads present, in the open project's downloads folder and the editor's cache, with their files, sizes, and whether they are in the media pool and used by clips.") { _, _ in
                let project = await editor.session?.project
                let all = try await SocialStore.list(editor)
                return .object([
                    "downloads": .array(all.map { entryJSON($0, project: project) }),
                    "bytes": .number(Double(all.reduce(0) { $0 + SocialStore.size($1.folder) })),
                    "folders": .array(try await SocialStore.roots(editor).map { .object(["location": .string($0.1.rawValue), "path": .string($0.0.path)]) }),
                ])
            },
            Tool("social.cleanup", .manage, "Move downloads, with their info.json, frames and sheets, to the Trash. A download used by clips of the open project is refused unless force is set; pool entries no clip uses are removed from the pool first.", [
                Parameter("ids", .array(.string), "Download ids to remove"),
                Parameter("all", .boolean, "Remove every download instead"),
                Parameter("force", .boolean, "Also trash downloads that clips use; the clips then show missing media"),
            ]) { _, args in
                let r = try await SocialStore.cleanup(ids: try args.strings("ids"), all: try args.bool("all") ?? false,
                                                      force: try args.bool("force") ?? false, editor: editor)
                return .object(["trashed": .array(r.trashed), "refused": .array(r.refused), "bytesFreed": .number(Double(r.bytesFreed)),
                                "removedFromPool": .array(r.removedFromPool.map { .string($0.raw) })])
            },
        ]
    }
}
