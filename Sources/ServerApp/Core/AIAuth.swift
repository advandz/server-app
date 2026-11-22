// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import OpenDirectory
import Security

/// A person signed in to the AI web app.
struct AIUser: Sendable, Equatable {
    let name: String          // canonical short name, lower case; keys their chats
    let fullName: String
}

/// Checks Mac account passwords with Open Directory, the same service the login window uses.
enum SystemAccounts {
    /// Short names are used in file paths, so only plain characters are accepted.
    static func isValidShortName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    /// Returns the account when the password is right and it's a real login account
    /// (uid 501 and up, with a login shell); nil otherwise.
    static func verify(user: String, password: String) -> AIUser? {
        guard isValidShortName(user), !password.isEmpty, password.utf8.count <= 1024 else { return nil }
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let attributes: NSArray = [kODAttributeTypeUniqueID, kODAttributeTypeUserShell, kODAttributeTypeFullName]
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: attributes)
            try record.verifyPassword(password)
            func values(_ key: String) -> [String] { ((try? record.values(forAttribute: key)) as? [String]) ?? [] }
            let uid = Int(values(kODAttributeTypeUniqueID).first ?? "") ?? 0
            let shell = values(kODAttributeTypeUserShell).first ?? ""
            guard uid >= 501, !shell.isEmpty, shell != "/usr/bin/false", !shell.hasSuffix("/nologin") else { return nil }
            let name = record.recordName.lowercased()
            guard isValidShortName(name) else { return nil }
            return AIUser(name: name, fullName: values(kODAttributeTypeFullName).first ?? record.recordName)
        } catch let error as NSError {
            // A wrong password is the normal failure (5000). Anything else means sign-in itself is
            // broken, so say so in the server's output (error code only, never the password).
            if !(error.domain == "com.apple.OpenDirectory" && error.code == Int(kODErrorCredentialsInvalid.rawValue)) {
                FileHandle.standardError.write(Data("Open Directory error while signing in: \(error.domain) \(error.code)\n".utf8))
            }
            return nil
        }
    }

    /// Extra accounts for automated tests (`SERVER_AI_TEST_USERS=alice:pw,bob:pw`). They're added
    /// on top of real sign-in and only honoured when SERVER_APP_SUPPORT is set, which the app
    /// itself never does.
    static func testAccounts() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        guard env["SERVER_APP_SUPPORT"] != nil, let list = env["SERVER_AI_TEST_USERS"] else { return [:] }
        var out: [String: String] = [:]
        for entry in list.split(separator: ",") {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, isValidShortName(parts[0]) { out[parts[0].lowercased()] = parts[1] }
        }
        return out
    }
}

/// Signed-in browser sessions, kept in memory (a restart signs everyone out).
final class SessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: (user: AIUser, expires: Date)] = [:]
    private let lifetime: TimeInterval = 7 * 24 * 3600

    func create(for user: AIUser) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            let now = Date()
            sessions = sessions.filter { $0.value.expires > now }
            sessions[token] = (user, now.addingTimeInterval(lifetime))
        }
        return token
    }

    /// The signed-in user for a token; each use extends the session.
    func user(for token: String?) -> AIUser? {
        guard let token else { return nil }
        return lock.withLock {
            guard let s = sessions[token], s.expires > Date() else { sessions[token] = nil; return nil }
            sessions[token] = (s.user, Date().addingTimeInterval(lifetime))
            return s.user
        }
    }

    func remove(_ token: String?) {
        guard let token else { return }
        lock.withLock { sessions[token] = nil }
    }

    static let cookieName = "server_ai_session"
    var maxAge: Int { Int(lifetime) }
}

/// Slows down password guessing: 5 failures per address and user, or 20 per address, within 10
/// minutes block further attempts from that address for a while.
final class LoginLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: [Date]] = [:]
    private let window: TimeInterval = 600

    private func recent(_ key: String) -> [Date] {
        let cutoff = Date().addingTimeInterval(-window)
        let list = (failures[key] ?? []).filter { $0 > cutoff }
        failures[key] = list.isEmpty ? nil : list
        return list
    }

    /// Seconds to wait before trying again, or nil when allowed. Requests that come through a
    /// tunnel (the internet) also share one overall budget, so guessing from many addresses
    /// at once can't get further than guessing from one.
    func retryAfter(ip: String, user: String, viaTunnel: Bool = false) -> Int? {
        lock.withLock {
            let perUser = recent("\(ip)|\(user.lowercased())"), perIP = recent(ip)
            let overall = viaTunnel ? recent("tunnel") : []
            let blocking = perUser.count >= 5 ? perUser : perIP.count >= 20 ? perIP : overall.count >= 30 ? overall : []
            guard let oldest = blocking.first else { return nil }
            return max(1, Int(oldest.addingTimeInterval(window).timeIntervalSinceNow))
        }
    }

    func recordFailure(ip: String, user: String, viaTunnel: Bool = false) {
        lock.withLock {
            failures["\(ip)|\(user.lowercased())", default: []].append(Date())
            failures[ip, default: []].append(Date())
            if viaTunnel { failures["tunnel", default: []].append(Date()) }
        }
    }

    func recordSuccess(ip: String, user: String) {
        lock.withLock { failures["\(ip)|\(user.lowercased())"] = nil }
    }
}
