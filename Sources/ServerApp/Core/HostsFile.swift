// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// One line of /etc/hosts. Lines we don't edit keep their exact original text, so entries other
/// apps own (MAMP PRO, VPN clients…) survive byte for byte.
struct HostsLine: Identifiable, Equatable {
    let id = UUID()
    var raw: String                 // original text; re-emitted as-is unless `entry` was edited
    var entry: HostEntry?           // nil for comments, blank lines and anything unparseable
    var edited = false

    var text: String { edited ? (entry?.formatted ?? raw) : raw }
}

struct HostEntry: Equatable {
    var address: String
    var names: [String]
    var comment: String = ""
    var enabled = true

    /// The system entries macOS needs; never edited or removed.
    var isSystem: Bool {
        (names == ["localhost"] && (address == "127.0.0.1" || address == "::1"))
            || (address == "255.255.255.255" && names == ["broadcasthost"])
    }

    var formatted: String {
        var line = "\(address)\t\(names.joined(separator: " "))"
        if !comment.isEmpty { line += "\t# \(comment)" }
        return enabled ? line : "#" + line
    }

    static func isValidAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    static func isValidName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 253 && !s.hasPrefix("-") && !s.hasPrefix(".")
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_") }
    }
}

enum HostsFile {
    /// The file to manage. Tests point SERVER_APP_HOSTS at a scratch copy, never the real one.
    static let path = ProcessInfo.processInfo.environment["SERVER_APP_HOSTS"] ?? "/etc/hosts"
    static var isSystemFile: Bool { path == "/etc/hosts" }

    static func read() -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func parse(_ text: String) -> [HostsLine] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }       // trailing newline
        return lines.map { HostsLine(raw: $0, entry: parseEntry($0)) }
    }

    /// `address names… [# comment]`, or the same commented out with a single leading `#`.
    static func parseEntry(_ line: String) -> HostEntry? {
        var body = line.trimmingCharacters(in: .whitespaces)
        var enabled = true
        if body.hasPrefix("#") {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            enabled = false
            if body.hasPrefix("#") { return nil }
        }
        var comment = ""
        if let hash = body.firstIndex(of: "#") {
            comment = body[body.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            body = String(body[..<hash])
        }
        let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2, HostEntry.isValidAddress(parts[0]),
              parts.dropFirst().allSatisfy(HostEntry.isValidName) else { return nil }
        return HostEntry(address: parts[0], names: Array(parts.dropFirst()), comment: comment, enabled: enabled)
    }

    static func serialize(_ lines: [HostsLine]) -> String {
        lines.map(\.text).joined(separator: "\n") + "\n"
    }

    /// Writes the new contents. `original` is the text the edits were based on: if the file
    /// changed since (another app edited it), nothing is written.
    /// Returns an error message, "" if cancelled, or nil on success.
    static func save(_ text: String, original: String) async -> String? {
        guard read() == original else {
            return "The hosts file was changed by another app since it was loaded. Reload it and make your changes again."
        }
        Paths.ensureDirectories()
        let staged = Paths.work + "/hosts.new"
        do { try text.write(toFile: staged, atomically: true, encoding: .utf8) } catch {
            return "Couldn't prepare the new hosts file: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(atPath: staged) }
        // Keep the file as it was before Server's first change.
        let backup = Paths.support + "/hosts.backup"
        if !FileManager.default.fileExists(atPath: backup) { try? original.write(toFile: backup, atomically: true, encoding: .utf8) }

        guard isSystemFile else {
            // Scratch copy (tests): no privileges or cache flush needed.
            do { try text.write(toFile: path, atomically: true, encoding: .utf8); return nil } catch {
                return error.localizedDescription
            }
        }
        // Copy into place, restore root:wheel 644, then flush the DNS cache.
        return await Privileged.run([
            ["/bin/cp", staged, path],
            ["/usr/sbin/chown", "root:wheel", path],
            ["/bin/chmod", "644", path],
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "mDNSResponder"],
        ])
    }
}
