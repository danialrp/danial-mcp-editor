import EditorCore
import EditorKit
import Foundation

/// yt-dlp as an external command (architecture, "External commands"): found
/// from settings, PATH or the usual Homebrew folders, run with a time limit,
/// its errors turned into messages an agent can act on.
public enum YtDlp {
    /// Finds a program. A name with a slash is used as it is (after `~`);
    /// a bare name is looked up in each folder of `path`, then in `folders`.
    public static func locate(_ name: String, path: String?, folders: [String], setting: String) throws -> URL {
        let fm = FileManager.default
        if name.contains("/") {
            let p = (name as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: p) else {
                throw EditorError(.notFound, "\(setting) is \(name), which is not an executable file. Set \(setting) with settings.set to the program's full path, or to its bare name to search PATH.")
            }
            return URL(fileURLWithPath: p)
        }
        let dirs = (path ?? "").split(separator: ":").map(String.init) + folders
        var seen: [String] = []
        for d in dirs where !d.isEmpty && !seen.contains(d) {
            seen.append(d)
            let p = (d as NSString).expandingTildeInPath + "/" + name
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        throw EditorError(.notFound, "\(name) was not found. Looked in PATH and \(folders.joined(separator: ", ")). Install it (for example `brew install \(name)`), or set \(setting) with settings.set to its full path.")
    }

    /// The yt-dlp program and arguments from settings.
    public static func command(_ s: UserSettings.DownloaderSettings) throws -> [String] {
        guard let first = s.command.first, !first.isEmpty else {
            throw EditorError.invalid("settings downloader.command is empty; set it to [\"yt-dlp\"] or to the program's full path")
        }
        let exe = try locate(first, path: ProcessInfo.processInfo.environment["PATH"], folders: s.searchFolders, setting: "downloader.command")
        return [exe.path] + s.command.dropFirst()
    }

    /// The folder holding ffmpeg, or nil when it is not installed.
    public static func ffmpegFolder(_ s: UserSettings.DownloaderSettings) -> URL? {
        guard !s.ffmpeg.isEmpty else { return nil }
        return (try? locate(s.ffmpeg, path: ProcessInfo.processInfo.environment["PATH"], folders: s.searchFolders, setting: "downloader.ffmpeg"))?
            .deletingLastPathComponent()
    }

    /// Arguments every call gets: settings, the browser sign-in if set.
    static func common(_ s: UserSettings.DownloaderSettings) -> [String] {
        var a = ["--no-color"]
        if !s.cookiesFromBrowser.isEmpty { a += ["--cookies-from-browser", s.cookiesFromBrowser] }
        if let f = ffmpegFolder(s) { a += ["--ffmpeg-location", f.path] }
        return a + s.extraArguments
    }

    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: String
        public var timedOut: Bool
    }

    /// Runs a program; stdout and stderr are kept apart, each stderr line
    /// (and stdout line that is not JSON) goes to `line`.
    public static func run(_ argv: [String], folders: [String], timeout: Double,
                           line: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        // yt-dlp needs a JavaScript runtime for YouTube and ffmpeg for
        // joining; both live in the same folders.
        env["PATH"] = (folders + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let o = Unchecked(NSMutableData()), e = Unchecked(LineBuffer(line))
        let lock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { lock.lock(); o.value.append(d); lock.unlock() }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { lock.lock(); e.value.add(d); lock.unlock() }
        }
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Task.isCancelled { p.terminate(); break }
            if Date() > deadline { timedOut = true; p.terminate(); break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let result = lock.withLock {
            if let rest = try? out.fileHandleForReading.readToEnd() { o.value.append(rest) }
            if let rest = try? err.fileHandleForReading.readToEnd() { e.value.add(rest) }
            e.value.flush()
            return Output(status: p.terminationStatus, stdout: o.value as Data, stderr: e.value.text, timedOut: timedOut)
        }
        try Task.checkCancellation()
        return result
    }

    final class LineBuffer {
        var text = ""
        private var pending = Data()
        private let line: (@Sendable (String) -> Void)?
        init(_ line: (@Sendable (String) -> Void)?) { self.line = line }
        func add(_ d: Data) {
            pending.append(d)
            while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                emit(pending[pending.startIndex..<nl])
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        func flush() { if !pending.isEmpty { emit(pending); pending = Data() } }
        private func emit(_ d: Data) {
            let s = String(decoding: d, as: UTF8.self)
            guard !s.isEmpty else { return }
            text += s + "\n"
            line?(s)
        }
    }

    /// What went wrong, for an agent: yt-dlp's ERROR lines and the warnings
    /// that say the site wants a sign-in (with --ignore-no-formats-error a
    /// sign-in wall shows only as a warning before "No video formats
    /// found"), or else its last output.
    public static func errorText(_ stderr: String, _ s: UserSettings.DownloaderSettings) -> String {
        var lines: [String] = []
        let all = stderr.split(separator: "\n").map(String.init)
        for (i, l) in all.enumerated() {
            var text: String?
            // An ERROR line can be empty, its message on the next line.
            if l.hasPrefix("ERROR:") {
                text = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if text?.isEmpty == true, i + 1 < all.count { text = all[i + 1].replacingOccurrences(of: "[download] ", with: "") }
            } else if l.hasPrefix("WARNING: "), s.loginHints.contains(where: { l.lowercased().contains($0.lowercased()) }) {
                text = String(l.dropFirst(9))
            }
            // yt-dlp's long help links and report advice say nothing to an agent.
            guard let t = text?.replacingOccurrences(of: #";? ?please report this issue on.*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #" See +https://[^ ]+ +for how to.*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces), !t.isEmpty, !lines.contains(t) else { continue }
            lines.append(t)
        }
        if lines.isEmpty { return String(stderr.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.suffix(3).joined(separator: " | ")
    }

    public enum Failure: Equatable, Sendable { case needsLogin, noVideo, other }

    public static func classify(_ message: String, _ s: UserSettings.DownloaderSettings) -> Failure {
        let m = message.lowercased()
        // A sign-in wall first: behind one yt-dlp also finds no video.
        if s.loginHints.contains(where: { m.contains($0.lowercased()) }) { return .needsLogin }
        if s.noVideoHints.contains(where: { m.contains($0.lowercased()) }) { return .noVideo }
        return .other
    }

    /// The error a failed call becomes.
    public static func failure(_ message: String, platform: SocialPlatform, _ s: UserSettings.DownloaderSettings) -> EditorError {
        switch classify(message, s) {
        case .needsLogin where s.cookiesFromBrowser.isEmpty:
            return EditorError(.locked, "\(platform.rawValue) wants a signed-in session for this item: \(message). To use a browser's sign-in, set downloader.cookiesFromBrowser (for example \"safari\" or \"chrome\") with settings.set, then try again.")
        case .needsLogin:
            return EditorError(.locked, "\(platform.rawValue) refused the item even with the sign-in of \(s.cookiesFromBrowser): \(message). Check that this browser is signed in to \(platform.rawValue).")
        default:
            return EditorError(.io, "yt-dlp failed: \(message)")
        }
    }
}
