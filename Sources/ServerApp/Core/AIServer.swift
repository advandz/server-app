// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import Network

/// Settings for the OpenAI-compatible server in front of Apple's on-device Foundation Model.
struct AIServerSettings: Codable, Hashable {
    var port = 8000
    var allowNetwork = false
    var apiKey = ""                         // empty = no key required
    var modelName = "apple-foundation-model"
    var webChat = true                      // serve the chat web app at /

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 8000
        allowNetwork = (try? c.decode(Bool.self, forKey: .allowNetwork)) ?? false
        apiKey = (try? c.decode(String.self, forKey: .apiKey)) ?? ""
        modelName = (try? c.decode(String.self, forKey: .modelName)) ?? "apple-foundation-model"
        webChat = (try? c.decode(Bool.self, forKey: .webChat)) ?? true
    }
}

enum AIServer {
    static let formula = "creevekcz/tap/afm-cli"
    static func afm(prefix: String) -> String { prefix + "/opt/afm-cli/bin/afm-cli" }
    static var pidFile: String { Paths.run + "/ai-server.pid" }
    static var logFile: String { Paths.logs + "/ai_requests.log" }
    static var startLog: String { Paths.logs + "/ai_start.log" }
    static var chatsDir: String { Paths.support + "/ai-chats" }

    /// Arguments for `Server --ai-server`. The API key travels in the environment, not argv.
    static func arguments(_ s: AIServerSettings, prefix: String) -> [String] {
        var args = ["--ai-server", "--host", s.allowNetwork ? "0.0.0.0" : "127.0.0.1", "--port", String(s.port),
                    "--model", s.modelName, "--afm", afm(prefix: prefix), "--pid-file", pidFile, "--log", logFile,
                    "--chats", chatsDir]
        if !s.webChat { args.append("--no-web") }
        return args
    }

    /// Where the web app is, for opening it from this Mac.
    static func webURL(_ s: AIServerSettings) -> URL? { URL(string: "http://127.0.0.1:\(s.port)/") }
}

// MARK: - Headless server (`Server --ai-server …`)

/// A small HTTP/1.1 server speaking the OpenAI API, answering with afm-cli (Apple Intelligence's
/// on-device model). Runs as its own process so it keeps serving after the app quits.
final class AIHTTPServer: @unchecked Sendable {
    let host: String
    let port: UInt16
    let model: String
    let afmPath: String
    let apiKey: String
    let logPath: String
    let webApp: Bool
    let store: ChatStore
    let networkAllowed: Bool
    let sessions = SessionStore()
    let limiter = LoginLimiter()
    let authGate = AsyncLimiter(limit: 1)          // password checks run one at a time
    let testAccounts = SystemAccounts.testAccounts()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ai-server", attributes: .concurrent)
    private let generation = AsyncLimiter(limit: 1)       // the on-device model answers one request at a time

    init(host: String, port: UInt16, model: String, afmPath: String, apiKey: String, logPath: String,
         webApp: Bool, chatsPath: String) {
        self.host = host; self.port = port; self.model = model; self.afmPath = afmPath; self.apiKey = apiKey; self.logPath = logPath
        self.webApp = webApp
        self.store = ChatStore(root: chatsPath)
        self.networkAllowed = host == "0.0.0.0"
    }

