// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// Thin wrapper around nvm (installed with Homebrew), which manages Node.js versions in ~/.nvm.
/// nvm is a shell function, so every call sources nvm.sh in a bash subshell; arguments are passed
/// through argv, never spliced into the script.
enum NVM {
    static let formula = "nvm"
    static var dir: String { NSHomeDirectory() + "/.nvm" }
    static func script(prefix: String) -> String { prefix + "/opt/nvm/nvm.sh" }
    static func isInstalled(prefix: String) -> Bool { FileManager.default.fileExists(atPath: script(prefix: prefix)) }

    struct Release: Identifiable, Hashable {
        var id: String { version }
        let version: String          // v22.21.1
        let lts: String?             // codename, e.g. "Jod"
        var major: Int { Int(version.dropFirst().split(separator: ".").first ?? "") ?? 0 }
    }

    /// Runs `nvm <args…>`. `onLine` streams output (for installs).
    static func run(_ args: [String], prefix: String, onLine: (@Sendable (String) -> Void)? = nil) async -> ShellResult {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let body = #"export NVM_DIR="$1"; . "$2" --no-use; shift 2; nvm "$@""#
        return await Shell.run("/bin/bash", ["-c", body, "nvm", dir, script(prefix: prefix)] + args,
                               env: ["NVM_DIR": dir, "NO_COLOR": "1"], onLine: onLine)
    }

    /// Installed versions, newest first (read straight from ~/.nvm, no subshell).
    static func installed() -> [String] {
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/versions/node")) ?? []
        return versions.filter { $0.hasPrefix("v") }.sorted { compare($0, $1) == .orderedDescending }
    }

    /// The version `nvm alias default` resolves to (e.g. v22.21.1), or nil.
    static func defaultVersion(prefix: String) async -> String? {
        guard FileManager.default.fileExists(atPath: dir + "/alias/default") else { return nil }
        let r = await run(["version", "default"], prefix: prefix)
        let v = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.hasPrefix("v") ? v : nil
    }

    /// LTS releases, newest patch of each major line first.
    static func remoteLTS(prefix: String) async -> [Release] {
        let r = await run(["ls-remote", "--lts", "--no-colors"], prefix: prefix)
        var latest: [Int: Release] = [:]
        for line in r.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "-" || $0 == ">" }).map(String.init)
            guard let v = parts.first(where: { $0.hasPrefix("v") && $0.contains(".") }) else { continue }
            let codename = line.range(of: "LTS: ").map { String(line[$0.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ") ")) }
            let rel = Release(version: v, lts: codename)
            if let cur = latest[rel.major], compare(cur.version, v) != .orderedAscending { continue }
            latest[rel.major] = rel
        }
        return latest.values.sorted { $0.major > $1.major }
    }

    /// Latest current (non-LTS) release.
    static func latestCurrent(prefix: String) async -> String? {
        let r = await run(["ls-remote", "--no-colors"], prefix: prefix)
        // Stable releases only (pre-releases have a "-" suffix, e.g. v27.0.0-alpha).
        return r.output.split(separator: "\n")
            .compactMap { line in line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init).first { $0.hasPrefix("v") && $0.contains(".") } }
            .filter { !$0.contains("-") }
            .max { compare($0, $1) == .orderedAscending }
    }

    static func binDir(_ version: String) -> String { dir + "/versions/node/\(version)/bin" }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.dropFirst().compare(b.dropFirst(), options: .numeric)
    }

    // MARK: Shell profile

    static var zshrc: String { NSHomeDirectory() + "/.zshrc" }

    /// Whether ~/.zshrc loads nvm, so `node` works in Terminal.
    static func shellConfigured() -> Bool {
        ((try? String(contentsOfFile: zshrc, encoding: .utf8)) ?? "").contains("nvm.sh")
    }

    static func addToShell(prefix: String) throws {
        var text = (try? String(contentsOfFile: zshrc, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += """

        # nvm (added by Server)
        export NVM_DIR="$HOME/.nvm"
        [ -s "\(script(prefix: prefix))" ] && \\. "\(script(prefix: prefix))"

        """
        try text.write(toFile: zshrc, atomically: true, encoding: .utf8)
    }
}
