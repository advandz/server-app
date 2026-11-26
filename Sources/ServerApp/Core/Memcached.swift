// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// Object cache settings (Homebrew memcached).
struct MemcachedSettings: Codable, Hashable {
    var port = 11211
    var allowNetwork = false              // listen on all addresses (memcached has no password)
    var memoryMB = 128
    var maxConnections = 1024
    var threads = 4
    var logLevel = 1                      // 0 = none, 1 = errors and warnings, 2 = every command

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 11211
        allowNetwork = (try? c.decode(Bool.self, forKey: .allowNetwork)) ?? false
        memoryMB = (try? c.decode(Int.self, forKey: .memoryMB)) ?? 128
        maxConnections = (try? c.decode(Int.self, forKey: .maxConnections)) ?? 1024
        threads = (try? c.decode(Int.self, forKey: .threads)) ?? 4
        logLevel = (try? c.decode(Int.self, forKey: .logLevel)) ?? 1
    }
}

enum MemcachedServer {
    static let formula = "memcached"
    static func binary(prefix: String) -> String { prefix + "/opt/memcached/bin/memcached" }
    static var pidFile: String { Paths.run + "/memcached.pid" }
    static var logFile: String { Paths.logs + "/memcached.log" }

    static func arguments(_ s: MemcachedSettings) -> [String] {
        var a = ["-p", String(s.port), "-l", s.allowNetwork ? "0.0.0.0" : "127.0.0.1", "-U", "0",
                 "-m", String(max(8, s.memoryMB)), "-c", String(max(16, s.maxConnections)), "-t", String(min(max(1, s.threads), 32))]
        if s.logLevel == 1 { a.append("-v") } else if s.logLevel >= 2 { a.append("-vv") }
        return a
    }

    struct Stats: Sendable {
        var version = ""
        var uptime = 0, connections = 0, totalConnections = 0
        var items = 0, bytes = 0, limit = 0
        var gets = 0, sets = 0, hits = 0, misses = 0, evictions = 0
    }

    /// Sends one text command to the server and returns its reply (up to the END / OK line).
    static func talk(_ command: String, port: Int) async -> String? {
        let r = await Shell.run("/usr/bin/nc", ["-w", "2", "127.0.0.1", String(port)], input: command + "\r\nquit\r\n")
        return r.ok ? r.output : nil
    }

    static func stats(port: Int) async -> Stats? {
        guard let text = await talk("stats", port: port), text.contains("STAT version") else { return nil }
        var map: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count == 3, parts[0] == "STAT" { map[parts[1]] = parts[2].trimmingCharacters(in: .whitespaces) }
        }
        func n(_ k: String) -> Int { Int(map[k] ?? "") ?? 0 }
        return Stats(version: map["version"] ?? "", uptime: n("uptime"), connections: n("curr_connections"), totalConnections: n("total_connections"),
                     items: n("curr_items"), bytes: n("bytes"), limit: n("limit_maxbytes"),
                     gets: n("cmd_get"), sets: n("cmd_set"), hits: n("get_hits"), misses: n("get_misses"), evictions: n("evictions"))
    }

    static func flush(port: Int) async -> Bool {
        (await talk("flush_all", port: port))?.contains("OK") == true
    }

    static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary) }
}

extension AppState {
    func startMemcached() async {
        let s = config.memcached
        try? FileManager.default.removeItem(atPath: MemcachedServer.pidFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MemcachedServer.binary(prefix: brew.prefix))
        process.arguments = MemcachedServer.arguments(s)
        process.standardInput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: MemcachedServer.logFile, contents: nil)
        let log = FileHandle(forWritingAtPath: MemcachedServer.logFile)
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        do { try process.run() } catch { errors[.memcached] = String(localized: "Couldn't start the object cache: \(error.localizedDescription)"); return }
        try? await Task.sleep(for: .milliseconds(700))
        guard process.isRunning else {
            errors[.memcached] = String(localized: "The object cache did not start.") + "\n" + ProcessInfoHelper.tail(MemcachedServer.logFile, lines: 6)
            return
        }
        try? String(process.processIdentifier).write(toFile: MemcachedServer.pidFile, atomically: true, encoding: .utf8)
        memcachedNeedsRestart = false
    }

    func stopMemcached() async {
        if let pid = ProcessInfoHelper.livePID(pidFile: MemcachedServer.pidFile) { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, ProcessInfoHelper.livePID(pidFile: MemcachedServer.pidFile) != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? FileManager.default.removeItem(atPath: MemcachedServer.pidFile)
        memcachedNeedsRestart = false
    }
}
