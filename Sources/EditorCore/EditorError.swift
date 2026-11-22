/// An error a command or query reports to its caller. The message is meant to
/// be read by an agent and should say what to change.
public struct EditorError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case notFound = "not_found"
        case invalid = "invalid"
        case conflict = "conflict"
        case locked = "locked"
        case staleRevision = "stale_revision"
        case io = "io"
    }

    public var code: Code
    public var message: String
    public var parameter: String?

    public init(_ code: Code, _ message: String, parameter: String? = nil) {
        self.code = code
        self.message = message
        self.parameter = parameter
    }

    public var description: String { message }

    public static func notFound(_ what: String, _ id: EntityID) -> EditorError {
        EditorError(.notFound, "no \(what) with id \(id)")
    }

    public static func invalid(_ message: String, parameter: String? = nil) -> EditorError {
        EditorError(.invalid, message, parameter: parameter)
    }
}
