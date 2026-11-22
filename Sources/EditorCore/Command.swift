/// A change to a project.
///
/// A command's stored properties are exactly its tool arguments, so the same
/// JSON is what an agent sends, what the journal stores and what the undo
/// history lists. `prepare` runs once, before the command is applied for the
/// first time: it snaps times to the frame grid and assigns the identifiers of
/// anything the command creates. The journal stores the prepared command, so
/// replaying it gives the same result.
public protocol EditorCommand: Codable, Sendable {
    static var name: String { get }
    static var spec: CommandSpec { get }

    mutating func prepare(in project: Project) throws
    func apply(to project: inout Project) throws
}

extension EditorCommand {
    public mutating func prepare(in project: Project) throws {}
    public var name: String { Self.name }
}

/// What a command or query looks like from the outside: the description and
/// parameters that become an MCP tool and, later, a menu item or key binding.
public struct CommandSpec: Sendable {
    public var summary: String
    public var parameters: [Parameter]
    /// False for commands that only other tools create (for example
    /// `media.add`, which `media.import` makes after reading the files).
    public var exposedAsTool: Bool

    public init(_ summary: String, _ parameters: [Parameter] = [], exposedAsTool: Bool = true) {
        self.summary = summary
        self.parameters = parameters
        self.exposedAsTool = exposedAsTool
    }
}

public struct Parameter: Sendable {
    public indirect enum Kind: Sendable {
        case string, number, integer, boolean
        case seconds
        case id
        case oneOf([String])
        case array(Kind)
        case object
        case any
    }

    public var name: String
    public var kind: Kind
    public var summary: String
    public var required: Bool

    public init(_ name: String, _ kind: Kind, _ summary: String, required: Bool = false) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.required = required
    }
}

extension Project {
    /// Snaps a timeline time to this project's frame grid and checks it.
    public func snap(_ t: Time, _ parameter: String) throws -> Time {
        guard t.ticks >= 0 else { throw EditorError.invalid("\(parameter) must not be negative", parameter: parameter) }
        return t.snapped(to: settings.frameRate)
    }
}
