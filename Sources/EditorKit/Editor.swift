import EditorCore
import Foundation

/// Reads the properties of a media file. The AVFoundation implementation lives
/// in `MediaEngine`; tests use a fake.
public protocol MediaProber: Sendable {
    func probe(_ url: URL) async throws -> MediaInfo
}

/// The editor as a whole: user settings, the media prober and the open project.
/// One project is open at a time.
public actor Editor {
    public static let version = "0.1.0"

    public nonisolated let settings: UserSettingsStore
    public nonisolated let prober: any MediaProber
    public private(set) var session: EditorSession? {
        didSet { for c in sessionWatchers.values { c.yield(session.map { SessionRef($0) }) } }
    }
    private var sessionWatchers: [UUID: AsyncStream<SessionRef?>.Continuation] = [:]

    /// Announces every project open and close (nil when none is open).
    public func sessions() -> AsyncStream<SessionRef?> {
        let id = UUID()
        let (stream, c) = AsyncStream<SessionRef?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sessionWatchers[id] = c
        c.yield(session.map { SessionRef($0) })
        c.onTermination = { [weak self] _ in Task { await self?.dropSessionWatcher(id) } }
        return stream
    }

    private func dropSessionWatcher(_ id: UUID) { sessionWatchers[id] = nil }

    public init(settings: UserSettingsStore, prober: any MediaProber) {
        self.settings = settings
        self.prober = prober
    }

    public func requireSession() throws -> EditorSession {
        guard let session else {
            throw EditorError(.notFound, "no project is open; call project.open or project.create first")
        }
        return session
    }

    /// Creates a project with a main track and opens it.
    public func createProject(at path: String, name: String?, settings ps: ProjectSettings) async throws -> EditorSession {
        let url = Self.packageURL(path)
        await closeBeforeSwitching()
        var p = Project(id: .random("project"), name: name ?? url.deletingPathExtension().lastPathComponent, settings: ps)
        p.tracks = [Track(id: .random("track"), kind: .main, name: "Main")]
        let s = try EditorSession.create(at: url, project: p, undoDepth: self.settings.current.undoDepth)
        session = s
        try remember(url)
        return s
    }

    public func openProject(at path: String) async throws -> EditorSession {
        let url = Self.packageURL(path)
        if let session, session.url.standardizedFileURL == url.standardizedFileURL { return session }
        await closeBeforeSwitching()
        let s = try await EditorSession.open(at: url, undoDepth: settings.current.undoDepth)
        session = s
        try remember(url)
        return s
    }

    /// Closes the open project before another one opens. Every confirmed
    /// change is already in its journal, so a failed final snapshot (for
    /// example because its folder was moved away) loses nothing and must not
    /// stop the switch.
    private func closeBeforeSwitching() async {
        try? await closeProject()
    }

    public func closeProject() async throws {
        guard let s = session else { return }
        session = nil
        try await s.close()
    }

    private func remember(_ url: URL) throws {
        // Scratch projects in the temporary folder (the self-test makes one
        // each run) are not the owner's work: they stay out of Open Recent.
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        func scratch(_ path: String) -> Bool { URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(temp) }
        try settings.update { s in
            s.recentProjects.removeAll { $0 == url.path || scratch($0) }
            guard !scratch(url.path) else { return }
            s.recentProjects.insert(url.path, at: 0)
            if s.recentProjects.count > 20 { s.recentProjects.removeLast(s.recentProjects.count - 20) }
        }
    }

    /// Adds the package extension when it is missing and expands `~`.
    public static func packageURL(_ path: String) -> URL {
        var p = (path as NSString).expandingTildeInPath
        if !p.hasSuffix("." + ProjectStore.packageExtension) { p += "." + ProjectStore.packageExtension }
        return URL(fileURLWithPath: p).standardizedFileURL
    }

    /// Size and modification time of a file, to notice when it changes.
    public static func fingerprint(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (a[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int64(mtime * 1000))"
    }
}

/// A sendable handle to a session, for streams.
public struct SessionRef: Sendable {
    public let session: EditorSession
    init(_ s: EditorSession) { session = s }
}
