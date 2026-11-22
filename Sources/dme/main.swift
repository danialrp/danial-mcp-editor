import EditorKit
import Foundation
import MCPServer
import MediaEngine

// Danial MCP Editor without a window: the MCP server.
//
//   dme serve [--port N]   MCP over HTTP on 127.0.0.1 (token in the settings file)
//   dme stdio              MCP over standard input and output
//   dme info               where settings live and how to connect a client

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let settings: UserSettingsStore
do {
    settings = try UserSettingsStore()
} catch {
    log("cannot read settings: \(error)")
    exit(1)
}
let runtime = await MainActor.run { EditorRuntime(settings: settings) }
let editor = runtime.editor
let handler = MCPHandler(editor: editor, tools: await MainActor.run { runtime.tools })

/// Saves and closes the open project on Ctrl-C or a normal kill. A hard kill
/// skips this, and the journal recovers everything on the next open.
func closeOnSignals() {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            Task {
                try? await editor.closeProject()
                exit(0)
            }
        }
        src.resume()
        signalSources.append(src)
    }
}
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

switch command {
case "serve":
    let port = option("port").flatMap(Int.init) ?? settings.current.mcp.port
    let server = HTTPTransport(handler: handler, port: port, token: settings.current.mcp.token)
    do {
        try await server.start()
    } catch {
        log("cannot listen on 127.0.0.1:\(port): \(error)")
        exit(1)
    }
    closeOnSignals()
    log("MCP over HTTP at http://127.0.0.1:\(port)/mcp (token in \(settings.fileURL.path))")
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }

case "stdio":
    closeOnSignals()
    await StdioTransport.run(handler)
    try? await editor.closeProject()

case "info":
    let s = settings.current
    print("""
    Danial MCP Editor \(Editor.version)
    settings: \(settings.fileURL.path)
    HTTP:     http://127.0.0.1:\(s.mcp.port)/mcp   (start with: dme serve)
    tools:    \(await MainActor.run { runtime.tools.count })

    Connect Claude Code over stdio:
      claude mcp add dme -- \(CommandLine.arguments[0]) stdio
    or over HTTP (the token is "mcp.token" in the settings file):
      claude mcp add --transport http dme http://127.0.0.1:\(s.mcp.port)/mcp --header "Authorization: Bearer <token>"
    """)

default:
    print("usage: dme serve [--port N] | dme stdio | dme info")
    exit(command == "help" ? 0 : 2)
}
