import AppKit
import AVFoundation
import Darwin
import EditorCore
import EditorKit
import Foundation

/// Gets word-level transcripts from the Edits app through its local MCP
/// server (requirements T-1 to T-3a).
///
/// - Only the sound goes to Edits, as a temporary WAV; never video.
/// - Edits in use (a project its user opened, an export running) is never
///   touched: the job waits until it is free.
/// - Everything the job creates is removed afterwards: its Edits project, the
///   WAV, and Edits' own copies of it. Edits is quit again if the job started it.
public actor EditsBridge {
    let settings: UserSettingsStore

    public init(settings: UserSettingsStore) { self.settings = settings }

    public struct Result: Sendable {
        public var words: [TranscriptWord]
        /// Things the job made that could not be removed.
        public var leftovers: [String]
        /// New files in Edits' library that do not carry the job's name.
        public var otherNewFiles: [String]
    }

    public func transcribe(_ asset: MediaAsset, from start: Time, to end: Time, language: String,
                           job: JobCenter.Context) async throws -> Result {
        let cfg = settings.current.edits
        let lock = try await takeLock(job)
        defer { flock(lock, LOCK_UN); close(lock) }

        let tag = "dme-transcript-" + job.id.replacingOccurrences(of: "job_", with: "")
        let folder = URL(fileURLWithPath: (cfg.importFolder as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent(tag + ".wav")

        await job.progress(0.02, "extracting the sound")
        try await Self.writeWAV(asset, from: start, to: end, to: wav)
        defer { try? FileManager.default.trashItem(at: wav, resultingItemURL: nil) }

        let wavSize = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? -1
        let wasRunning = Self.running(cfg.bundleID) != nil
        let client = try EditsClient(url: cfg.url, token: cfg.token)
        if wasRunning {
            try await waitUntilFree(client, job: job, limit: cfg.waitWhenBusySeconds)
        } else {
            await job.progress(0.05, "starting Edits")
            try await launch(cfg, client: client)
        }
        let before = Self.mediaFiles()
        var words: [TranscriptWord] = []
        var failure: Error?
        do {
            await job.progress(0.1, "transcribing in Edits")
            _ = try await client.call("newProject")
            _ = try await client.call("setTitle", ["name": .string(tag)])
            let alias = try await client.call("importToMediaBin", ["path": .string(wav.path)])["aliasId"]?.stringValue
            guard let alias else { throw EditorError(.io, "Edits did not import the sound") }
            var r = try await client.call("transcribeClip", ["id": .string(alias), "language": .string(language),
                                                              "mergeSplitWords": .bool(true), "background": .bool(false)])
            while r["status"]?.stringValue == "running", let jid = r["jobId"]?.stringValue {
                try job.checkCancelled()
                await job.progress(0.1 + 0.8 * (r["progress"]?.doubleValue ?? 0), "transcribing in Edits")
                r = try await client.call("jobStatus", ["id": .string(jid)])
            }
            let result = r["result"] ?? r
            if result["ok"]?.boolValue == false { throw EditorError(.io, "Edits could not transcribe: \(result)") }
            words = (result["words"]?.arrayValue ?? []).compactMap { w in
                guard let text = (w["text"] ?? w["word"])?.stringValue, let s = w["start"]?.doubleValue, let e = w["end"]?.doubleValue else { return nil }
                return TranscriptWord(text: text, start: start + Time(seconds: s), end: start + Time(seconds: e))
            }
        } catch {
            failure = error
        }

        // Clean up whatever happened above.
        await job.progress(0.92, "cleaning up Edits")
        var leftovers: [String] = []
        if (try? await client.call("closeProject")) == nil { leftovers.append("could not close the work project") }
        if let list = try? await client.call("projects")["projects"]?.arrayValue {
            for p in list where p["name"]?.stringValue == tag {
                if let id = p["id"]?.stringValue, (try? await client.call("deleteProject", ["id": .string(id)])) == nil {
                    leftovers.append("Edits project \(tag)")
                }
            }
        }
        if !wasRunning { await quit(cfg.bundleID) }
        // Removed: files that carry this job's name, and Edits' own copy of the
        // WAV (Edits names it by a random id, so it is matched by its exact
        // size). Other new files may belong to a project Edits reopened by
        // itself; they are only reported.
        var unknown: [String] = []
        for f in Self.mediaFiles().subtracting(before) {
            let size = (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? Int) ?? -2
            if f.contains(tag) || (f.contains("/Media/Original/") && f.hasSuffix(".wav") && size == wavSize) {
                if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: f), resultingItemURL: nil)) == nil { leftovers.append(f) }
            } else {
                unknown.append(f)
            }
        }
        if let failure { throw failure }
        return Result(words: words.sorted { $0.start < $1.start }, leftovers: leftovers, otherNewFiles: unknown)
    }

    // MARK: steps

    /// One bridge job at a time across every editor process on this Mac.
    private func takeLock(_ job: JobCenter.Context) async throws -> Int32 {
        let path = settings.directory.appendingPathComponent("edits-bridge.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw EditorError(.io, "cannot create \(path)") }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            await job.progress(0, "waiting for another transcription to finish")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return fd
    }

    /// Edits that was already running is in use when a project is open in it
    /// or an export runs; then the job waits.
    private func waitUntilFree(_ client: EditsClient, job: JobCenter.Context, limit: Double) async throws {
        let started = Date()
        while true {
            let screen = try await client.call("appState")["screen"]?.stringValue ?? ""
            let export = (try? await client.call("exportStatus")["state"]?.stringValue) ?? "idle"
            let busy = screen == "editor" || ["preparing", "exporting", "rendering", "running"].contains(export)
            if !busy, screen != "loading" { return }
            if Date().timeIntervalSince(started) > limit {
                throw EditorError(.conflict, "Edits has been in use for \(Int(limit)) s (\(screen == "editor" ? "a project is open" : "an export is running")); try again when it is free")
            }
            await job.progress(0, "Edits is in use; waiting until it is free")
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private func launch(_ cfg: UserSettings.EditsBridgeSettings, client: EditsClient) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: cfg.appPath), configuration: config)
        // Ready when its server answers and it has left the loading screen.
        for _ in 0..<120 {
            if let s = try? await client.call("appState")["screen"]?.stringValue, s != "loading" { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw EditorError(.io, "Edits started but its MCP server did not answer within 2 minutes")
    }

    private func quit(_ bundleID: String) async {
        guard let app = Self.running(bundleID) else { return }
        app.terminate()
        for _ in 0..<60 where !app.isTerminated { try? await Task.sleep(nanoseconds: 500_000_000) }
    }

    nonisolated static func running(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Files Edits keeps for imported media (copies and proxies).
    nonisolated static func mediaFiles() -> Set<String> {
        let libs = URL(fileURLWithPath: ("~/Movies/Edits/Libraries" as NSString).expandingTildeInPath)
        var out = Set<String>()
        let fm = FileManager.default
        for lib in (try? fm.contentsOfDirectory(at: libs, includingPropertiesForKeys: nil)) ?? [] {
            for sub in ["Media/Original", "Media/Proxies"] {
                let d = lib.appendingPathComponent(sub)
                for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] { out.insert(d.appendingPathComponent(f).path) }
            }
        }
        return out
    }

    /// The sound of a stretch of a file as a 16-bit WAV.
    static func writeWAV(_ a: MediaAsset, from start: Time, to end: Time, to url: URL) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: a.path))
        var file: AVAudioFile?
        try await AudioReader.stream(asset, range: CMTimeRange(start: cm(start), end: cm(end))) { s, ch in
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioReader.rate, AVNumberOfChannelsKey: ch,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            let frames = s.count / ch
            guard let f = file, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buf.frameLength = AVAudioFrameCount(frames)
            for c in 0..<ch {
                let dst = buf.floatChannelData![c]
                for i in 0..<frames { dst[i] = s[i * ch + c] }
            }
            try f.write(from: buf)
        }
        guard file != nil else { throw EditorError.invalid("media \(a.id) has no sound in that range") }
    }
}

