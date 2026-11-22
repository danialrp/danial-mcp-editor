import Foundation

/// MCP over standard input and output: one JSON-RPC message per line. Used when
/// a client starts the editor as a child process. Logs go to standard error.
public enum StdioTransport {
    public static func run(_ handler: MCPHandler) async {
        let out = FileHandle.standardOutput
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                if var reply = await handler.handle(data) {
                    reply.append(0x0A)
                    out.write(reply)
                }
            }
        } catch {
            log("stdin closed: \(error)")
        }
    }
}

public func log(_ message: String) {
    FileHandle.standardError.write(Data("[dme] \(message)\n".utf8))
}
