import EditorCore
import Foundation
@testable import EditorKit
import Testing

@Suite struct DownloaderSettingsTests {
    func store() throws -> (UserSettingsStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-dl-\(UUID().uuidString)")
        return (try UserSettingsStore(directory: dir), dir)
    }

    @Test func defaults() throws {
        let d = UserSettings.defaults().downloader
        #expect(d.command == ["yt-dlp"] && d.ffmpeg == "ffmpeg")
        #expect(d.searchFolders == ["/opt/homebrew/bin", "/usr/local/bin"])
        #expect(d.cookiesFromBrowser.isEmpty, "no browser sign-in unless the owner sets one")
        #expect(d.projectFolder == "downloads" && d.cacheFolder.isEmpty)
        #expect(d.defaultQuality == "1080" && d.qualities[d.defaultQuality] != nil)
        #expect(d.qualities["1080"]?.joined(separator: " ").contains("vcodec:h264") == true, "H.264 first, which AVFoundation reads")
        #expect(d.mergeFormat == "mp4" && d.playlistLimit == 20 && d.sheetFrames == 12)
        #expect(!d.loginHints.isEmpty && !d.noVideoHints.isEmpty)
    }

    @Test func olderSettingsFilesGetTheDefaults() throws {
        let (s, dir) = try store()
        defer { try? FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
        // A settings file written before the downloader existed, and one with only some of its keys.
        var tree = try JSONValue(encoding: s.current).objectValue!
        tree["downloader"] = nil
        #expect(try JSONValue.object(tree).decode(UserSettings.self).downloader == UserSettings.DownloaderSettings())
        tree["downloader"] = .object(["cookiesFromBrowser": .string("safari"), "playlistLimit": .number(3)])
        let partial = try JSONValue.object(tree).decode(UserSettings.self).downloader
        #expect(partial.cookiesFromBrowser == "safari" && partial.playlistLimit == 3 && partial.command == ["yt-dlp"])
    }

    @Test func setByDottedKey() throws {
        let (s, dir) = try store()
        defer { try? FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
        try s.set(key: "downloader.cookiesFromBrowser", value: .string("chrome"))
        try s.set(key: "downloader.command", value: .array([.string("/usr/local/bin/yt-dlp")]))
        #expect(s.current.downloader.cookiesFromBrowser == "chrome" && s.current.downloader.command == ["/usr/local/bin/yt-dlp"])
        #expect(try UserSettingsStore(directory: dir).current.downloader.cookiesFromBrowser == "chrome", "saved to the file")
        #expect(throws: EditorError.self) { try s.set(key: "downloader.noSuchKey", value: .bool(true)) }
        #expect(throws: EditorError.self) { try s.set(key: "downloader.playlistLimit", value: .string("many")) }
    }
}