/// A small client for the Edits MCP server.
struct EditsClient: Sendable {
    let url: URL
    let headers: [String: String]

    init(url: String, token: String) throws {
        guard let u = URL(string: url) else { throw EditorError.invalid("edits.url is not a URL") }
        self.url = u
        var t = token
        if t.isEmpty { t = Self.tokenFromClaudeConfig() ?? "" }
        guard !t.isEmpty else {
            throw EditorError(.invalid, "no token for Edits: set edits.token in the settings file, or set up the Edits MCP server in Claude Code")
        }
        headers = ["Authorization": t.hasPrefix("Bearer ") ? t : "Bearer \(t)"]
    }

    /// The Edits setup stores its header in Claude Code's config; reuse it
    /// rather than copy the token anywhere else.
    static func tokenFromClaudeConfig() -> String? {
        let path = ("~/.claude.json" as NSString).expandingTildeInPath
        guard let d = FileManager.default.contents(atPath: path), let j = try? JSONValue.parse(d) else { return nil }
        return j["mcpServers"]?["metapilot-native"]?["headers"]?["Authorization"]?.stringValue
    }

    /// Calls one Edits tool and returns its JSON result.
    func call(_ name: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        let body: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                                       "params": .object(["name": .string(name), "arguments": .object(args)])])
        var req = URLRequest(url: url, timeoutInterval: 900)
        req.httpMethod = "POST"
        req.httpBody = try body.data()
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EditorError(.io, "Edits answered \( (response as? HTTPURLResponse)?.statusCode ?? 0) to \(name)")
        }
        let r = try JSONValue.parse(data)
        if let e = r["error"] { throw EditorError(.io, "Edits \(name): \(e)") }
        guard let text = r["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue else {
            throw EditorError(.io, "Edits \(name): empty answer")
        }
        guard let out = try? JSONValue.parse(Data(text.utf8)) else { throw EditorError(.io, "Edits \(name): \(text)") }
        if out["ok"]?.boolValue == false { throw EditorError(.io, "Edits \(name) failed: \(text.prefix(300))") }
        return out
    }
}
