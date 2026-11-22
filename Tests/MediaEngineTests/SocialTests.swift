import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing

/// The social downloader without the network: yt-dlp's JSON, page tags,
/// naming, sidecars, cleanup and the command lookup.
@Suite struct SocialTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/social")
    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    static let defaults = UserSettings.DownloaderSettings()

    @Test func readsYtDlpMetadata() throws {
        let m = try SocialMetadata.parse(ytdlp: try Self.fixture("video.json"), url: "https://youtu.be/abc123XYZ_0")
        #expect(m.platform == "youtube" && m.id == "abc123XYZ_0" && m.title == "Sample clip")
        #expect(m.uploader == "Example Channel" && m.uploaderID == "@example" && m.channel == "Example Channel")
        #expect(m.uploadDate == "2024-01-31", "YYYYMMDD becomes YYYY-MM-DD")
        #expect(m.description == "A short sample.\nSecond line.")
        #expect(m.duration == 61.5 && m.viewCount == 12345 && m.likeCount == 678 && m.commentCount == 9)
        #expect(m.width == 1920 && m.height == 1080 && m.tags == ["sample", "test"])
        #expect(m.webpageURL == "https://www.youtube.com/watch?v=abc123XYZ_0" && m.url == "https://youtu.be/abc123XYZ_0")
        #expect(m.thumbnail == "https://img.example.com/large.jpg", "the largest sized thumbnail")
        let f = try #require(m.formats)
        #expect(f.count == 5, "storyboards are not media")
        #expect(f.heights == [720, 1080] && f.videoCodecs == ["avc1", "vp9", "av01"] && f.audioOnly)
        #expect(f.extensions == ["m4a", "mp4", "webm"])
        #expect(m.subtitles == ["de", "en"] && m.automaticCaptions == ["en", "fr"])
        #expect(m.entries == nil)
    }

    @Test func readsCarouselsAndTheirPictures() throws {
        let data = try Self.fixture("carousel.json")
        let m = try SocialMetadata.parse(ytdlp: data, url: "https://www.instagram.com/p/C0ffee/")
        #expect(m.platform == "instagram" && m.uploadDate == "2023-11-14", "date from the timestamp when upload_date is missing")
        #expect(m.entries?.map(\.id) == ["1", "2", "3"], "null entries are dropped")
        #expect(m.entries?[1].formats?.heights == [1280])
        #expect(m.pictureURLs == ["https://img.example.com/1-1080.jpg", "https://img.example.com/2-cover.jpg", "https://img.example.com/3-b.jpg"])
        let raw = try JSONValue.parse(data)
        #expect(SocialDownloader.pictureURLs(raw, all: false) == ["https://img.example.com/1-1080.jpg", "https://img.example.com/3-b.jpg"],
                "only items without formats; unsized thumbnails: the last")
        #expect(SocialDownloader.pictureURLs(raw, all: true).count == 3)
        #expect(SocialDownloader.hasFormats(raw), "one item of the carousel is a video")
        #expect(SocialDownloader.hasFormats(try JSONValue.parse(try Self.fixture("video.json"))))
        let photo = try JSONValue.parse(Data(#"{"id": "p", "formats": [{"ext": "mhtml", "format_id": "sb0"}], "requested_downloads": [{"ext": "NA"}], "thumbnails": [{"url": "https://img.example.com/p.jpg"}]}"#.utf8))
        #expect(!SocialDownloader.hasFormats(photo), "storyboards only: a photo post")
        #expect(SocialDownloader.pictureURLs(photo, all: false) == ["https://img.example.com/p.jpg"])
    }

    @Test func badJSONSaysWhatCameBack() {
        #expect(throws: EditorError.self) { try SocialMetadata.parse(ytdlp: Data("not json".utf8), url: "https://x.com/a/status/1") }
        #expect(throws: EditorError.self) { try SocialMetadata.parse(ytdlp: Data("null".utf8), url: "https://x.com/a/status/1") }
        let out = Data("[download] 5%\n{\"id\": \"a\"}\n".utf8)
        #expect(SocialDownloader.json(out)?["id"]?.stringValue == "a", "the JSON line after progress lines")
    }

    @Test func readsPageTags() throws {
        let t = OpenGraph.parse(String(decoding: try Self.fixture("page.html"), as: UTF8.self))
        #expect(t.title == "Example & Co. on the site", "content before property, entities decoded")
        #expect(t.description == "A \"quoted\" description \u{2014} with entities \u{2764}")
        #expect(t.images == ["https://img.example.com/a.jpg?w=1&h=2", "https://img.example.com/b.jpg"], "upper case, repeats dropped, no width tag")
        #expect(t.videos == ["https://video.example.com/v.mp4"], "og:video:type is not a link")
        #expect(t.type == "video.other" && t.siteName == "Example")
        let tw = OpenGraph.parse(#"<html><head><meta name="twitter:image:src" content="https://img.example.com/t.jpg"></head></html>"#)
        #expect(tw.images == ["https://img.example.com/t.jpg"], "twitter card image when there is no og:image")
        #expect(OpenGraph.parse("<html><body>no tags</body></html>") == OpenGraph.Tags())
    }

    @Test func namesFoldersByPlatformAndPost() throws {
        func id(_ s: String) throws -> String { SocialPlatform.itemID(try SocialPlatform.link(s)) }
        #expect(try id("https://www.youtube.com/watch?v=abc123XYZ_0&t=10") == "youtube-abc123XYZ_0")
        #expect(try id("https://youtu.be/abc123XYZ_0?si=x") == "youtube-abc123XYZ_0")
        #expect(try id("https://www.youtube.com/shorts/Short_1") == "youtube-Short_1")
        #expect(try id("https://www.pinterest.com/pin/1234567890/") == "pinterest-1234567890")
        #expect(try id("https://de.pinterest.com/pin/42/") == "pinterest-42")
        #expect(try id("https://www.instagram.com/p/C0ffee/?img_index=2") == "instagram-C0ffee")
        #expect(try id("https://www.instagram.com/reel/R3el/") == "instagram-R3el")
        #expect(try id("https://x.com/someone/status/1777/photo/1") == "x-1777")
        #expect(try id("https://twitter.com/someone/status/1888") == "x-1888")
        #expect(try id("x.com/someone/status/1999") == "x-1999", "https is added")
        let other = try id("https://vimeo.com/12345")
        #expect(other.hasPrefix("other-") && other.count == "other-".count + 12, "other sites: a hash of the link")
        #expect(other == (try id("https://vimeo.com/12345")), "the same link gives the same folder")
        #expect(SocialPlatform.safeName("a/b c?d..e") == "a_b_c_d..e")
        #expect(SocialPlatform.safeName("../x") == "_x", "never a hidden or parent folder")
        #expect(SocialPlatform.safeName(String(repeating: "z", count: 200)).count == 80)
        #expect(throws: EditorError.self) { try SocialPlatform.link("not a link") }
        #expect(throws: EditorError.self) { try SocialPlatform.link("ftp://example.com/a") }
    }

    @Test func sidecarAndFileKinds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-social-\(UUID().uuidString)/youtube-abc")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("inspect"), withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: dir.deletingLastPathComponent(), resultingItemURL: nil) }
        for n in ["abc.mp4", "abc.en.vtt", "02-abc.jpg", "abc.mp4.part", ".hidden", "abc.m4a"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(n))
        }
        var m = try SocialMetadata.parse(ytdlp: try Self.fixture("video.json"), url: "https://youtu.be/abc")
        m.entries = [SocialMetadata(platform: "youtube", url: "u", id: "e1")]
        let item = SocialItem(id: "youtube-abc", url: "https://youtu.be/abc", platform: "youtube",
                              downloadedAt: Date(timeIntervalSince1970: 1_700_000_000), what: "all", source: "yt-dlp",
                              metadata: m, files: [SocialFile(name: "abc.mp4", kind: .video, bytes: 1)], warnings: ["w"])
        try SocialStore.write(item, in: dir)
        #expect(SocialStore.read(dir) == item, "the sidecar reads back exactly")
        let text = try String(contentsOf: dir.appendingPathComponent("info.json"), encoding: .utf8)
        #expect(text.contains("\"downloadedAt\" : \"2023-11-14T22:13:20Z\""), "dates as ISO 8601")
        #expect(SocialStore.mediaFiles(in: dir).map(\.lastPathComponent) == ["02-abc.jpg", "abc.en.vtt", "abc.m4a", "abc.mp4"],
                "no sidecar, inspect folder, partial or hidden files")
        #expect(SocialFile.kind(of: "a.mp4") == .video && SocialFile.kind(of: "a.webm") == .video && SocialFile.kind(of: "a.mov") == .video)
        #expect(SocialFile.kind(of: "a.m4a") == .audio && SocialFile.kind(of: "a.webp") == .image && SocialFile.kind(of: "a.jpg") == .image)
        #expect(SocialFile.kind(of: "a.en.vtt") == .subtitles && SocialFile.kind(of: "a.srt") == .subtitles && SocialFile.kind(of: "a.txt") == .other)
    }

    @Test func subtitlesBecomePlainText() throws {
        let text = SubtitleText.plain(String(decoding: try Self.fixture("captions.vtt"), as: UTF8.self))
        #expect(text == "hello there\ngeneral & friends\nlast line", "no timings, tags, cue numbers or rolling repeats")
    }

    @Test func qualitiesAndTimes() throws {
        let s = Self.defaults
        #expect(try SocialDownloader.qualityArguments(nil, s) == s.qualities["1080"])
        #expect(try SocialDownloader.qualityArguments("720", s).last?.contains("res:720") == true)
        #expect(try SocialDownloader.qualityArguments("bv*[height<=360]+ba/b", s) == ["-f", "bv*[height<=360]+ba/b"])
        #expect(throws: EditorError.self) { try SocialDownloader.qualityArguments("superb", s) }
        #expect(SocialInspect.evenTimes(4, over: 8) == [1, 3, 5, 7])
        #expect(SocialInspect.evenTimes(0, over: 8).isEmpty && SocialInspect.evenTimes(3, over: 0).isEmpty)
    }

    @Test func missingCommandSaysWhereItLookedAndWhatToSet() throws {
        do {
            _ = try YtDlp.locate("dme-no-such-tool", path: "/nonexistent-a", folders: ["/nonexistent-b"], setting: "downloader.command")
            Issue.record("found a program that does not exist")
        } catch let e as EditorError {
            #expect(e.code == .notFound)
            #expect(e.message.contains("dme-no-such-tool was not found") && e.message.contains("/nonexistent-b"))
            #expect(e.message.contains("downloader.command") && e.message.contains("settings.set"))
        }
        do {
            _ = try YtDlp.locate("/nonexistent-c/yt-dlp", path: nil, folders: [], setting: "downloader.command")
            Issue.record("accepted a missing path")
        } catch let e as EditorError {
            #expect(e.message.contains("not an executable file") && e.message.contains("downloader.command"))
        }
        #expect(try YtDlp.locate("sh", path: "/nonexistent-a:/bin", folders: [], setting: "x").path == "/bin/sh")
        #expect(try YtDlp.locate("sh", path: "", folders: ["/bin"], setting: "x").path == "/bin/sh", "the folders after PATH")
        var s = Self.defaults
        s.command = []
        #expect(throws: EditorError.self) { try YtDlp.command(s) }
    }

    @Test func errorsAreClassified() {
        let s = Self.defaults
        let bot = "[youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication."
        #expect(YtDlp.classify(bot, s) == .needsLogin)
        #expect(YtDlp.classify("[Instagram] x: Requested content is not available, rate-limit reached or login required", s) == .needsLogin)
        #expect(YtDlp.classify("[Pinterest] 1: No video formats found!", s) == .noVideo)
        #expect(YtDlp.classify("[twitter] 1: No video could be found in this tweet", s) == .noVideo)
        #expect(YtDlp.classify("Unable to download webpage: HTTP Error 404", s) == .other)
        let e = YtDlp.failure(bot, platform: .youtube, s)
        #expect(e.code == .locked && e.message.contains("downloader.cookiesFromBrowser"))
        #expect(YtDlp.errorText("noise\nERROR: [x] 1: broken; please report this issue on  https://example.com\n", s) == "[x] 1: broken")
        // Behind a sign-in wall with --ignore-no-formats-error, the reason is only a warning.
        let walled = "WARNING: [youtube] No title found\nWARNING: [youtube] Sign in to confirm you’re not a bot. See  https://example.com/faq  for how to pass cookies\nERROR: [youtube] abc: No video formats found!\n"
        let text = YtDlp.errorText(walled, s)
        #expect(text == "[youtube] Sign in to confirm you’re not a bot. | [youtube] abc: No video formats found!", "\(text)")
        #expect(YtDlp.classify(text, s) == .needsLogin, "the sign-in wall wins over no video")
        #expect(YtDlp.errorText("WARNING: [twitter] No video could be found in this tweet\nERROR: Requested format is not available\n", s)
                == "Requested format is not available", "other warnings are left out")
        #expect(YtDlp.errorText("ERROR: \n[download] Got error: reset. Giving up after 10 retries\n", s) == "Got error: reset. Giving up after 10 retries",
                "an empty ERROR line takes the next line")
    }
}

