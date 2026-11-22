import EditorCore
import Foundation

/// Long work (transcription, analysis, later export and rendering) runs as a
/// job: it gets an id at once, reports progress, can be waited on and
/// cancelled, and never blocks the command bus.
public actor JobCenter {
    public enum State: String, Codable, Sendable { case running, done, failed, cancelled }

    public struct Info: Codable, Sendable {
        public var id: String
        public var kind: String
        public var state: State
        public var progress: Double
        public var message: String
        public var started: Date
        public var finished: Date?
        public var result: JSONValue?
        public var error: String?
    }

    /// Handed to the work so it can report and notice cancellation.
    public struct Context: Sendable {
        public let id: String
        let center: JobCenter

        public func progress(_ fraction: Double, _ message: String = "") async {
            await center.update(id, progress: fraction, message: message)
        }

        public func checkCancelled() throws { try Task.checkCancellation() }
    }

    private var jobs: [String: Info] = [:]
    private var order: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Starts work and returns its id at once.
    public func start(_ kind: String, _ work: @escaping @Sendable (Context) async throws -> JSONValue) -> String {
        let id = "job_" + IDGenerator.newSeed()
        jobs[id] = Info(id: id, kind: kind, state: .running, progress: 0, message: "", started: Date())
        order.append(id)
        if order.count > 200 { let old = order.removeFirst(); jobs[old] = nil }
        let ctx = Context(id: id, center: self)
        tasks[id] = Task {
            do {
                let r = try await work(ctx)
                self.finish(id, state: .done, result: r, error: nil)
            } catch is CancellationError {
                self.finish(id, state: .cancelled, result: nil, error: "cancelled")
            } catch {
                self.finish(id, state: Task.isCancelled ? .cancelled : .failed, result: nil, error: "\(error)")
            }
        }
        return id
    }

    public func info(_ id: String) throws -> Info {
        guard let j = jobs[id] else { throw EditorError(.notFound, "no job \(id)") }
        return j
    }

    public func list() -> [Info] { order.compactMap { jobs[$0] } }

    public func cancel(_ id: String) throws {
        _ = try info(id)
        tasks[id]?.cancel()
    }

    /// Waits until the job ends or the timeout passes, then returns its info.
    public func wait(_ id: String, timeout: Double) async throws -> Info {
        let j = try info(id)
        if j.state != .running { return j }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForEnd(id) }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)) }
            await group.next()
            group.cancelAll()
        }
        return try info(id)
    }

    private func waitForEnd(_ id: String) async {
        if jobs[id]?.state != .running { return }
        await withCheckedContinuation { c in waiters[id, default: []].append(c) }
    }

    fileprivate func update(_ id: String, progress: Double, message: String) {
        guard jobs[id]?.state == .running else { return }
        jobs[id]?.progress = min(1, max(0, progress))
        if !message.isEmpty { jobs[id]?.message = message }
    }

    private func finish(_ id: String, state: State, result: JSONValue?, error: String?) {
        jobs[id]?.state = state
        jobs[id]?.finished = Date()
        jobs[id]?.result = result
        jobs[id]?.error = error
        if state == .done { jobs[id]?.progress = 1 }
        tasks[id] = nil
        for w in waiters.removeValue(forKey: id) ?? [] { w.resume() }
    }

    /// The job tools; they hold the center and call into it.
    public nonisolated func toolsSync() -> [Tool] {
        [
            Tool("job.list", .read, "Running and recent jobs (transcription, analysis, export).") { [self] _, _ in
                .object(["jobs": try JSONValue(encoding: await self.list())])
            },
            Tool("job.get", .read, "One job: state, progress, message, and its result when done.", [
                Parameter("id", .string, "Job id", required: true),
            ]) { [self] _, args in
                try JSONValue(encoding: try await self.info(try args.requiredString("id")))
            },
            Tool("job.wait", .read, "Wait until a job ends, or until the timeout, and return it.", [
                Parameter("id", .string, "Job id", required: true),
                Parameter("timeout", .number, "Seconds to wait at most; default 60, at most 600"),
            ]) { [self] _, args in
                let t = min(600, max(0, try args.double("timeout") ?? 60))
                return try JSONValue(encoding: try await self.wait(try args.requiredString("id"), timeout: t))
            },
            Tool("job.cancel", .manage, "Stop a job. Finished parts are kept.", [
                Parameter("id", .string, "Job id", required: true),
            ]) { [self] _, args in
                try await self.cancel(try args.requiredString("id"))
                return .object(["cancelled": .bool(true)])
            },
        ]
    }
}
