import EditorCore
import EditorKit
import Foundation
import Testing
@testable import MCPServer
import MediaEngine

/// Commands that are not tools themselves, and the tool that creates each.
let internalCommands = ["media.add": "media.import", "media.setPath": "media.relink", "transcript.add": "transcript.import", "look.put": "look.loadProfile", "effect.put": "effect.add"]

@Suite struct ParityTests {
    @MainActor @Test func everyCommandIsReachableThroughATool() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-p-\(UUID().uuidString)")
        let tools = Set(EditorRuntime(settings: try UserSettingsStore(directory: dir)).tools.map(\.name))
        for c in CommandRegistry.all {
            if c.spec.exposedAsTool {
                #expect(tools.contains(c.name), "command \(c.name) has no tool")
            } else {
                let maker = internalCommands[c.name]
                #expect(maker != nil && tools.contains(maker!), "internal command \(c.name) is not created by any tool")
            }
        }
    }

    @Test func toolNamesAreValidAndUniqueForMCPClients() {
        let names = ToolCatalog.all.map { MCPHandler.mcpName($0.name) }
        #expect(Set(names).count == names.count)
        for n in names {
            #expect(n.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil, "bad tool name \(n)")
        }
    }

    @Test func everyToolAndParameterIsDescribed() {
        for t in ToolCatalog.all {
            #expect(!t.summary.isEmpty, "\(t.name) has no summary")
            for p in t.parameters { #expect(!p.summary.isEmpty, "\(t.name).\(p.name) has no summary") }
            #expect(Set(t.parameters.map(\.name)).count == t.parameters.count, "\(t.name) repeats a parameter")
        }
    }

    @Test func everyCommandParameterDecodes() throws {
        // A command's declared parameters must be exactly the keys it decodes:
        // a key it ignores would be silently dropped.
        for c in CommandRegistry.all where c.spec.exposedAsTool {
            let declared = Set(c.spec.parameters.map(\.name))
            let mirror = Set(Mirror(reflecting: try sample(c)).children.compactMap(\.label)).subtracting(["idSeed"])
            #expect(mirror == declared, "\(c.name): fields \(mirror.sorted()) vs parameters \(declared.sorted())")
        }
    }

    func sample(_ t: any EditorCommand.Type) throws -> any EditorCommand {
        var args: [String: JSONValue] = [:]
        for p in t.spec.parameters where p.required {
            args[p.name] = switch p.kind {
            case .seconds, .number: .number(1)
            case .integer: .number(1)
            case .boolean: .bool(true)
            case .oneOf(let v): .string(v[0])
            case .array(.object): .array([])
            case .array: .array([.string("x")])
            default: .string("x")
            }
        }
        return try CommandRegistry.decode(name: t.name, arguments: JSONValue.object(args).data())
    }
}

@Suite struct HandlerTests {
    @Test func initializeListAndCall() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-h-\(UUID().uuidString)")
        let h = MCPHandler(editor: Editor(settings: try UserSettingsStore(directory: dir), prober: NoProber()))
        let initReply = try JSONValue.parse(await h.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8))!)
        #expect(initReply["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(await h.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        let call = try JSONValue.parse(await h.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"project_get"}}"#.utf8))!)
        #expect(call["result"]?["isError"]?.boolValue == true)
        let unknown = try JSONValue.parse(await h.handle(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}"#.utf8))!)
        #expect(unknown["error"]?["code"]?.intValue == -32602)
    }

    @Test func settingsNeverExposeTheToken() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-s-\(UUID().uuidString)")
        let store = try UserSettingsStore(directory: dir)
        let text = String(decoding: try store.publicJSON().data(), as: UTF8.self)
        #expect(!text.contains(store.current.mcp.token))
        #expect(throws: EditorError.self) { try store.set(key: "mcp.token", value: .string("x")) }
        try store.set(key: "cutRules.silence.minPause", value: .number(0.3))
        #expect(store.current.cutRules.silence.minPause == 0.3)
        #expect(throws: EditorError.self) { try store.set(key: "cutRules.nope", value: .number(1)) }
    }
}

struct NoProber: MediaProber {
    func probe(_ url: URL) async throws -> MediaInfo { throw EditorError(.invalid, "no media in tests") }
}

@Suite struct SettingsCompatibilityTests {
    @Test func olderSettingsFilesStillLoadAndHideTheEditsToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dme-c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = #"{"mcp":{"port":19700,"token":"abc"},"undoDepth":500,"recentProjects":[],"projectPresets":{},"cutRules":{"minPause":0.25,"talkingHeadSpeed":1.22}}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = try UserSettingsStore(directory: dir)
        #expect(store.current.cutRules.silence.minPause == 0.25)
        #expect(store.current.edits.url.hasPrefix("http://127.0.0.1"))
        try store.update { $0.edits.token = "secret-edits-token" }
        let text = String(decoding: try store.publicJSON().data(), as: UTF8.self)
        #expect(!text.contains("secret-edits-token"))
        #expect(throws: EditorError.self) { try store.set(key: "edits.token", value: .string("x")) }
    }
}
