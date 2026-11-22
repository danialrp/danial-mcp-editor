import EditorCore
import Foundation

/// The result of applying commands.
public struct ApplyResult: Codable, Sendable {
    /// Revision after the change (unchanged for a dry run).
    public var revision: Int
    public var dryRun: Bool
    /// The commands as applied: times snapped and new ids filled in.
    public var applied: [StoredCommand]
}

/// One step in the history of the open session.
public struct HistoryRecord: Codable, Sendable {
    public var revision: Int
    public var op: JournalEntry.Op
    public var commands: [StoredCommand]?
    public var at: Date
}

/// The command bus for one open project.
///
/// Every change goes through `apply`, `undo` or `redo`. Changes are ordered by
/// the actor, written to the journal before they count, and kept in an undo
/// history of whole-project states. Unchanged parts of those states share
/// storage, so a step costs only what it changed.
public actor EditorSession {
    public nonisolated let url: URL
    /// Tells this opening of a project from every other. An object's address
    /// cannot: the next session often gets the address of the one just closed.
    public nonisolated let instanceID = UUID()
    public private(set) var project: Project
    public private(set) var revision: Int

    private let store: ProjectStore
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private var records: [HistoryRecord] = []
    private let undoDepth: Int
    private let compactEvery: Int
    private var watchers: [UUID: AsyncStream<Int>.Continuation] = [:]

    private struct Step {
        var revision: Int        // revision the step produced
        var commands: [StoredCommand]
        var before: Project
        var after: Project
    }

    private init(store: ProjectStore, project: Project, revision: Int, undoDepth: Int, compactEvery: Int) {
        self.url = store.url
        self.store = store
        self.project = project
        self.revision = revision
        self.undoDepth = undoDepth
        self.compactEvery = compactEvery
    }

    /// Creates a new project package.
    public static func create(at url: URL, project: Project, undoDepth: Int = 500, compactEvery: Int = 1000) throws -> EditorSession {
        let store = try ProjectStore.create(at: url, project: project)
        return EditorSession(store: store, project: project, revision: 0, undoDepth: undoDepth, compactEvery: compactEvery)
    }

    /// Opens a package, replays its journal and writes a fresh snapshot.
    public static func open(at url: URL, undoDepth: Int = 500, compactEvery: Int = 1000) async throws -> EditorSession {
        let (store, snap, entries) = try ProjectStore.open(at: url)
        let s = EditorSession(store: store, project: snap.project, revision: snap.revision,
                              undoDepth: undoDepth, compactEvery: compactEvery)
        try await s.replay(entries)
        return s
    }

    /// Releases the project without a final snapshot, as a crash would.
    /// For tests of crash recovery.
    func abandonForTesting() {
        store.close()
    }

    /// Writes a final snapshot and releases the project.
    public func close() throws {
        for c in watchers.values { c.finish() }
        watchers.removeAll()
        try store.compact(project, revision: revision)
        store.close()
    }

    // MARK: changes

    /// Applies commands as one atomic step. With `dryRun` nothing changes and
    /// the result shows what would be applied.
    @discardableResult
    public func apply(_ commands: [any EditorCommand], ifRevision: Int? = nil, dryRun: Bool = false) throws -> ApplyResult {
        if let ifRevision, ifRevision != revision {
            throw EditorError(.staleRevision, "the project is at revision \(revision), not \(ifRevision); read it again and retry")
        }
        guard !commands.isEmpty else { throw EditorError.invalid("no commands to apply") }
        var p = project
        var applied: [StoredCommand] = []
        for (i, var c) in commands.enumerated() {
            do {
                try c.prepare(in: p)
                try c.apply(to: &p)
            } catch var e as EditorError {
                if commands.count > 1 { e.message = "command \(i) (\(c.name)): \(e.message)" }
                throw e
            }
            applied.append(try StoredCommand(c))
        }
        if dryRun { return ApplyResult(revision: revision, dryRun: true, applied: applied) }
        try commit(.apply, commands: applied, before: project, after: p)
        return ApplyResult(revision: revision, dryRun: false, applied: applied)
    }

    public func applyStored(_ stored: [StoredCommand], ifRevision: Int? = nil, dryRun: Bool = false) throws -> ApplyResult {
        try apply(stored.map { try $0.decoded() }, ifRevision: ifRevision, dryRun: dryRun)
    }

    @discardableResult
    public func undo() throws -> Int {
        guard let step = undoStack.last else { throw EditorError.invalid("nothing to undo") }
        try store.append(JournalEntry(revision: revision + 1, op: .undo))
        undoStack.removeLast()
        redoStack.append(step)
        project = step.before
        revision += 1
        records.append(HistoryRecord(revision: revision, op: .undo, commands: step.commands, at: Date()))
        notify()
        try compactIfNeeded()
        return revision
    }

    @discardableResult
    public func redo() throws -> Int {
        guard let step = redoStack.last else { throw EditorError.invalid("nothing to redo") }
        try store.append(JournalEntry(revision: revision + 1, op: .redo))
        redoStack.removeLast()
        undoStack.append(step)
        project = step.after
        revision += 1
        records.append(HistoryRecord(revision: revision, op: .redo, commands: step.commands, at: Date()))
        notify()
        try compactIfNeeded()
        return revision
    }

    /// Undoes steps until the project is back to how it was at `target`.
    @discardableResult
    public func revert(to target: Int) throws -> Int {
        guard target <= revision else { throw EditorError.invalid("revision \(target) is in the future", parameter: "revision") }
        // Applied steps made after `target`, newest first.
        while let top = undoStack.last, top.revision > target {
            try undo()
        }
        if let top = undoStack.last, top.revision > target {
            throw EditorError.invalid("revision \(target) is older than the undo history", parameter: "revision")
        }
        return revision
    }

    /// A stream of revisions, one value per change (apply, undo or redo).
    /// The UI and the player rebuild from it.
    public func changes() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, c) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        watchers[id] = c
        c.onTermination = { [weak self] _ in Task { await self?.dropWatcher(id) } }
        return stream
    }

    private func dropWatcher(_ id: UUID) { watchers[id] = nil }

    private func notify() { for c in watchers.values { c.yield(revision) } }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func history(since: Int = 0, limit: Int = 100) -> [HistoryRecord] {
        Array(records.filter { $0.revision > since }.suffix(limit))
    }

    // MARK: private

    private func commit(_ op: JournalEntry.Op, commands: [StoredCommand], before: Project, after: Project) throws {
        try store.append(JournalEntry(revision: revision + 1, op: op, commands: commands))
        revision += 1
        project = after
        undoStack.append(Step(revision: revision, commands: commands, before: before, after: after))
        if undoStack.count > undoDepth { undoStack.removeFirst(undoStack.count - undoDepth) }
        redoStack.removeAll()
        records.append(HistoryRecord(revision: revision, op: op, commands: commands, at: Date()))
        notify()
        try compactIfNeeded()
    }

    private func compactIfNeeded() throws {
        if store.journalCount >= compactEvery { try store.compact(project, revision: revision) }
    }

    /// Re-applies journal entries after a crash or a normal close.
    private func replay(_ entries: [JournalEntry]) throws {
        for e in entries {
            guard e.revision == revision + 1 else {
                throw EditorError(.io, "journal skips from revision \(revision) to \(e.revision)")
            }
            switch e.op {
            case .apply:
                var p = project
                for c in e.commands ?? [] { try c.decoded().apply(to: &p) }
                revision += 1
                undoStack.append(Step(revision: revision, commands: e.commands ?? [], before: project, after: p))
                if undoStack.count > undoDepth { undoStack.removeFirst() }
                redoStack.removeAll()
                project = p
            case .undo:
                guard let s = undoStack.popLast() else { throw EditorError(.io, "journal undo at revision \(e.revision) has nothing to undo") }
                redoStack.append(s)
                project = s.before
                revision += 1
            case .redo:
                guard let s = redoStack.popLast() else { throw EditorError(.io, "journal redo at revision \(e.revision) has nothing to redo") }
                undoStack.append(s)
                project = s.after
                revision += 1
            }
            records.append(HistoryRecord(revision: revision, op: e.op, commands: e.commands, at: e.at))
        }
        if !entries.isEmpty { try store.compact(project, revision: revision) }
    }
}
