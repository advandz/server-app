// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import Network

/// The chat web app served by the AI server: static files, Mac-account sign-in, and a small JSON
/// API for per-user chats. None of these routes send CORS headers.
extension AIHTTPServer {
    static let systemPrompt = "You are a helpful assistant. Answer clearly and concisely, and use Markdown for code and lists."
    /// The on-device model has a small context window; older turns are dropped past this many characters.
    static let historyBudget = 9000

    func apiError(_ conn: NWConnection, _ status: Int, _ message: String, extraHeaders: [String: String] = [:]) {
        send(conn, status: status, json: ["error": message], extraHeaders: extraHeaders, cors: false)
    }

    func handleWeb(_ req: Request, _ conn: NWConnection) async -> Int {
        let path = req.path
        // Static files
        if req.method == "GET" {
            switch path {
            case "/", "/index.html":
                sendRaw(conn, status: 200, contentType: "text/html; charset=utf-8", body: Data(AIWebApp.html.utf8), cors: false); return 200
            case "/app.css":
                sendRaw(conn, status: 200, contentType: "text/css; charset=utf-8", body: Data(AIWebApp.css.utf8), cors: false); return 200
            case "/app.js":
                sendRaw(conn, status: 200, contentType: "text/javascript; charset=utf-8", body: Data(AIWebApp.js.utf8), cors: false); return 200
            case "/favicon.svg", "/favicon.ico":
                sendRaw(conn, status: 200, contentType: "image/svg+xml", body: Data(AIWebApp.icon.utf8), cors: false); return 200
            default: break
            }
        }
        guard path.hasPrefix("/api/") else { apiError(conn, 404, "Not found."); return 404 }

        // Browsers send Origin on cross-site requests: refuse state changes that didn't come from this page.
        if req.method != "GET", !originMatchesHost(req) { apiError(conn, 403, "Cross-origin request refused."); return 403 }

        let token = req.cookie(SessionStore.cookieName)
        if path == "/api/login", req.method == "POST" { return await login(req, conn) }
        if path == "/api/logout", req.method == "POST" {
            sessions.remove(token)
            send(conn, status: 200, json: ["ok": true], extraHeaders: ["Set-Cookie": Self.cookie("", maxAge: 0, secure: Self.isHTTPS(req))], cors: false)
            return 200
        }
        guard let user = sessions.user(for: token) else { apiError(conn, 401, "Sign in to continue."); return 401 }

        let parts = path.split(separator: "/").map(String.init)      // ["api", "chats", id?, "messages"?]
        switch (req.method, parts.count, parts.count > 1 ? parts[1] : "") {
        case ("GET", 2, "me"):
            send(conn, status: 200, json: ["user": user.name, "name": user.fullName, "model": model], cors: false)
        case ("GET", 2, "chats"):
            send(conn, status: 200, json: ["chats": store.list(user).map(\.summary)], cors: false)
        case ("POST", 2, "chats"):
            guard let chat = store.create(user) else { apiError(conn, 400, "You have too many chats. Delete some first."); return 400 }
            send(conn, status: 200, json: chat.json, cors: false)
        case (_, 3, "chats"):
            return chatRoute(req, conn, user, id: parts[2])
        case ("POST", 4, "chats") where parts[3] == "messages":
            return await sendMessage(req, conn, user, id: parts[2])
        default:
            apiError(conn, 404, "Not found."); return 404
        }
        return 200
    }

    // MARK: Sign in

    /// The session cookie. Through a tunnel the page is served over HTTPS, so it's also marked Secure.
    private static func cookie(_ value: String, maxAge: Int, secure: Bool = false) -> String {
        "\(SessionStore.cookieName)=\(value); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(maxAge)" + (secure ? "; Secure" : "")
    }

    private static func isHTTPS(_ req: Request) -> Bool {
        req.secure || req.headers["x-forwarded-proto"]?.lowercased() == "https" || (req.headers["cf-visitor"] ?? "").contains("https")
    }

    private func login(_ req: Request, _ conn: NWConnection) async -> Int {
        guard let json = body(req), let name = json["username"] as? String, let password = json["password"] as? String,
              !name.isEmpty, !password.isEmpty else { apiError(conn, 400, "Enter your user name and password."); return 400 }
        let tunnel = Self.viaTunnel(req)
        let ip = Self.clientIP(conn, req)
        func tooMany(_ wait: Int) -> Int {
            apiError(conn, 429, "Too many attempts. Try again in \(max(1, wait / 60)) minute(s).", extraHeaders: ["Retry-After": String(wait)])
            return 429
        }
        if let wait = limiter.retryAfter(ip: ip, user: name, viaTunnel: tunnel) { return tooMany(wait) }
        // Password checks are queued one at a time, and the limit is checked again when it's this
        // attempt's turn, so many parallel guesses can't all slip past it. A failed check holds the
        // queue for a second, which caps guessing at about one try per second.
        enum Outcome: Sendable { case ok(AIUser), blocked(Int), wrong }
        let outcome = await authGate.run { () -> Outcome in
            if let wait = self.limiter.retryAfter(ip: ip, user: name, viaTunnel: tunnel) { return .blocked(wait) }
            if let user = await self.authenticate(name, password) { return .ok(user) }
            self.limiter.recordFailure(ip: ip, user: name, viaTunnel: tunnel)
            try? await Task.sleep(for: .seconds(1))
            return .wrong
        }
        let user: AIUser
        switch outcome {
        case .blocked(let wait): return tooMany(wait)
        case .wrong: apiError(conn, 401, "Incorrect user name or password."); return 401
        case .ok(let u): user = u
        }
        limiter.recordSuccess(ip: ip, user: name)
        let token = sessions.create(for: user)
        send(conn, status: 200, json: ["user": user.name, "name": user.fullName, "model": model],
             extraHeaders: ["Set-Cookie": Self.cookie(token, maxAge: sessions.maxAge, secure: Self.isHTTPS(req))], cors: false)
        return 200
    }