    static func main(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let server = AIHTTPServer(
            host: value("--host") ?? "127.0.0.1",
            port: UInt16(value("--port") ?? "8000") ?? 8000,
            model: value("--model") ?? "apple-foundation-model",
            afmPath: value("--afm") ?? "/opt/homebrew/bin/afm-cli",
            apiKey: ProcessInfo.processInfo.environment["SERVER_AI_API_KEY"] ?? "",
            logPath: value("--log") ?? "/dev/null",
            webApp: !args.contains("--no-web"),
            chatsPath: value("--chats") ?? NSHomeDirectory() + "/Library/Application Support/Server/ai-chats")
        let pidFile = value("--pid-file")
        signal(SIGTERM) { _ in exit(0) }
        do {
            try server.start()
            if let pidFile { try? String(getpid()).write(toFile: pidFile, atomically: true, encoding: .utf8) }
            print("AI server listening on \(server.host):\(server.port)")
        } catch {
            FileHandle.standardError.write(Data("Couldn't start: \(error)\n".utf8))
            exit(1)
        }
        dispatchMain()
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        if host != "0.0.0.0" {
            // Bind to one address: the port goes in the endpoint, not the listener.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { FileHandle.standardError.write(Data("Listener failed: \(e)\n".utf8)); exit(1) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: HTTP

    struct Request {
        var method = ""
        var path = ""
        var headers: [String: String] = [:]
        var body = Data()

        func cookie(_ name: String) -> String? {
            guard let header = headers["cookie"] else { return nil }
            for part in header.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, kv[0] == name { return kv[1] }
            }
            return nil
        }
    }

    private func accept(_ conn: NWConnection) {
        // "Allow other devices" off: this Mac only (the listener is already bound to 127.0.0.1;
        // this is a second line of defence).
        if !networkAllowed && !Self.isLoopback(conn) { conn.cancel(); return }
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    static func isLoopback(_ conn: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = conn.endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || (a.asIPv4?.isLoopback ?? false)
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    /// True when the request was forwarded by Cloudflare (it sets this header on all of them).
    static func viaTunnel(_ req: Request) -> Bool { req.headers["cf-connecting-ip"] != nil }

    /// The visitor's address: for tunnel traffic (which always arrives from this Mac) that's
    /// what Cloudflare reports, so logins can be limited per visitor.
    static func clientIP(_ conn: NWConnection, _ req: Request) -> String {
        if isLoopback(conn), let reported = req.headers["cf-connecting-ip"],
           reported.count <= 45, reported.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) { return reported }
        return clientIP(conn)
    }

    /// The client's address without any interface suffix.
    static func clientIP(_ conn: NWConnection) -> String {
        guard case let .hostPort(host, _) = conn.endpoint else { return "?" }
        let text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a): text = "\(a)"
        case .name(let n, _): text = n
        @unknown default: text = "?"
        }
        return text.components(separatedBy: "%")[0]
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                Task { await self.handle(request, conn) }
            } else if done || error != nil || buffer.count > 8 << 20 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    /// Returns a request once the headers and the whole body (Content-Length) have arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return Request(method: "BAD") }
        var req = Request(method: String(first[0]), path: String(first[1]).components(separatedBy: "?")[0])
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            req.headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(req.headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        req.body = data[bodyStart..<(bodyStart + length)]
        return req
    }

