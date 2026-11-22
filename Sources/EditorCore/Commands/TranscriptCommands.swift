/// Stores a transcript in the project. Created by `transcript.create` and
/// `transcript.import`.
public struct AddTranscript: EditorCommand {
    public static let name = "transcript.add"
    public static let spec = CommandSpec("Store a transcript in the project.", exposedAsTool: false)

    public var transcript: Transcript

    public init(transcript: Transcript) { self.transcript = transcript }

    public func apply(to p: inout Project) throws {
        _ = try p.asset(transcript.asset)
        guard !p.transcripts.contains(where: { $0.id == transcript.id }) else {
            throw EditorError(.conflict, "transcript id \(transcript.id) already exists")
        }
        p.transcripts.append(transcript)
    }
}

public struct RemoveTranscripts: EditorCommand {
    public static let name = "transcript.remove"
    public static let spec = CommandSpec("Remove stored transcripts.", [
        Parameter("ids", .array(.id), "Transcript ids", required: true),
    ])

    public var ids: [EntityID]

    public init(ids: [EntityID]) { self.ids = ids }

    public func apply(to p: inout Project) throws {
        let set = Set(ids)
        for id in set where !p.transcripts.contains(where: { $0.id == id }) { throw EditorError.notFound("transcript", id) }
        p.transcripts.removeAll { set.contains($0.id) }
    }
}
