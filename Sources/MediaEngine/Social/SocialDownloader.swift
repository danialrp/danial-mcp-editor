import EditorCore
import EditorKit
import Foundation

/// Downloads posts with yt-dlp; posts without video (photos, carousels,
/// image pins) fall back to the pictures in yt-dlp's metadata, then to the
/// page's og:image and og:video tags.
public enum SocialDownloader {
    public enum What: String, CaseIterable, Sendable { case video, audio, images, all }

    public struct Request: Sendable {
        public var url: URL
        public var what: What = .all
        /// A name from downloader.qualities, or a yt-dlp format such as `bv*[height<=720]+ba/b`.
        public var quality: String?
        public var subtitles = false
        public var playlistLimit: Int?

        public init(url: URL) { self.url = url }
    }

    /// yt-dlp arguments that pick the format for a quality.
    public static func qualityArguments(_ quality: String?, _ s: UserSettings.DownloaderSettings) throws -> [String] {
        let q = quality ?? s.defaultQuality
        if let preset = s.qualities[q] { return preset }
        if q.contains("[") || q.contains("/") || q.contains("+") || ["b", "bv", "ba", "best", "worst", "bv*"].contains(q) { return ["-f", q] }
        throw EditorError.invalid("quality \(q) is neither a name from downloader.qualities (\(s.qualities.keys.sorted().joined(separator: ", "))) nor a yt-dlp format such as bv*[height<=720]+ba/b", parameter: "quality")
    }

    static func limit(_ r: Request, _ s: UserSettings.DownloaderSettings) -> Int { max(1, r.playlistLimit ?? s.playlistLimit) }