/// Cleanup with a project open: downloads that clips use stay unless forced.
@Suite(.serialized) struct SocialCleanupTests {
    @Test func refusesDownloadsThatClipsUse() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dme-social-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.trashItem(at: tmp, resultingItemURL: nil) }
        let editor = Editor(settings: try UserSettingsStore(directory: tmp.appendingPathComponent("home")), prober: AVMediaProber())
        let session = try await editor.createProject(at: tmp.appendingPathComponent("p").path, name: nil,
                                                     settings: ProjectSettings(width: 320, height: 240, frameRate: .fps30, dynamicRange: .sdr))
        let root = try SocialStore.projectRoot(session.url, editor.settings)
        #expect(root.path.hasPrefix(session.url.path), "downloads go inside the open project")
        func make(_ id: String) throws -> URL {
            let f = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: f.appendingPathComponent("inspect"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1000).write(to: f.appendingPathComponent("v.mp4"))
            try Data(repeating: 2, count: 50).write(to: f.appendingPathComponent("inspect/sheet-v.png"))
            try SocialStore.write(SocialItem(id: id, url: "https://x.com/a/status/1", platform: "x", downloadedAt: Date(), what: "all",
                                             source: "yt-dlp", metadata: SocialMetadata(platform: "x", url: "u", id: "1"),
                                             files: [SocialFile(name: "v.mp4", kind: .video, bytes: 1000)]), in: f)
            return f
        }
        let used = try make("x-used"), pooled = try make("x-pooled"), loose = try make("x-loose")
        let info = MediaInfo(duration: Time(seconds: 5), video: VideoInfo(width: 320, height: 240, frameRate: 30, codec: "avc1", bitDepth: 8, transfer: nil, primaries: nil), audio: nil)
        let track = await session.project.tracks[0].id
        _ = try await session.apply([
            AddMedia(assets: [MediaAsset(id: "m_used", path: used.appendingPathComponent("v.mp4").path, name: "v.mp4", fingerprint: "a", info: info),
                              MediaAsset(id: "m_pooled", path: pooled.appendingPathComponent("v.mp4").path, name: "v.mp4", fingerprint: "b", info: info)]),
            AddClip(track: track, asset: "m_used", start: .zero, id: "clip_1"),
        ])
        #expect(try await SocialStore.list(editor).map(\.item.id) == ["x-loose", "x-pooled", "x-used"])

        let r = try await SocialStore.cleanup(ids: ["x-used", "x-pooled", "x-loose"], all: false, force: false, editor: editor)
        #expect(r.refused.count == 1 && r.refused[0]["id"]?.stringValue == "x-used")
        #expect(r.refused[0]["reason"]?.stringValue?.contains("clip_1") == true && r.refused[0]["reason"]?.stringValue?.contains("force") == true)
        #expect(r.trashed.compactMap { $0["id"]?.stringValue } == ["x-pooled", "x-loose"])
        #expect(r.bytesFreed > 2 * 1000, "media, sidecar and inspect files")
        #expect(r.removedFromPool == ["m_pooled"], "an unused pool entry goes with its file")
        #expect(FileManager.default.fileExists(atPath: used.path))
        #expect(!FileManager.default.fileExists(atPath: pooled.path) && !FileManager.default.fileExists(atPath: loose.path))
        #expect(await session.project.media.map(\.id) == ["m_used"])

        await #expect(throws: EditorError.self) { try await SocialStore.cleanup(ids: ["x-gone"], all: false, force: false, editor: editor) }
        await #expect(throws: EditorError.self) { try await SocialStore.cleanup(ids: nil, all: false, force: false, editor: editor) }

        let forced = try await SocialStore.cleanup(ids: nil, all: true, force: true, editor: editor)
        #expect(forced.trashed.count == 1 && forced.refused.isEmpty)
        #expect(forced.trashed[0]["clipsLeftWithoutMedia"] == .array([.string("clip_1")]))
        #expect(!FileManager.default.fileExists(atPath: used.path))
        #expect(try await SocialStore.list(editor).isEmpty)
        try await editor.closeProject()
    }
}
