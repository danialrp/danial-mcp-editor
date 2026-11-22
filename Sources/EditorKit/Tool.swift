import EditorCore
import Foundation

/// One capability as the outside world sees it: an MCP tool today, a menu item
/// or key binding later. Every tool is listed in `ToolCatalog`.
public struct Tool: Sendable {
    public enum Access: String, Sendable {
        /// Reads only.
        case read
        /// Changes the project and is undoable.
        case write
        /// Opens, creates, closes or moves projects, or changes settings.
        case manage
    }

    public var name: String
    public var summary: String
    public var parameters: [Parameter]
    public var access: Access
    public var run: @Sendable (Editor, Args) async throws -> JSONValue

    public init(_ name: String, _ access: Access, _ summary: String, _ parameters: [Parameter] = [],
                run: @escaping @Sendable (Editor, Args) async throws -> JSONValue) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.access = access
        self.run = run
    }

    /// Runs the tool after checking that every argument is a known parameter.
    public func call(_ editor: Editor, arguments: JSONValue?) async throws -> JSONValue {
        let object: [String: JSONValue]
        switch arguments {
        case nil, .null?: object = [:]
        case .object(let o)?: object = o
        default: throw EditorError.invalid("arguments must be an object")
        }
        let known = Set(parameters.map(\.name))
        if let unknown = object.keys.sorted().first(where: { !known.contains($0) }) {
            throw EditorError.invalid("\(name) has no parameter \"\(unknown)\"; parameters are: \(parameters.map(\.name).joined(separator: ", "))", parameter: unknown)
        }
        for p in parameters where p.required && (object[p.name] == nil || object[p.name] == .null) {
            throw EditorError.invalid("\(name) needs \(p.name)", parameter: p.name)
        }
        return try await run(editor, Args(object))
    }
}

/// Typed access to tool arguments, with errors an agent can act on.
public struct Args: Sendable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue]) { self.values = values }

    public func has(_ k: String) -> Bool { values[k] != nil && values[k] != .null }

    public func string(_ k: String) throws -> String? {
        guard has(k) else { return nil }
        guard let s = values[k]?.stringValue else { throw EditorError.invalid("\(k) must be a string", parameter: k) }
        return s
    }

    public func requiredString(_ k: String) throws -> String {
        guard let s = try string(k) else { throw EditorError.invalid("\(k) is required", parameter: k) }
        return s
    }

    public func int(_ k: String) throws -> Int? {
        guard has(k) else { return nil }
        guard let i = values[k]?.intValue else { throw EditorError.invalid("\(k) must be a whole number", parameter: k) }
        return i
    }

    public func double(_ k: String) throws -> Double? {
        guard has(k) else { return nil }
        guard let d = values[k]?.doubleValue, d.isFinite else { throw EditorError.invalid("\(k) must be a number", parameter: k) }
        return d
    }

    public func bool(_ k: String) throws -> Bool? {
        guard has(k) else { return nil }
        guard let b = values[k]?.boolValue else { throw EditorError.invalid("\(k) must be true or false", parameter: k) }
        return b
    }

    public func strings(_ k: String) throws -> [String]? {
        guard has(k) else { return nil }
        guard let a = values[k]?.arrayValue else { throw EditorError.invalid("\(k) must be a list", parameter: k) }
        return try a.map {
            guard let s = $0.stringValue else { throw EditorError.invalid("\(k) must be a list of strings", parameter: k) }
            return s
        }
    }

    public func time(_ k: String) throws -> Time? { try double(k).map(Time.init(seconds:)) }

    /// The arguments without the given keys, as a JSON object.
    public func json(removing keys: Set<String> = []) -> JSONValue {
        .object(values.filter { !keys.contains($0.key) })
    }
}