    /// The JSON object yt-dlp printed: the last stdout line that is one.
    static func json(_ stdout: Data) -> JSONValue? {
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let v = try? JSONValue.parse(Data(line.utf8)), case .object = v { return v }
        }
        return nil
    }

    // MARK: metadata only

    public struct InfoResult: Sendable {
        public var metadata: SocialMetadata
        public var source: String
        public var pictures: [String]
        public var videos: [String]
        /// Set when the site showed a sign-in wall: the metadata may be
        /// partial and a download would fail without a sign-in.
        public var needsLogin: String?
    }

    /// Metadata without downloading: yt-dlp, else the page's tags.
    public static func info(_ url: URL, playlistLimit: Int?, settings store: UserSettingsStore) async throws -> InfoResult {
        let s = store.current.downloader
        let platform = SocialPlatform.of(url)
        let cmd = try YtDlp.command(s)
        let args = cmd + YtDlp.common(s) + ["-J", "--skip-download", "--ignore-no-formats-error",
                                           "--yes-playlist", "--playlist-items", "1:\(max(1, playlistLimit ?? s.playlistLimit))", "--", url.absoluteString]
        let out = try await YtDlp.run(args, folders: s.searchFolders, timeout: s.infoTimeoutSeconds)
        if out.timedOut { throw EditorError(.io, "yt-dlp did not answer within downloader.infoTimeoutSeconds (\(Int(s.infoTimeoutSeconds)) s)") }
        let message = YtDlp.errorText(out.stderr, s)
        if let v = json(out.stdout) {
            let m = SocialMetadata.parse(v, url: url.absoluteString, platform: platform.rawValue)
            let login = m.formats == nil && YtDlp.classify(message, s) == .needsLogin
            return InfoResult(metadata: m, source: "yt-dlp", pictures: m.formats == nil && !login ? m.pictureURLs : [], videos: [],
                              needsLogin: login ? YtDlp.failure(message, platform: platform, s).message : nil)
        }
        if YtDlp.classify(message, s) == .needsLogin { throw YtDlp.failure(message, platform: platform, s) }
        if let page = try? await pageTags(url, s), !(page.images.isEmpty && page.videos.isEmpty) {
            return InfoResult(metadata: metadata(page, url: url), source: "page tags", pictures: page.images, videos: page.videos)
        }
        throw YtDlp.failure(message, platform: platform, s)
    }

    static func metadata(_ page: OpenGraph.Tags, url: URL) -> SocialMetadata {
        var m = SocialMetadata(platform: SocialPlatform.of(url).rawValue, url: url.absoluteString, id: SocialPlatform.itemKey(url))
        m.title = page.title
        m.description = page.description
        m.thumbnail = page.images.first
        m.webpageURL = url.absoluteString
        return m
    }

    // MARK: download

    /// Downloads into `folder` and writes its sidecar.
    public static func download(_ r: Request, into folder: URL, settings store: UserSettingsStore, prober: any MediaProber,
                                progress: @escaping @Sendable (Double, String) async -> Void) async throws -> SocialItem {
        let s = store.current.downloader
        let platform = SocialPlatform.of(r.url)
        let cmd = try YtDlp.command(s)
        let quality = try qualityArguments(r.quality, s)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var warnings: [String] = []
        var raw: JSONValue?
        var failure: String?
        var source = "yt-dlp"
        let ffmpeg = YtDlp.ffmpegFolder(s)
        if ffmpeg == nil { warnings.append("ffmpeg was not found (downloader.ffmpeg): only formats with picture and sound in one file can be downloaded") }

        // 1. Metadata once. Sites can throttle repeated reads, so the
        //    download below works from it.
        await progress(0.02, "yt-dlp: reading \(r.url.absoluteString)")
        // The subtitle choice goes into the metadata (requested_subtitles),
        // so it is made here.
        let subtitleArgs = r.subtitles
            ? ["--write-subs", "--write-auto-subs", "--sub-langs", s.subtitleLanguages.joined(separator: ","), "--sub-format", "vtt/best"] : []
        let infoArgs = cmd + YtDlp.common(s) + ["-J", "--skip-download", "--ignore-no-formats-error", "--yes-playlist",
                                               "--playlist-items", "1:\(limit(r, s))"] + subtitleArgs + ["--", r.url.absoluteString]
        let infoOut = try await YtDlp.run(infoArgs, folders: s.searchFolders, timeout: s.infoTimeoutSeconds)
        if infoOut.timedOut { throw EditorError(.io, "yt-dlp did not answer within downloader.infoTimeoutSeconds (\(Int(s.infoTimeoutSeconds)) s)") }
        raw = json(infoOut.stdout)
        let infoText = YtDlp.errorText(infoOut.stderr, s)
        let hasVideo = raw.map(hasFormats) ?? false
        if !hasVideo, YtDlp.classify(infoText, s) == .needsLogin { throw YtDlp.failure(infoText, platform: platform, s) }
        if raw == nil { failure = infoText }

        // 2. The video or sound, from that metadata.
        if r.what != .images, let raw, hasVideo {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("dme-social-\(UUID().uuidString).info.json")
            try raw.data().write(to: work)
            defer { try? FileManager.default.removeItem(at: work) }   // an intermediate: its links carry the session
            var args = cmd + YtDlp.common(s) + [
                "--load-info-json", work.path, "-J", "--no-simulate", "--ignore-no-formats-error", "--ignore-errors",
                "--progress", "--newline", "--no-mtime", "-o", folder.path + "/%(playlist_index&{:02d}-|)s%(id)s.%(ext)s",
            ]
            if r.what == .audio {
                args += ["-f", s.audioFormat]
                // Keep a video already downloaded here when its sound is extracted.
                if ffmpeg != nil { args += ["-x", "--audio-format", s.audioCodec] + (haveMedia(folder) ? ["-k"] : []) }
            } else {
                args += quality + ["--merge-output-format", s.mergeFormat]
            }
            args += subtitleArgs
            let meter = Meter(progress)
            let out = try await YtDlp.run(args, folders: s.searchFolders, timeout: s.downloadTimeoutSeconds) { meter.line($0) }
            if out.timedOut {
                throw EditorError(.io, "the download took longer than downloader.downloadTimeoutSeconds (\(Int(s.downloadTimeoutSeconds)) s); raise it with settings.set or choose a lower quality")
            }
            if out.status != 0 {
                let text = YtDlp.errorText(out.stderr, s)
                if !haveMedia(folder), YtDlp.classify(text, s) == .needsLogin { throw YtDlp.failure(text, platform: platform, s) }
                if haveMedia(folder) { warnings.append("yt-dlp: \(text)") } else { failure = text }
            }
        }

        // 3. Pictures: of the items without video, or of every item when
        //    only pictures are wanted.
        var pictures: [String] = []
        if r.what == .images || r.what == .all, let raw { pictures = pictureURLs(raw, all: r.what == .images) }
        var meta = raw.map { SocialMetadata.parse($0, url: r.url.absoluteString, platform: platform.rawValue) }
        if !pictures.isEmpty { source = haveMedia(folder) ? "yt-dlp and its thumbnails" : "yt-dlp thumbnails" }
        var videos: [String] = []
        if pictures.isEmpty && !haveMedia(folder) {
            // Nothing from yt-dlp: the page's own tags.
            do {
                let page = try await pageTags(r.url, s)
                if r.what != .audio && r.what != .video { pictures = page.images }
                if r.what != .audio && r.what != .images { videos = page.videos }
                if !pictures.isEmpty || !videos.isEmpty {
                    source = "page tags"
                    if meta == nil { meta = metadata(page, url: r.url) }
                }
            } catch {
                warnings.append("reading the page failed: \(error)")
            }
        }
        let key = SocialPlatform.itemKey(r.url)
        for (i, v) in videos.enumerated() {
            await progress(0.6, "page video \(i + 1) of \(videos.count)")
            do { try await save(v, name: videos.count > 1 ? String(format: "%02d-%@", i + 1, key) : key, kind: "video", into: folder, s) }
            catch { warnings.append("\(v): \(error)") }
        }
        for (i, p) in pictures.enumerated() {
            await progress(0.7 + 0.25 * Double(i) / Double(max(1, pictures.count)), "picture \(i + 1) of \(pictures.count)")
            do { try await save(p, name: pictures.count > 1 ? String(format: "%02d-%@", i + 1, key) : key, kind: "image", into: folder, s) }
            catch { warnings.append("\(p): \(error)") }
        }
        guard haveMedia(folder) else {
            if let failure { throw YtDlp.failure(failure + " (and the page has no og:image or og:video tag to fall back on)", platform: platform, s) }
            throw EditorError(.notFound, "nothing to download at \(r.url.absoluteString) for what: \(r.what.rawValue): yt-dlp found no media and the page has no og:image or og:video tag")
        }
        await progress(0.97, "reading the files")
        let files = await SocialStore.describe(folder, prober: prober)
        let item = SocialItem(id: folder.lastPathComponent, url: r.url.absoluteString, platform: platform.rawValue,
                              downloadedAt: Date(), what: r.what.rawValue, source: source,
                              metadata: meta ?? SocialMetadata(platform: platform.rawValue, url: r.url.absoluteString, id: key),
                              files: files, warnings: warnings)
        try SocialStore.write(item, in: folder)
        return item
    }

    /// Whether yt-dlp's metadata offers any downloadable format (storyboards
    /// do not count), for the post or one of its items.
    static func hasFormats(_ v: JSONValue) -> Bool {
        if (v["formats"]?.arrayValue ?? []).contains(where: { $0["ext"]?.stringValue != "mhtml" }) { return true }
        if v["url"]?.stringValue != nil, v["_type"]?.stringValue != "url" { return true }
        return (v["entries"]?.arrayValue ?? []).contains(where: hasFormats)
    }

    static func haveMedia(_ folder: URL) -> Bool {
        SocialStore.mediaFiles(in: folder).contains { [.video, .audio, .image].contains(SocialFile.kind(of: $0.lastPathComponent)) }
    }

    /// Picture links in yt-dlp's metadata: of each item that has no
    /// formats (a photo), or of every item when `all`. (Metadata read with
    /// --skip-download still lists requested_downloads, so that says nothing.)
    static func pictureURLs(_ v: JSONValue, all: Bool) -> [String] {
        func one(_ e: JSONValue) -> String? {
            let formats = (e["formats"]?.arrayValue ?? []).filter { $0["ext"]?.stringValue != "mhtml" }
            guard all || formats.isEmpty else { return nil }
            return SocialMetadata.bestThumbnail(e) ?? e["thumbnail"]?.stringValue
        }
        if let entries = v["entries"]?.arrayValue, !entries.isEmpty { return entries.compactMap(one) }
        return one(v).map { [$0] } ?? []
    }

    // MARK: the web

    static func get(_ url: URL, _ s: UserSettings.DownloaderSettings) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: s.infoTimeoutSeconds)
        req.setValue(s.pageUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard let h = resp as? HTTPURLResponse else { throw EditorError(.io, "no answer from \(url.host ?? "")") }
        guard h.statusCode < 400 else { throw EditorError(.io, "\(url.host ?? "") answered HTTP \(h.statusCode)") }
        return (d, h)
    }

    /// The page's og: and twitter: tags.
    public static func pageTags(_ url: URL, _ s: UserSettings.DownloaderSettings) async throws -> OpenGraph.Tags {
        let (d, _) = try await get(url, s)
        return OpenGraph.parse(String(decoding: d, as: UTF8.self))
    }

    /// Saves one picture or video link as `<name>.<ext>`.
    static func save(_ link: String, name: String, kind: String, into folder: URL, _ s: UserSettings.DownloaderSettings) async throws {
        guard let url = URL(string: link), url.scheme?.hasPrefix("http") == true else { throw EditorError(.invalid, "not a web link") }
        let (d, h) = try await get(url, s)
        let type = (h.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        var ext: String
        if kind == "image" {
            ext = BrowserTools.imageExtension(d) ?? ""
            guard !ext.isEmpty || type.hasPrefix("image/") else { throw EditorError(.io, "not a picture (\(type))") }
            if ext.isEmpty { ext = String(type.dropFirst(6).prefix { $0.isLetter }) }
        } else {
            guard type.hasPrefix("video/") || ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
                throw EditorError(.io, "the page's video is a stream (\(type.isEmpty ? url.pathExtension : type)), not a file")
            }
            ext = ["mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased()
                : (type.contains("quicktime") ? "mov" : "mp4")
        }
        try d.write(to: folder.appendingPathComponent("\(name).\(ext.isEmpty ? "jpg" : ext)"), options: .atomic)
    }

    /// Turns yt-dlp's progress lines into job progress.
    final class Meter: @unchecked Sendable {
        private let report: @Sendable (Double, String) async -> Void
        private let lock = NSLock()
        private var item = 1, items = 1, last = -1.0

        init(_ report: @escaping @Sendable (Double, String) async -> Void) { self.report = report }

        func line(_ l: String) {
            lock.lock(); defer { lock.unlock() }
            if let m = l.firstMatch(of: /Downloading (?:item|video) (\d+) of (\d+)/), let a = Int(m.1), let b = Int(m.2) {
                item = a; items = max(1, b)
            }
            guard l.hasPrefix("[download]"), let m = l.firstMatch(of: /(\d+(?:\.\d+)?)%/), let pct = Double(m.1) else { return }
            let f = 0.05 + 0.85 * (Double(item - 1) + pct / 100) / Double(items)
            guard f - last >= 0.01 || pct >= 100 else { return }
            last = f
            let msg = items > 1 ? "item \(item) of \(items): \(l.dropFirst(10).trimmingCharacters(in: .whitespaces))"
                : String(l.dropFirst(10).trimmingCharacters(in: .whitespaces))
            let report = self.report
            Task { await report(f, msg) }
        }
    }
}
