// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// Runs system commands as root through macOS's own administrator password prompt
/// (AppleScript `with administrator privileges`). Used for /etc/hosts, File Sharing,
/// Content Caching and the firewall — never for the app's own services.
enum Privileged {
    enum Outcome {
        case success(String)        // the commands' output
        case cancelled
        case failed(String)
    }

    /// Argument that sends the preceding command's output to /dev/null (needed for daemons, which
    /// would otherwise keep `do shell script` waiting on their inherited output).
    static let quiet = "@@server-quiet@@"

    /// Runs each command (an executable path followed by its arguments) in order, stopping at
    /// the first failure, behind a single password prompt. Arguments travel through argv and are
    /// quoted by AppleScript, so nothing is spliced into a shell string.
    static func execute(_ commands: [[String]]) async -> Outcome {
        var argv: [String] = []
        for (i, command) in commands.enumerated() {
            if i > 0 { argv.append("&&") }
            argv += command
        }
        let script = [
            "on run argv",
            "set cmd to \"\"",
            "repeat with a in argv",
            "if (a as text) is \"&&\" then",
            "set cmd to cmd & \"&& \"",
            "else if (a as text) is \"@@server-quiet@@\" then",
            "set cmd to cmd & \"> /dev/null 2>&1 \"",
            "else",
            "set cmd to cmd & quoted form of (a as text) & \" \"",
            "end if",
            "end repeat",
            "do shell script cmd with administrator privileges",
            "end run",
        ]
        var args: [String] = []
        for line in script { args += ["-e", line] }
        let r = await Shell.run("/usr/bin/osascript", args + argv)
        if r.ok { return .success(r.output) }
        if r.output.contains("-128") || r.output.localizedCaseInsensitiveContains("user canceled") { return .cancelled }
        return .failed(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs the commands; returns an error message, "" if the user cancelled, or nil on success.
    static func run(_ commands: [[String]]) async -> String? {
        switch await execute(commands) {
        case .success: return nil
        case .cancelled: return ""
        case .failed(let message): return message
        }
    }
}
