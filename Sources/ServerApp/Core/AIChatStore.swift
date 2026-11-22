// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

struct ChatMessage: Codable, Equatable {
    var role: String                 // "user" or "assistant"
    var content: String
    var time: Date

    var json: [String: Any] {
        ["role": role, "content": content, "time": ISO8601DateFormatter().string(from: time)]
    }
}

struct Chat: Codable {
    var id: String
    var title: String
    var created: Date
    var updated: Date
    var messages: [ChatMessage]

    var summary: [String: Any] {
        let f = ISO8601DateFormatter()
        return ["id": id, "title": title, "updated": f.string(from: updated), "created": f.string(from: created)]
    }
    var json: [String: Any] {
        var s = summary
        s["messages"] = messages.map(\.json)
        return s
    }
}

/// Chats saved as one JSON file each, in a folder per user:
///   <root>/<user>/<chat id>.json
/// Users are kept apart by the server (a chat is only ever loaded for the signed-in user); the
/// files themselves are readable by the Mac account that runs Server.
final class ChatStore: @unchecked Sendable {
    let root: String
    static let maxChatsPerUser = 500
    static let maxMessageLength = 20_000
    private let lock = NSLock()
    private var busy: Set<String> = []
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(root: String) { self.root = root }

    private func directory(_ user: AIUser) -> String? {
        SystemAccounts.isValidShortName(user.name) ? root + "/" + user.name : nil
    }

    /// Chat ids are UUIDs; anything else is refused before it can reach a file path.
    static func validID(_ id: String) -> String? { UUID(uuidString: id)?.uuidString.lowercased() }

    private func path(_ user: AIUser, _ id: String) -> String? {
        guard let dir = directory(user), let id = Self.validID(id) else { return nil }
        return "\(dir)/\(id).json"
    }

    private func ensureDirectory(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func list(_ user: AIUser) -> [Chat] {
        guard let dir = directory(user) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir + "/" + name) else { return nil }
            return try? decoder.decode(Chat.self, from: data)
        }
        .sorted { $0.updated > $1.updated }
    }

    func load(_ user: AIUser, _ id: String) -> Chat? {
        guard let p = path(user, id), let data = FileManager.default.contents(atPath: p) else { return nil }
        return try? decoder.decode(Chat.self, from: data)
    }

    @discardableResult
    func save(_ user: AIUser, _ chat: Chat) -> Bool {
        guard let dir = directory(user), let p = path(user, chat.id), let data = try? encoder.encode(chat) else { return false }
        ensureDirectory(dir)
        guard FileManager.default.createFile(atPath: p, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        return true
    }

    func create(_ user: AIUser) -> Chat? {
        guard list(user).count < Self.maxChatsPerUser else { return nil }
        let now = Date()
        let chat = Chat(id: UUID().uuidString.lowercased(), title: "New chat", created: now, updated: now, messages: [])
        return save(user, chat) ? chat : nil
    }

    func delete(_ user: AIUser, _ id: String) -> Bool {
        guard let p = path(user, id), FileManager.default.fileExists(atPath: p) else { return false }
        return (try? FileManager.default.removeItem(atPath: p)) != nil
    }

    /// Marks a chat as generating so two sends can't interleave. False if it already is.
    func begin(_ user: AIUser, _ id: String) -> Bool {
        lock.withLock { busy.insert("\(user.name)/\(id)").inserted }
    }

    func end(_ user: AIUser, _ id: String) {
        lock.withLock { _ = busy.remove("\(user.name)/\(id)") }
    }

    /// A short title from the first message.
    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let clean = line.trimmingCharacters(in: .whitespaces)
        guard clean.count > 42 else { return clean.isEmpty ? "New chat" : clean }
        let cut = clean.prefix(42)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 20 { return String(cut[..<space]) + "…" }
        return String(cut) + "…"
    }
}
