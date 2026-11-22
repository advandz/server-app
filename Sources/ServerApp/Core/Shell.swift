// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

struct ShellResult: Sendable {
    var status: Int32
    var output: String          // stdout + stderr, interleaved
    var ok: Bool { status == 0 }
}

/// Thin async wrapper around `Process`. No external dependencies.
enum Shell {
    /// Base environment for every child process. Apps launched from Finder get a
    /// minimal PATH, so we always add the Homebrew locations for both architectures.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let path = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                    "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["PATH"] = path
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"   // we run `brew update` ourselves, once per launch
        env["NONINTERACTIVE"] = "1"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Runs a command to completion, capturing output. `onLine` streams output lines as they arrive.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String] = [],
                    env: [String: String] = [:],
                    cwd: String? = nil,
                    input: String? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            process.environment = environment(env)
            let stdin = input.map { _ in Pipe() }
            process.standardInput = stdin ?? FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let buffer = OutputBuffer(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                buffer.append(rest)
                buffer.flush()
                cont.resume(returning: ShellResult(status: p.terminationStatus, output: buffer.text))
            }
            do {
                try process.run()
                if let stdin, let input {
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: ShellResult(status: -1, output: "Failed to launch \(executable): \(error.localizedDescription)"))
            }
        }
    }

    /// Runs a command whose children daemonize (httpd, nginx, php-fpm, mysqld).
    /// Output goes to a file instead of a pipe: forked daemons inherit the descriptors and
    /// would otherwise keep a pipe open forever.
    static func launchDaemon(_ executable: String, _ arguments: [String], logFile: String) async -> ShellResult {
        FileManager.default.createFile(atPath: logFile, contents: nil)
        return await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment()
            process.standardInput = FileHandle.nullDevice
            let handle = FileHandle(forWritingAtPath: logFile) ?? FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { p in
                try? handle.close()
                let text = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
                cont.resume(returning: ShellResult(status: p.terminationStatus, output: text))
            }
            do { try process.run() } catch {
                cont.resume(returning: ShellResult(status: -1, output: error.localizedDescription))
            }
        }
    }

    /// Single-quotes a string for /bin/sh.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?
    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        guard let onLine else { return }
        pending.append(chunk)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            onLine(line)
        }
    }
    func flush() {
        lock.lock(); defer { lock.unlock() }
        if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

// MARK: - Process helpers

enum ProcessInfoHelper {
    /// Reads a pid file and returns the pid if that process is alive.
    static func livePID(pidFile: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        if kill(pid, 0) == 0 || errno == EPERM { return pid }
        return nil
    }

    /// Returns "httpd (PID 123)" if some process is listening on the TCP port, nil otherwise.
    static func portOwner(_ port: Int, udp: Bool = false) async -> String? {
        let r = await Shell.run("/usr/sbin/lsof", udp ? ["-nP", "-iUDP:\(port)", "-Fpc"]
                                                      : ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"])
        guard r.ok else { return nil }
        var pid = "", cmd = ""
        for line in r.output.split(separator: "\n") {
            if line.hasPrefix("p"), pid.isEmpty { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), cmd.isEmpty { cmd = String(line.dropFirst()) }
        }
        return pid.isEmpty ? nil : "\(cmd) (PID \(pid))"
    }

    static func tail(_ path: String, lines: Int = 300) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        let slice = data.count > 256_000 ? data.suffix(256_000) : data
        let text = String(decoding: slice, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

extension Shell {
    /// Opens a text file in the user's default text editor.
    static func openInTextEditor(_ path: String) {
        guard !path.isEmpty else { return }
        Task { _ = await run("/usr/bin/open", ["-t", path]) }
    }
}
