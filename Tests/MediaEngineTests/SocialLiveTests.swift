import EditorCore
import EditorKit
import Foundation
@testable import MediaEngine
import Testing

/// Downloads real public posts through the social tools, inspects them and
/// cleans up. Needs the network and yt-dlp, so it runs only with
/// DME_LIVE_SOCIAL=1. DME_LIVE_SOCIAL_URLS (links separated by spaces or
/// commas) replaces the built-in list; those links are reported, not required.
/// Browser sign-ins are never used here: downloader.cookiesFromBrowser stays off.
@Suite("Social downloads (live)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["DME_LIVE_SOCIAL"] == "1"))
struct SocialLiveTests {
    struct Case {
        var url: String
        var what: String = "all"
        /// Must download; otherwise the outcome is only reported.
        var required: Bool
        var expect: SocialFile.Kind?
    }

    /// Public posts, checked to exist.
    static let builtIn: [Case] = [
        Case(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", required: true, expect: .video),
        Case(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", required: false, expect: .video),
        Case(url: "https://www.pinterest.com/pin/456411743503928724/", required: true, expect: .video),
        Case(url: "https://www.pinterest.com/pin/679973243780791131/", required: true, expect: .image),
        Case(url: "https://x.com/NASA/status/2001331807124332572", required: true, expect: .video),
        Case(url: "https://x.com/apod/status/1972468975851262242", required: true, expect: .image),
        Case(url: "https://x.com/NASA/status/2001331807124332572", what: "audio", required: true, expect: .audio),
        Case(url: "https://www.instagram.com/reel/Dfc1mYxFevS/", required: false, expect: .video),
        Case(url: "https://www.instagram.com/p/Df-NlR0PjmN/", required: false, expect: .image),
        Case(url: "https://www.instagram.com/p/DfkkknjD6vm/", required: false, expect: nil),
    ]

    static var cases: [Case] {
        guard let list = ProcessInfo.processInfo.environment["DME_LIVE_SOCIAL_URLS"], !list.isEmpty else { return builtIn }
        return list.split(whereSeparator: { $0 == "," || $0 == " " }).map { Case(url: String($0), required: false, expect: nil) }
    }

    @Test func downloadInspectAndCleanUp() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dme-social-live-\(UUID().uuidString)")
        defer { try? FileManager.default.trashItem(at: tmp, resultingItemURL: nil) }
        let settings = try UserSettingsStore(directory: tmp.appendingPathComponent("home"))
        #expect(settings.current.downloader.cookiesFromBrowser.isEmpty)
        let editor = Editor(settings: settings, prober: AVMediaProber())
        let media = MediaContext(editor: editor)
        let jobs = JobCenter()
        let tools = Dictionary(uniqueKeysWithValues: SocialTools.make(media, jobs: jobs).map { ($0.name, $0) })
        func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            try await tools[name]!.call(editor, arguments: .object(args))
        }
        _ = try await editor.createProject(at: tmp.appendingPathComponent("live").path, name: nil,
                                           settings: ProjectSettings(width: 1080, height: 1920, frameRate: .fps30, dynamicRange: .sdr))
        var report: [String] = []
        var imported = false
        for c in Self.cases {
            let started = Date()
            do {
                if c.url.contains("youtube") {
                    let info = try await call("social.info", ["url": .string(c.url)])
                    #expect(info["metadata"]?["title"]?.stringValue?.isEmpty == false)
                }
                var args: [String: JSONValue] = ["url": .string(c.url), "what": .string(c.what)]
                // One YouTube video also brings its captions and goes into the pool.
                let first = c.url.contains("youtube") && !imported
                if first { args["subtitles"] = .bool(true); args["import"] = .bool(true) }
                let start = try await call("social.download", args)
                let jobID = try #require(start["jobId"]?.stringValue)
                let job = try await jobs.wait(jobID, timeout: 1800)
                guard job.state == .done, let result = job.result else {
                    throw EditorError(.io, job.error ?? "job \(job.state.rawValue)")
                }
                let id = try #require(result["id"]?.stringValue)
                let files = try (result["files"] ?? .array([])).decode([SocialFile].self)
                #expect(!files.isEmpty)
                if let k = c.expect { #expect(files.contains { $0.kind == k }, "\(c.url): expected a \(k.rawValue), got \(files.map(\.name))") }
                for f in files where f.kind == .video { #expect((f.duration ?? 0) > 0 && (f.width ?? 0) > 0, "\(f.name) reads in AVFoundation") }
                if first {
                    imported = true
                    #expect(result["imported"]?.arrayValue?.isEmpty == false, "imported into the pool")
                }
                let inspect = try await call("social.inspect", ["id": .string(id), "frames": .number(2)])
                if files.contains(where: { $0.kind == .video || $0.kind == .image }) {
                    #expect(inspect["sheet"]?["path"]?.stringValue.map { FileManager.default.fileExists(atPath: $0) } == true, "\(c.url): a contact sheet")
                    #expect(inspect["images"]?.arrayValue?.count == 1, "the sheet is returned as an image")
                }
                if files.contains(where: { $0.kind == .video }) { #expect(inspect["frames"]?.arrayValue?.count == 2) }
                if files.contains(where: { $0.kind == .audio }) { #expect(inspect["audio"]?["integratedLUFS"]?.doubleValue != nil, "loudness of the sound") }
                let subs = inspect["subtitles"]?.arrayValue?.count ?? 0
                let loud = inspect["audio"]?["integratedLUFS"]?.doubleValue
                let list = try await call("social.list", [:])
                #expect(list["downloads"]?.arrayValue?.contains { $0["id"]?.stringValue == id } == true)
                let kinds = files.map { "\($0.kind.rawValue) \($0.width ?? 0)x\($0.height ?? 0)\($0.duration.map { String(format: " %.1fs", $0) } ?? "")" }
                report.append("WORKED \(c.url) -> \(id) via \(result["source"]?.stringValue ?? "?"): \(kinds.joined(separator: ", ")); warnings \(result["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? [])"
                              + "; subtitles \(subs); loudness \(loud.map { "\($0) LUFS" } ?? "-"); \(Int(Date().timeIntervalSince(started))) s")
            } catch {
                let login = (error as? EditorError)?.code == .locked
                report.append("\(login ? "NEEDS LOGIN" : "FAILED") \(c.url): \(error)")
                if c.required { Issue.record("\(c.url) did not download: \(error)") }
            }
        }
        // Everything into the Trash; the imported video's pool entry goes too.
        let clean = try await call("social.cleanup", ["all": .bool(true)])
        #expect(clean["refused"]?.arrayValue?.isEmpty == true)
        report.append("CLEANUP trashed \(clean["trashed"]?.arrayValue?.count ?? 0), freed \(clean["bytesFreed"]?.intValue ?? 0) bytes, removed from pool \(clean["removedFromPool"]?.arrayValue?.count ?? 0)")
        #expect(try await SocialStore.list(editor).isEmpty)
        try await editor.closeProject()
        print(report.map { "LIVE " + $0 }.joined(separator: "\n"))
    }
}
