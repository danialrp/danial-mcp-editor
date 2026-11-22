import EditorCore
import EditorKit
import Foundation

/// The Model Context Protocol on top of the tool catalog: JSON-RPC 2.0 with
/// `initialize`, `ping`, `tools/list` and `tools/call`. Transports (HTTP and
/// stdio) pass raw messages in and send the replies back.
public struct MCPHandler: Sendable {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public let editor: Editor
    let tools: [String: Tool]
    let toolList: JSONValue

    /// `tools` defaults to the catalog; the app adds the tools that need the
    /// media engine (playback, frames).
    public init(editor: Editor, tools list: [Tool] = ToolCatalog.all) {
        self.editor = editor
        var map: [String: Tool] = [:]
        for t in list { map[Self.mcpName(t.name)] = t }
        tools = map
        toolList = .array(list.map(Self.describe))
    }

    /// Tool names use dots inside the editor (`timeline.split`). MCP clients
    /// accept only letters, digits, `_` and `-`, so dots become underscores.
    public static func mcpName(_ name: String) -> String { name.replacingOccurrences(of: ".", with: "_") }

    /// Handles one message or a batch. Returns nil when there is nothing to
    /// send back (only notifications).
    public func handle(_ data: Data) async -> Data? {
        guard let message = try? JSONValue.parse(data) else {
            return try? Self.error(id: .null, code: -32700, "parse error").data()
        }
        if case .array(let batch) = message {
            var replies: [JSONValue] = []
            for m in batch { if let r = await handle(message: m) { replies.append(r) } }
            return replies.isEmpty ? nil : try? JSONValue.array(replies).data()
        }
        return try? await handle(message: message)?.data()
    }

    func handle(message m: JSONValue) async -> JSONValue? {
        guard let method = m["method"]?.stringValue else {
            return Self.error(id: m["id"] ?? .null, code: -32600, "invalid request")
        }
        // A message without an id is a notification and gets no reply.
        guard let id = m["id"], id != .null else { return nil }
        let params = m["params"] ?? .object([:])
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[1]
            return Self.result(id: id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("danial-mcp-editor"), "version": .string(Editor.version)]),
                "instructions": .string(Self.instructions),
            ]))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, .object(["tools": toolList]))
        case "tools/call":
            guard let name = params["name"]?.stringValue, let tool = tools[name] else {
                return Self.error(id: id, code: -32602, "unknown tool \(params["name"]?.stringValue ?? "")")
            }
            return Self.result(id: id, await call(tool, params["arguments"]))
        default:
            return Self.error(id: id, code: -32601, "method not found: \(method)")
        }
    }

    func call(_ tool: Tool, _ arguments: JSONValue?) async -> JSONValue {
        do {
            var value = try await tool.call(editor, arguments: arguments)
            // A tool may return pictures under "images": each becomes an image
            // content block the model can see.
            var blocks: [JSONValue] = []
            if case .object(var o) = value, let images = o.removeValue(forKey: "images")?.arrayValue {
                for img in images {
                    if let data = img["data"], let mime = img["mimeType"] {
                        blocks.append(.object(["type": .string("image"), "data": data, "mimeType": mime]))
                    }
                }
                value = .object(o)
            }
            let text = (try? value.data()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            blocks.insert(.object(["type": .string("text"), "text": .string(text)]), at: 0)
            var r: [String: JSONValue] = ["content": .array(blocks)]
            if case .object = value { r["structuredContent"] = value }
            return .object(r)
        } catch let e as EditorError {
            var detail: [String: JSONValue] = ["code": .string(e.code.rawValue), "message": .string(e.message)]
            if let p = e.parameter { detail["parameter"] = .string(p) }
            return .object([
                "isError": .bool(true),
                "content": .array([.object(["type": .string("text"), "text": .string("\(e.code.rawValue): \(e.message)")])]),
                "structuredContent": .object(["error": .object(detail)]),
            ])
        } catch {
            return .object([
                "isError": .bool(true),
                "content": .array([.object(["type": .string("text"), "text": .string("error: \(error)")])]),
            ])
        }
    }

    static func describe(_ t: Tool) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for p in t.parameters {
            var s = schema(p.kind)
            if case .object(var o) = s {
                o["description"] = .string(p.kind.isSeconds ? "\(p.summary) (seconds)" : p.summary)
                s = .object(o)
            }
            props[p.name] = s
        }
        let required = t.parameters.filter(\.required).map { JSONValue.string($0.name) }
        var input: [String: JSONValue] = ["type": .string("object"), "properties": .object(props),
                                          "additionalProperties": .bool(false)]
        if !required.isEmpty { input["required"] = .array(required) }
        return .object([
            "name": .string(mcpName(t.name)),
            "title": .string(t.name),
            "description": .string(t.summary),
            "inputSchema": .object(input),
            "annotations": .object([
                "readOnlyHint": .bool(t.access == .read),
                "destructiveHint": .bool(false),
                "openWorldHint": .bool(false),
            ]),
        ])
    }

    static func schema(_ k: Parameter.Kind) -> JSONValue {
        switch k {
        case .string, .id: return .object(["type": .string("string")])
        case .number, .seconds: return .object(["type": .string("number")])
        case .integer: return .object(["type": .string("integer")])
        case .boolean: return .object(["type": .string("boolean")])
        case .oneOf(let v): return .object(["type": .string("string"), "enum": .array(v.map { .string($0) })])
        case .array(let inner): return .object(["type": .string("array"), "items": schema(inner)])
        case .object: return .object(["type": .string("object")])
        case .any: return .object([:])
        }
    }

    static func result(id: JSONValue, _ r: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": r])
    }

    static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    static let instructions = """
    Danial MCP Editor: a video editor driven entirely through these tools.
    Start with agent_onboard: one call gives the rules, the tool map, the open project in brief,
    its notes (spec and progress in full) and what changed since they were written.
    Keep your own spec and progress in the project with notes_write, so the next session starts from them.
    Times are timeline seconds snapped to the frame grid. Use batch_apply for many edits (one step, one undo).
    """
}

extension Parameter.Kind {
    var isSeconds: Bool { if case .seconds = self { true } else { false } }
}