    /// Sends a JSON response. OpenAI routes carry CORS headers so browser apps can call them; the
    /// web app's routes (`cors: false`) carry none and are only reachable from their own origin.
    func send(_ conn: NWConnection, status: Int, json: Any, extraHeaders: [String: String] = [:], cors: Bool = true) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        sendRaw(conn, status: status, contentType: "application/json", body: body, extraHeaders: extraHeaders, cors: cors)
    }

    func sendRaw(_ conn: NWConnection, status: Int, contentType: String, body: Data,
                 extraHeaders: [String: String] = [:], cors: Bool = true) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += cors ? Self.cors : Self.webHeaders
        head += extraHeaders.map { "\($0.key): \($0.value)\r\n" }.joined() + "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    static let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\n"

    /// Headers for the web app: no CORS, scripts only from this server, nothing cached.
    static let webHeaders = "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nCache-Control: no-store\r\n"

    static func reason(_ s: Int) -> String {
        [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
         409: "Conflict", 429: "Too Many Requests", 500: "Internal Server Error"][s] ?? "OK"
    }

    private func error(_ conn: NWConnection, _ status: Int, _ message: String, type: String = "invalid_request_error") {
        send(conn, status: status, json: ["error": ["message": message, "type": type, "param": NSNull(), "code": NSNull()]])
    }

    // MARK: Routing

    private func handle(_ req: Request, _ conn: NWConnection) async {
        let started = Date()
        var status = 200
        // Only method, path and status are logged: never request bodies (they can hold passwords).
        defer { log("\(req.method) \(req.path) \(status) \(String(format: "%.2fs", Date().timeIntervalSince(started)))") }

        if req.path.hasPrefix("/v1") || req.path == "/health" {
            status = await handleOpenAI(req, conn)
        } else if webApp {
            status = await handleWeb(req, conn)
        } else if req.path == "/" {
            send(conn, status: 200, json: ["status": "ok", "model": model])
        } else {
            status = 404; error(conn, 404, "Unknown endpoint \(req.method) \(req.path).")
        }
    }

    /// The OpenAI-compatible API (and /health). The API key applies here only.
    private func handleOpenAI(_ req: Request, _ conn: NWConnection) async -> Int {
        if req.method == "OPTIONS" {
            let head = "HTTP/1.1 204 No Content\r\n" + Self.cors + "Content-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return 204
        }
        // Cloudflare adds this header to everything it forwards. Through the internet the API must
        // not be open: it would hand your Mac's on-device model to anyone with the link.
        if Self.viaTunnel(req), apiKey.isEmpty {
            error(conn, 403, "The API isn't available over the internet without an API key. Set one in AI Models › Settings.",
                  type: "invalid_api_key")
            return 403
        }
        if !apiKey.isEmpty, req.headers["authorization"] != "Bearer \(apiKey)" {
            error(conn, 401, "Incorrect API key provided.", type: "invalid_api_key"); return 401
        }
        let created = Int(Date().timeIntervalSince1970)
        switch (req.method, req.path) {
        case ("GET", "/health"):
            send(conn, status: 200, json: ["status": "ok", "model": model])
        case ("GET", "/v1/models"):
            send(conn, status: 200, json: ["object": "list", "data": [["id": model, "object": "model", "created": created, "owned_by": "apple"]]])
        case ("GET", let p) where p.hasPrefix("/v1/models/"):
            send(conn, status: 200, json: ["id": String(p.dropFirst("/v1/models/".count)), "object": "model", "created": created, "owned_by": "apple"])
        case ("POST", "/v1/chat/completions"):
            return await chat(req, conn)
        case ("POST", "/v1/completions"):
            return await completion(req, conn)
        default:
            error(conn, 404, "Unknown endpoint \(req.method) \(req.path)."); return 404
        }
        return 200
    }

    func body(_ req: Request) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
    }

    /// Message content can be a string or an array of parts ([{type: "text", text: …}]).
    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }

    private func chat(_ req: Request, _ conn: NWConnection) async -> Int {
        guard let json = body(req), let messages = json["messages"] as? [[String: Any]], !messages.isEmpty else {
            error(conn, 400, "'messages' is required."); return 400
        }
        var system: [String] = []
        var turns: [(role: String, content: String)] = []
        for m in messages {
            let role = m["role"] as? String ?? "user"
            let content = Self.text(m["content"])
            switch role {
            case "system", "developer": system.append(content)
            case "assistant": turns.append(("assistant", content))
            default: turns.append(("user", content))           // user, tool, function
            }
        }
        guard let last = turns.last, last.role == "user" else { error(conn, 400, "The last message must be from the user."); return 400 }
        let history = Array(turns.dropLast())
        let schema = Self.schema(json["response_format"], system: &system)
        let requestedModel = json["model"] as? String ?? model
        let stream = json["stream"] as? Bool ?? false
        let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
        let created = Int(Date().timeIntervalSince1970)

        if stream {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n" + Self.cors + "Connection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .idempotent)
            func chunk(_ delta: [String: Any], finish: String? = nil) {
                let obj: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": requestedModel,
                                          "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]]]
                let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
                conn.send(content: Data("data: ".utf8) + data + Data("\n\n".utf8), completion: .idempotent)
            }
            chunk(["role": "assistant", "content": ""])
            let result = await generate(system: system, history: history, prompt: last.content, schema: schema) { piece in
                chunk(["content": piece])
            }
            if case .failure(let e) = result {
                let obj: [String: Any] = ["error": ["message": e.message, "type": "server_error"]]
                let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                conn.send(content: Data("data: ".utf8) + data + Data("\n\n".utf8), completion: .idempotent)
            }
            chunk([:], finish: "stop")
            conn.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { _ in conn.cancel() })
            return 200
        }

        switch await generate(system: system, history: history, prompt: last.content, schema: schema, onPiece: nil) {
        case .success(let text):
            let promptTokens = Self.tokens(messages.map { Self.text($0["content"]) }.joined(separator: " "))
            let completionTokens = Self.tokens(text)
            send(conn, status: 200, json: [
                "id": id, "object": "chat.completion", "created": created, "model": requestedModel,
                "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
                "usage": ["prompt_tokens": promptTokens, "completion_tokens": completionTokens, "total_tokens": promptTokens + completionTokens],
            ])
            return 200
        case .failure(let e):
            error(conn, 500, e.message, type: "server_error"); return 500
        }
    }

    private func completion(_ req: Request, _ conn: NWConnection) async -> Int {
        guard let json = body(req) else { error(conn, 400, "Invalid JSON body."); return 400 }
        let prompt = (json["prompt"] as? String) ?? (json["prompt"] as? [String])?.joined(separator: "\n") ?? ""
        guard !prompt.isEmpty else { error(conn, 400, "'prompt' is required."); return 400 }
        switch await generate(system: [], history: [], prompt: prompt, schema: nil, onPiece: nil) {
        case .success(let text):
            let p = Self.tokens(prompt), c = Self.tokens(text)
            send(conn, status: 200, json: [
                "id": "cmpl-" + UUID().uuidString.prefix(8).lowercased(), "object": "text_completion",
                "created": Int(Date().timeIntervalSince1970), "model": json["model"] as? String ?? model,
                "choices": [["index": 0, "text": text, "finish_reason": "stop", "logprobs": NSNull()]],
                "usage": ["prompt_tokens": p, "completion_tokens": c, "total_tokens": p + c],
            ])
            return 200
        case .failure(let e):
            error(conn, 500, e.message, type: "server_error"); return 500
        }
    }

    /// response_format: json_schema → afm-cli --schema; json_object → an instruction.
    private static func schema(_ format: Any?, system: inout [String]) -> String? {
        guard let f = format as? [String: Any], let type = f["type"] as? String else { return nil }
        if type == "json_object" { system.append("Respond only with a valid JSON object."); return nil }
        if type == "json_schema", let js = f["json_schema"] as? [String: Any], let schema = js["schema"],
           let data = try? JSONSerialization.data(withJSONObject: schema) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// Rough token estimate (~4 characters per token); the model doesn't report counts.
    private static func tokens(_ s: String) -> Int { max(1, s.count / 4) }

    // MARK: afm-cli

    struct GenerationError: Error { let message: String }

    func generate(system: [String], history: [(role: String, content: String)], prompt: String, schema: String?,
                          onPiece: ((String) -> Void)?) async -> Result<String, GenerationError> {
        await generation.run {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-server-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            var args: [String] = []
            if !system.isEmpty { args += ["--system-prompt", system.joined(separator: "\n\n")] }
            if let schema { args += ["--schema", schema] }
            if !history.isEmpty {
                // afm-cli's conversation file: earlier turns, so the model sees the whole chat.
                let now = ISO8601DateFormatter().string(from: Date())
                let conv: [String: Any] = ["createdAt": now, "updatedAt": now,
                                           "messages": history.map { ["role": $0.role, "content": $0.content, "timestamp": now] }]
                let file = dir.appendingPathComponent("conversation.json")
                if let data = try? JSONSerialization.data(withJSONObject: conv) { try? data.write(to: file) }
                args += ["--conversation", file.path]
            }
            // The prompt goes through a file so any text (leading dashes, size) is passed safely.
            let promptFile = dir.appendingPathComponent("prompt.txt")
            try? prompt.write(to: promptFile, atomically: true, encoding: .utf8)
            args += ["--file", promptFile.path]

            let pieces = PieceCollector()
            let r = await Shell.run(self.afmPath, args) { line in
                pieces.append(line)
                onPiece?(pieces.count == 1 ? line : "\n" + line)
            }
            let output = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !r.ok || output.isEmpty {
                return .failure(GenerationError(message: output.isEmpty ? "The on-device model returned nothing (status \(r.status))." : output))
            }
            return .success(output)
        }
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let handle = FileHandle(forWritingAtPath: logPath) ?? {
            FileManager.default.createFile(atPath: logPath, contents: nil); return FileHandle(forWritingAtPath: logPath)
        }() else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(stamp) \(line)\n".utf8))
        try? handle.close()
    }
}

private final class PieceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func append(_ s: String) { lock.withLock { n += 1 } }
}

/// Runs at most `limit` operations at once; the rest wait their turn.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<T: Sendable>(_ op: @Sendable () async -> T) async -> T {
        if running >= limit { await withCheckedContinuation { waiting.append($0) } } else { running += 1 }
        defer {
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
        return await op()
    }
}
