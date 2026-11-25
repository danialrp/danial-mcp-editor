import Darwin
import EditorCore
import Foundation

/// One command as stored in the journal and listed in the history.
public struct StoredCommand: Codable, Equatable, Sendable {
    public var name: String
    public var args: JSONValue

    public init(name: String, args: JSONValue) {
        self.name = name
        self.args = args
    }

    public init(_ command: any EditorCommand) throws {
        self.name = command.name
        self.args = try JSONValue.parse(CommandRegistry.encode(command))
    }

    public func decoded(stored: Bool = false) throws -> any EditorCommand {
        try CommandRegistry.decode(name: name, arguments: args.data(), stored: stored)
    }
}

/// One line of the journal.
public struct JournalEntry: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case apply, undo, redo }

    public var revision: Int
    public var op: Op
    public var commands: [StoredCommand]?
    public var at: Date
    /// For an undo or redo of a step made before the last snapshot, which
    /// the journal no longer holds: the project the undo or redo gives, and
    /// the revision the step made. Without them a reopen could not replay it.
    public var project: Project?
    public var stepRevision: Int?

    public init(revision: Int, op: Op, commands: [StoredCommand]? = nil, at: Date = Date(),
                project: Project? = nil, stepRevision: Int? = nil) {
        self.revision = revision
        self.op = op
        self.commands = commands
        self.at = at
        self.project = project
        self.stepRevision = stepRevision
    }
}

struct Snapshot: Codable {
    var revision: Int
    var project: Project
}

/// The project package on disk:
///
///     Name.dmeproj/
///       project.json    snapshot: the project at some revision
///       journal.jsonl   every change since that snapshot, one line each
///       .lock           held while a process has the project open
///
/// A journal line is written and flushed before the change is reported as
/// done, so a crash loses nothing that was confirmed.
final class ProjectStore {
    static let packageExtension = "dmeproj"

    let url: URL
    private var journalFD: Int32 = -1
    private var lockFD: Int32 = -1
    private(set) var journalCount = 0
    private(set) var journalBytes = 0

    private var snapshotURL: URL { url.appendingPathComponent("project.json") }
    private var journalURL: URL { url.appendingPathComponent("journal.jsonl") }
    private var lockURL: URL { url.appendingPathComponent(".lock") }

    private static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let lineDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init(url: URL) { self.url = url }

    deinit { close() }

    /// Creates a new package. Fails if anything exists at the path.
    static func create(at url: URL, project: Project) throws -> ProjectStore {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            throw EditorError(.conflict, "\(url.path) already exists")
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let s = ProjectStore(url: url)
        try s.lock()
        try s.writeSnapshot(project, revision: 0)
        try s.openJournal(truncate: true)
        return s
    }

    /// Opens a package and returns its snapshot and the journal written after it.
    static func open(at url: URL) throws -> (ProjectStore, Snapshot, [JournalEntry]) {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) else {
            throw EditorError(.notFound, "\(url.path) is not a project (no project.json)")
        }
        let s = ProjectStore(url: url)
        try s.lock()
        let snap: Snapshot
        do {
            snap = try lineDecoder.decode(Snapshot.self, from: Data(contentsOf: s.snapshotURL))
        } catch {
            throw EditorError(.io, "cannot read \(s.snapshotURL.path): \(error)")
        }
        let entries = try s.readJournal(after: snap.revision)
        try s.openJournal(truncate: false)
        s.journalCount = entries.count
        s.journalBytes = (try? FileManager.default.attributesOfItem(atPath: s.journalURL.path)[.size] as? Int) ?? 0
        return (s, snap, entries)
    }

    func append(_ entry: JournalEntry) throws {
        var line = try Self.lineEncoder.encode(entry)
        line.append(0x0A)
        try line.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(journalFD, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw EditorError(.io, "journal write failed: \(String(cString: strerror(errno)))")
                }
                off += n
            }
        }
        guard fsync(journalFD) == 0 else {
            throw EditorError(.io, "journal flush failed: \(String(cString: strerror(errno)))")
        }
        journalCount += 1
        journalBytes += line.count
    }

    /// Writes a new snapshot and empties the journal.
    func compact(_ project: Project, revision: Int) throws {
        try writeSnapshot(project, revision: revision)
        try openJournal(truncate: true)
        journalCount = 0
        journalBytes = 0
    }

    func close() {
        if journalFD >= 0 { Darwin.close(journalFD); journalFD = -1 }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }

    // MARK: private

    private func lock() throws {
        lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { throw EditorError(.io, "cannot create \(lockURL.path)") }
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(lockFD)
            lockFD = -1
            throw EditorError(.locked, "\(url.path) is open in another editor process")
        }
    }

    private func writeSnapshot(_ project: Project, revision: Int) throws {
        let data = try JSON.prettyEncoder.encode(Snapshot(revision: revision, project: project))
        try data.write(to: snapshotURL, options: .atomic)
    }

    private func openJournal(truncate: Bool) throws {
        if journalFD >= 0 { Darwin.close(journalFD) }
        let flags = O_WRONLY | O_CREAT | O_APPEND | (truncate ? O_TRUNC : 0)
        journalFD = Darwin.open(journalURL.path, flags, 0o644)
        guard journalFD >= 0 else { throw EditorError(.io, "cannot open \(journalURL.path)") }
        if truncate { fsync(journalFD) }
    }

    /// Reads journal lines newer than the snapshot. A damaged last line (a
    /// write cut short by a crash) is dropped and cut from the file; damage
    /// anywhere else is reported.
    private func readJournal(after revision: Int) throws -> [JournalEntry] {
        guard let data = try? Data(contentsOf: journalURL), !data.isEmpty else { return [] }
        var entries: [JournalEntry] = []
        var validLength = 0
        var lineStart = 0
        let bytes = [UInt8](data)
        var i = 0
        while i <= bytes.count {
            if i == bytes.count || bytes[i] == 0x0A {
                if i > lineStart {
                    let line = Data(bytes[lineStart..<i])
                    let complete = i < bytes.count
                    if let e = try? Self.lineDecoder.decode(JournalEntry.self, from: line), complete {
                        if e.revision > revision { entries.append(e) }
                        validLength = i + 1
                    } else if i >= bytes.count - 1 {
                        break  // damaged last line
                    } else {
                        throw EditorError(.io, "journal line \(entries.count + 1) is damaged in \(journalURL.path)")
                    }
                } else {
                    validLength = i + 1
                }
                lineStart = i + 1
            }
            i += 1
        }
        if validLength < bytes.count {
            truncate(journalURL.path, off_t(validLength))
        }
        return entries
    }
}
