import CryptoKit
import EditorCore
import EditorKit
import Foundation

/// The site a link belongs to, and the stable key of the post in it.
public enum SocialPlatform: String, Codable, Sendable, CaseIterable {
    case youtube, pinterest, instagram, x, other

    public static func of(_ url: URL) -> SocialPlatform {
        let host = (url.host ?? "").lowercased()
        func on(_ domains: [String]) -> Bool {
            domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        if on(["youtube.com", "youtu.be", "youtube-nocookie.com"]) { return .youtube }
        if on(["pin.it"]) || host.split(separator: ".").contains("pinterest") { return .pinterest }
        if on(["instagram.com", "instagr.am"]) { return .instagram }
        if on(["x.com", "twitter.com", "fxtwitter.com", "vxtwitter.com"]) { return .x }
        return .other
    }

    /// The post's own id taken from the link, so the same post always lands
    /// in the same folder. Links of other shapes get a hash of the link.
    public static func itemKey(_ url: URL) -> String {
        let parts = url.path.split(separator: "/").map(String.init)
        func after(_ names: Set<String>) -> String? {
            guard let i = parts.firstIndex(where: { names.contains($0.lowercased()) }), i + 1 < parts.count else { return nil }
            return parts[i + 1]
        }
        var key: String?
        switch of(url) {
        case .youtube:
            if (url.host ?? "").lowercased().hasSuffix("youtu.be") { key = parts.first }
            else {
                key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
                    ?? after(["shorts", "live", "embed", "v"])
                    ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "list" }?.value
            }
        case .pinterest: key = after(["pin"])
        case .instagram: key = after(["p", "reel", "reels", "tv"])
        case .x: key = after(["status", "statuses"])
        case .other: key = nil
        }
        if let key, !key.isEmpty { return safeName(key) }
        return SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The folder name of a download: platform and post key.
    public static func itemID(_ url: URL) -> String { "\(of(url).rawValue)-\(itemKey(url))" }

    /// Letters, digits, dot, dash and underscore only; at most 80 characters.
    public static func safeName(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var out = String(s.map { allowed.contains($0) ? $0 : "_" }.prefix(80))
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "item" : out
    }

    /// The link as given, checked: http(s) with a host.
    public static func link(_ s: String) throws -> URL {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t.contains("://") ? t : "https://" + t), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host, host.contains(".") else {
            throw EditorError.invalid("\(s) is not a web link; give the full address of the post, for example https://www.youtube.com/watch?v=...", parameter: "url")
        }
        return u
    }
}

/// What a post says about itself, from yt-dlp's JSON or the page's tags.
public struct SocialMetadata: Codable, Equatable, Sendable {
    public struct Formats: Codable, Equatable, Sendable {
        public var count: Int
        /// Picture heights offered, lowest first.
        public var heights: [Int]
        /// Video codecs offered (avc1, vp09, av01, ...).
        public var videoCodecs: [String]
        public var audioOnly: Bool
        public var extensions: [String]
    }

    public var platform: String
    /// The link as given.
    public var url: String
    public var webpageURL: String?
    public var id: String
    public var title: String?
    public var uploader: String?
    public var uploaderID: String?
    public var channel: String?
    /// YYYY-MM-DD.
    public var uploadDate: String?
    public var description: String?
    public var duration: Double?
    public var viewCount: Int?
    public var likeCount: Int?
    public var commentCount: Int?
    public var width: Int?
    public var height: Int?
    public var thumbnail: String?
    public var tags: [String]?
    public var formats: Formats?
    public var subtitles: [String]?
    public var automaticCaptions: [String]?
    /// Items of a carousel, playlist or multi-video post.
    public var entries: [SocialMetadata]?

    public init(platform: String, url: String, id: String) {
        self.platform = platform
        self.url = url
        self.id = id
    }

