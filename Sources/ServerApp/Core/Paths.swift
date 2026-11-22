// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// All files the app owns. Configs, logs, data and certificates live in Application Support;
/// pid files and unix sockets live in a short /tmp path because sockets are limited to 104 bytes.
enum Paths {
    static let fm = FileManager.default

    static let support: String = {
        if let override = ProcessInfo.processInfo.environment["SERVER_APP_SUPPORT"] { return override }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        return base + "/Server"
    }()
    static var configFile: String { support + "/config.json" }
    static var conf: String { support + "/conf" }
    static var apacheConf: String { conf + "/apache" }
    static var nginxConf: String { conf + "/nginx" }
    static var phpConf: String { conf + "/php" }
    static var mysqlConf: String { conf + "/mysql" }
    static var logs: String { support + "/logs" }
    static var siteLogs: String { logs + "/sites" }
    static var data: String { support + "/data" }
    static var ssl: String { support + "/ssl" }
    static var work: String { support + "/work" }        // cwd for brew, scratch files

    static let run = ProcessInfo.processInfo.environment["SERVER_APP_RUN"] ?? "/tmp/serverapp-\(getuid())"

    static func mysqlDataDir(_ formula: String) -> String {
        data + "/" + formula.replacingOccurrences(of: "@", with: "-")
    }
    static func phpTag(_ formula: String) -> String { formula.replacingOccurrences(of: "@", with: "-") }
    static func phpSocket(_ formula: String) -> String { run + "/\(phpTag(formula)).sock" }
    static var mysqlSocket: String { run + "/mysql.sock" }

    static func ensureDirectories() {
        for dir in [support, conf, apacheConf, apacheConf + "/sites", nginxConf, nginxConf + "/sites", phpConf, mysqlConf,
                    logs, siteLogs, data, ssl, work, run, run + "/apache", run + "/nginx"] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    static func write(_ text: String, to path: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
