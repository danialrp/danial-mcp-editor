import Foundation
@preconcurrency import Network

/// MCP over HTTP on the loopback interface (the "streamable HTTP" transport,
/// answering every POST with a single JSON response).
///
/// - `POST /mcp` carries JSON-RPC. It needs `Authorization: Bearer <token>`.
/// - A request from a browser page (an `Origin` that is not local) is refused,
///   so a web page cannot drive the editor.
/// - `GET /mcp` answers 405: the server does not open event streams.
public final class HTTPTransport: @unchecked Sendable {
    let handler: MCPHandler
    let token: String
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dme.http")

    public init(handler: MCPHandler, port: Int, token: String) {
        self.handler = handler
        self.port = UInt16(port)
        self.token = token
    }

    /// Starts listening. Returns once the port is bound or binding failed.
    public func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { c.resume() }
                case .failed(let e): once.run { c.resume(throwing: e) }
                case .waiting(let e): once.run { c.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    public func stop() { listener?.cancel() }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        Connection(c, server: self).read()
    }

    /// Handles one HTTP request and returns status, headers and body.
    func respond(method: String, path: String, headers: [String: String], body: Data) async -> (Int, [String: String], Data) {
        let route = path.split(separator: "?").first.map(String.init) ?? path
        guard route == "/mcp" else { return (404, [:], Data("not found\n".utf8)) }
        if let origin = headers["origin"], !Self.isLocal(origin) {
            return (403, [:], Data("forbidden origin\n".utf8))
        }
        guard headers["authorization"] == "Bearer \(token)" else {
            return (401, ["WWW-Authenticate": "Bearer"], Data("missing or wrong bearer token\n".utf8))
        }
        switch method {
        case "POST":
            var extra: [String: String] = [:]
            if body.range(of: Data("\"initialize\"".utf8)) != nil {
                extra["Mcp-Session-Id"] = UUID().uuidString.lowercased()
            }
            guard let reply = await handler.handle(body) else { return (202, extra, Data()) }
            extra["Content-Type"] = "application/json"
            return (200, extra, reply)
        case "GET":
            return (405, ["Allow": "POST, DELETE"], Data())
        case "DELETE":
            return (200, [:], Data())
        default:
            return (405, ["Allow": "POST, DELETE"], Data())
        }
    }

    static func isLocal(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

/// Reads HTTP/1.1 requests from one connection, keeping it open between them.
private final class Connection: @unchecked Sendable {
    let c: NWConnection
    let server: HTTPTransport
    var buffer = Data()
    static let maxBody = 64 * 1024 * 1024

    init(_ c: NWConnection, server: HTTPTransport) {
        self.c = c
        self.server = server
    }

    func read() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            if error != nil { c.cancel(); return }
            if processBuffered() { return }
            if done { c.cancel(); return }
            read()
        }
    }

    /// Returns true when a request was taken from the buffer and is being answered.
    private func processBuffered() -> Bool {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { send(400, [:], Data(), keepAlive: false); return true }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= Self.maxBody else { send(413, [:], Data(), keepAlive: false); return true }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return false }
        let body = buffer[bodyStart..<(bodyStart + length)]
        buffer = Data(buffer[(bodyStart + length)...])
        let method = String(requestLine[0]), path = String(requestLine[1])
        let keepAlive = headers["connection"]?.lowercased() != "close"
        Task {
            let (status, h, data) = await server.respond(method: method, path: path, headers: headers, body: Data(body))
            send(status, h, data, keepAlive: keepAlive)
        }
        return true
    }

    private func send(_ status: Int, _ headers: [String: String], _ body: Data, keepAlive: Bool) {
        var h = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Length: \(body.count)\r\n"
        h += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        for (k, v) in headers { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var out = Data(h.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { [self] _ in
            if keepAlive {
                if !processBuffered() { read() }
            } else {
                c.cancel()
            }
        })
    }

    static func reason(_ s: Int) -> String {
        [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
         404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large"][s] ?? "Status"
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if !done { done = true; f() }
    }
}