    /// Reads yt-dlp's `--dump-single-json` output.
    public static func parse(ytdlp data: Data, url: String) throws -> SocialMetadata {
        let v: JSONValue
        do { v = try JSONValue.parse(data) } catch {
            throw EditorError(.io, "yt-dlp did not return readable JSON: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard case .object = v else { throw EditorError(.io, "yt-dlp returned no metadata for \(url)") }
        let platform = (try? SocialPlatform.link(url)).map { SocialPlatform.of($0).rawValue } ?? SocialPlatform.other.rawValue
        return parse(v, url: url, platform: platform)
    }

    static func parse(_ v: JSONValue, url: String, platform: String) -> SocialMetadata {
        func str(_ k: String) -> String? { v[k]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ k: String) -> Int? { v[k]?.doubleValue.map { Int($0) } }
        var m = SocialMetadata(platform: platform, url: url, id: str("id") ?? "")
        m.webpageURL = str("webpage_url") ?? str("original_url")
        m.title = str("title") ?? str("fulltitle")
        m.uploader = str("uploader") ?? str("channel") ?? str("creator")
        m.uploaderID = str("uploader_id") ?? str("channel_id")
        m.channel = str("channel")
        if let d = str("upload_date"), d.count == 8, d.allSatisfy(\.isNumber) {
            m.uploadDate = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
        } else if let t = v["timestamp"]?.doubleValue {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            m.uploadDate = f.string(from: Date(timeIntervalSince1970: t))
        }
        m.description = str("description")
        m.duration = v["duration"]?.doubleValue
        m.viewCount = int("view_count")
        m.likeCount = int("like_count")
        m.commentCount = int("comment_count")
        m.width = int("width")
        m.height = int("height")
        m.thumbnail = bestThumbnail(v) ?? str("thumbnail")
        m.tags = v["tags"]?.arrayValue?.compactMap(\.stringValue).nilIfEmpty
        if let fs = v["formats"]?.arrayValue, !fs.isEmpty {
            // Storyboards (mhtml) are previews, not media.
            let media = fs.filter { $0["ext"]?.stringValue != "mhtml" }
            let video = media.filter { ($0["vcodec"]?.stringValue ?? "none") != "none" }
            let heights = Set(video.compactMap { $0["height"]?.doubleValue.map { Int($0) } }).sorted()
            let codecs = video.compactMap { $0["vcodec"]?.stringValue?.split(separator: ".").first.map(String.init) }
            m.formats = Formats(count: media.count, heights: heights,
                                videoCodecs: codecs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                                audioOnly: media.contains { ($0["vcodec"]?.stringValue ?? "") == "none" && ($0["acodec"]?.stringValue ?? "none") != "none" },
                                extensions: Set(media.compactMap { $0["ext"]?.stringValue }).sorted())
        }
        m.subtitles = v["subtitles"]?.objectValue?.keys.sorted().nilIfEmpty
        m.automaticCaptions = v["automatic_captions"]?.objectValue?.keys.sorted().nilIfEmpty
        if let entries = v["entries"]?.arrayValue {
            m.entries = entries.filter { $0 != .null }.map { parse($0, url: $0["webpage_url"]?.stringValue ?? url, platform: platform) }
        }
        return m
    }

    /// The largest thumbnail: by its size when given, else the last one
    /// (yt-dlp lists them worst first).
    static func bestThumbnail(_ v: JSONValue) -> String? {
        guard let list = v["thumbnails"]?.arrayValue?.filter({ $0["url"]?.stringValue != nil }), !list.isEmpty else { return nil }
        let sized = list.enumerated().max { a, b in
            let pa = (a.element["width"]?.doubleValue ?? 0) * (a.element["height"]?.doubleValue ?? a.element["width"]?.doubleValue ?? 0)
            let pb = (b.element["width"]?.doubleValue ?? 0) * (b.element["height"]?.doubleValue ?? b.element["width"]?.doubleValue ?? 0)
            return pa != pb ? pa < pb : a.offset < b.offset
        }
        return sized?.element["url"]?.stringValue
    }

    /// The pictures of a post that has no video: each entry's largest
    /// thumbnail, or the post's own.
    public var pictureURLs: [String] {
        if let entries, !entries.isEmpty { return entries.flatMap(\.pictureURLs) }
        return thumbnail.map { [$0] } ?? []
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

/// Open Graph and Twitter card tags of a page: how a post shows itself
/// when shared, and the fallback when yt-dlp finds no media.
public enum OpenGraph {
    public struct Tags: Equatable, Sendable {
        public var images: [String] = []
        public var videos: [String] = []
        public var title: String?
        public var description: String?
        public var type: String?
        public var siteName: String?
    }

    public static func parse(_ html: String) -> Tags {
        var t = Tags()
        var twitterImages: [String] = []
        let meta = try! Regex(#"<meta\b[^>]*>"#).ignoresCase()
        let attr = try! Regex(#"([A-Za-z_:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
        for m in html.matches(of: meta) {
            var a: [String: String] = [:]
            for p in html[m.range].matches(of: attr) {
                guard let k = p.output[1].substring.map(String.init)?.lowercased() else { continue }
                a[k] = String(p.output[2].substring ?? p.output[3].substring ?? "")
            }
            guard let key = (a["property"] ?? a["name"])?.lowercased(), let raw = a["content"] else { continue }
            let value = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch key {
            case "og:image", "og:image:url", "og:image:secure_url":
                if !t.images.contains(value) { t.images.append(value) }
            case "og:video", "og:video:url", "og:video:secure_url":
                if !t.videos.contains(value) { t.videos.append(value) }
            case "twitter:image", "twitter:image:src":
                if !twitterImages.contains(value) { twitterImages.append(value) }
            case "og:title": t.title = t.title ?? value
            case "og:description": t.description = t.description ?? value
            case "og:type": t.type = t.type ?? value
            case "og:site_name": t.siteName = t.siteName ?? value
            default: break
            }
        }
        if t.images.isEmpty { t.images = twitterImages }
        return t
    }

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " "]
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String?
                if let n = named[name.lowercased()] { rep = n }
                else if name.hasPrefix("#x") || name.hasPrefix("#X"), let c = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(c) { rep = String(Character(u)) }
                else if name.hasPrefix("#"), let c = UInt32(name.dropFirst()), let u = Unicode.Scalar(c) { rep = String(Character(u)) }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

/// Subtitle files (WebVTT, SRT) as plain text.
public enum SubtitleText {
    /// The spoken lines in order, without timings, tags or the repeats that
    /// rolling automatic captions carry.
    public static func plain(_ vtt: String) -> String {
        var lines: [String] = []
        var recent: [String] = []
        let tag = try! Regex(#"<[^>]*>"#)
        for raw in vtt.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l == "WEBVTT" || l.hasPrefix("WEBVTT ") || l.contains("-->") || l.hasPrefix("NOTE")
                || l.hasPrefix("Kind:") || l.hasPrefix("Language:") || l.hasPrefix("STYLE") || l.hasPrefix("REGION")
                || l.allSatisfy(\.isNumber) { continue }
            let text = OpenGraph.decodeEntities(l.replacing(tag, with: "")).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !recent.contains(text) else { continue }
            lines.append(text)
            recent.append(text)
            if recent.count > 3 { recent.removeFirst() }
        }
        return lines.joined(separator: "\n")
    }
}
