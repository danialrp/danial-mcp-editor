import Foundation

/// Every command the editor knows. Tools, the journal and the undo history all
/// look commands up here by name.
public enum CommandRegistry {
    public static let all: [any EditorCommand.Type] = [
        SetProjectSettings.self, SetAccent.self,
        AddMedia.self, SetMediaPath.self, SetMediaMatte.self, RemoveMedia.self,
        AddTrack.self, RemoveTrack.self, ReorderTrack.self, SetTrack.self,
        AddClip.self, MoveClip.self, TrimClip.self, SlipClip.self, RemoveClips.self,
        ReplaceClipMedia.self, DuplicateClips.self, CopyClipsTo.self, NudgeClips.self, DetachAudio.self, FreezeFrame.self,
        SetClipSpeed.self, SetClipAudio.self, SetClipTransform.self, SetJoinFades.self,
        SplitAt.self, DeleteToClipEdge.self, DeleteRange.self, CloseGaps.self,
        AddMarker.self, RemoveMarkers.self,
        AddTranscript.self, RemoveTranscripts.self,
        CreateLook.self, UpdateLook.self, PutLook.self, AssignLook.self, RemoveLook.self,
        PutEffect.self, RemoveEffect.self, ReorderEffect.self, SetKeyframes.self, RemoveKeyframes.self,
        AddPickedColor.self, UpdatePickedColor.self, RemovePickedColor.self,
    ]

    private static let byName: [String: any EditorCommand.Type] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func type(named name: String) -> (any EditorCommand.Type)? { byName[name] }

    /// Decodes a command from its JSON arguments.
    /// `stored` reads a command from the journal, with the wider time limit
    /// of saved files: what was applied once must always replay.
    public static func decode(name: String, arguments: Data, stored: Bool = false) throws -> any EditorCommand {
        guard let t = byName[name] else { throw EditorError(.notFound, "unknown command \(name)") }
        do {
            return try t.decodeJSON(arguments, stored: stored)
        } catch let e as DecodingError {
            throw EditorError.invalid("bad arguments for \(name): \(describe(e))")
        }
    }

    public static func encode(_ command: any EditorCommand) throws -> Data {
        try encoder.encode(command)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

extension EditorCommand {
    static func decodeJSON(_ data: Data, stored: Bool) throws -> any EditorCommand {
        let d = JSONDecoder()
        d.userInfo[Time.argumentsKey] = !stored
        return try d.decode(Self.self, from: data)
    }
}

/// A short, readable explanation of a decoding failure for an agent.
public func describe(_ e: DecodingError) -> String {
    func path(_ c: [CodingKey]) -> String {
        c.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
    switch e {
    case .keyNotFound(let k, let ctx): return "missing \(path(ctx.codingPath + [k]))"
    case .typeMismatch(_, let ctx): return "wrong type at \(path(ctx.codingPath)): \(ctx.debugDescription)"
    case .valueNotFound(_, let ctx): return "missing value at \(path(ctx.codingPath))"
    case .dataCorrupted(let ctx): return "\(path(ctx.codingPath)): \(ctx.debugDescription)"
    @unknown default: return "\(e)"
    }
}