    /// Mac account passwords are checked with Open Directory (off the main queue: it blocks).
    private func authenticate(_ name: String, _ password: String) async -> AIUser? {
        if let expected = testAccounts[name.lowercased()] {
            return expected == password ? AIUser(name: name.lowercased(), fullName: name.capitalized) : nil
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: SystemAccounts.verify(user: name, password: password)) }
        }
    }

    private func originMatchesHost(_ req: Request) -> Bool {
        guard let origin = req.headers["origin"] else { return true }          // not a browser cross-site request
        guard let url = URL(string: origin), let host = url.host, let hostHeader = req.headers["host"]?.lowercased() else { return false }
        var authority = host.lowercased()
        if host.contains(":") { authority = "[\(authority)]" }
        if let port = url.port { authority += ":\(port)" }
        func normalised(_ s: String) -> String { s.hasSuffix(":80") ? String(s.dropLast(3)) : s }
        return normalised(authority) == normalised(hostHeader)
    }

    // MARK: Chats

    private func chatRoute(_ req: Request, _ conn: NWConnection, _ user: AIUser, id: String) -> Int {
        guard var chat = store.load(user, id) else { apiError(conn, 404, "Chat not found."); return 404 }
        switch req.method {
        case "GET":
            send(conn, status: 200, json: chat.json, cors: false)
        case "PATCH":
            guard let title = body(req)?["title"] as? String else { apiError(conn, 400, "A title is required."); return 400 }
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { apiError(conn, 400, "A title is required."); return 400 }
            chat.title = String(clean.prefix(80))
            store.save(user, chat)
            send(conn, status: 200, json: chat.summary, cors: false)
        case "DELETE":
            send(conn, status: store.delete(user, id) ? 200 : 500, json: ["ok": true], cors: false)
        default:
            apiError(conn, 405, "Method not allowed."); return 405
        }
        return 200
    }

    private func sendMessage(_ req: Request, _ conn: NWConnection, _ user: AIUser, id: String) async -> Int {
        guard let text = (body(req)?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            apiError(conn, 400, "Write a message first."); return 400
        }
        guard text.count <= ChatStore.maxMessageLength else { apiError(conn, 400, "That message is too long."); return 400 }
        guard var chat = store.load(user, id) else { apiError(conn, 404, "Chat not found."); return 404 }
        guard store.begin(user, id) else { apiError(conn, 409, "This chat is still answering."); return 409 }
        defer { store.end(user, id) }

        let history = Self.trimmed(chat.messages)
        let now = Date()
        let firstMessage = chat.messages.isEmpty
        chat.messages.append(ChatMessage(role: "user", content: text, time: now))
        if firstMessage { chat.title = ChatStore.title(from: text) }
        chat.updated = now
        store.save(user, chat)

        switch await generate(system: [Self.systemPrompt], history: history, prompt: text, schema: nil, onPiece: nil) {
        case .success(let answer):
            let reply = ChatMessage(role: "assistant", content: answer, time: Date())
            // Reload: the chat may have been renamed while the model was answering.
            var latest = store.load(user, id) ?? chat
            latest.messages.append(reply)
            latest.updated = reply.time
            store.save(user, latest)
            send(conn, status: 200, json: ["message": reply.json, "chat": latest.summary], cors: false)
            return 200
        case .failure(let failure):
            // Take the question back out so the saved chat stays consistent; the page restores it.
            var latest = store.load(user, id) ?? chat
            if latest.messages.last?.role == "user" { latest.messages.removeLast() }
            if latest.messages.isEmpty { latest.title = "New chat" }
            store.save(user, latest)
            let lower = failure.message.lowercased()
            let tooLong = lower.contains("context") || lower.contains("exceed") || lower.contains("too long")
            apiError(conn, 500, tooLong
                     ? "This chat has grown too long for the on-device model. Start a new chat to continue."
                     : "The model couldn't answer: \(failure.message)")
            return 500
        }
    }

    /// Recent turns that fit the budget, starting with a question.
    static func trimmed(_ messages: [ChatMessage]) -> [(role: String, content: String)] {
        var kept: [(role: String, content: String)] = []
        var total = 0
        for m in messages.reversed() {
            total += m.content.count
            if total > historyBudget && !kept.isEmpty { break }
            kept.insert((m.role, m.content), at: 0)
        }
        while kept.first?.role == "assistant" { kept.removeFirst() }
        return kept
    }
}
