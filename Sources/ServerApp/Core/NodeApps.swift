// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// Runs Node.js websites: one process per enabled Node site whose web server is running, with
/// the chosen nvm version first on PATH and PORT set. Output goes to the site's log.
extension AppState {
    static func nodePIDFile(_ site: Website) -> String { Paths.run + "/node-\(site.slug).pid" }
    static func nodeSignatureFile(_ site: Website) -> String { Paths.run + "/node-\(site.slug).sig" }
    static func nodeLogFile(_ site: Website) -> String { Paths.siteLogs + "/\(site.slug)-node.log" }

    func isNodeAppRunning(_ site: Website) -> Bool {
        ProcessInfoHelper.livePID(pidFile: Self.nodePIDFile(site)) != nil
    }

    /// Starts, restarts (when its settings changed) or stops each Node.js app to match what
    /// should be serving right now.
    func syncNode() async {
        Paths.ensureDirectories()
        let defaultVersion = await NVM.defaultVersion(prefix: brew.prefix)
        var wanted = Set<String>()
        for site in config.websites where site.isNode {
            let serverRunning = isRunning(site.server == .apache ? .apache : .nginx)
            guard site.enabled && serverRunning else {
                await stopNodeApp(site)
                continue
            }
            wanted.insert(site.slug)
            let version = site.node.version.isEmpty ? defaultVersion : site.node.version
            guard let version, FileManager.default.fileExists(atPath: NVM.binDir(version) + "/node") else {
                nodeErrors[site.id] = site.node.version.isEmpty
                    ? "No default Node.js version. Install one on the Node.js page."
                    : "Node.js \(site.node.version) isn't installed. Install it on the Node.js page."
                await stopNodeApp(site)
                continue
            }
            let signature = [version, site.node.command, String(site.node.port), site.node.environment, site.documentRoot]
                .joined(separator: "\u{1F}")
            let current = try? String(contentsOfFile: Self.nodeSignatureFile(site), encoding: .utf8)
            if isNodeAppRunning(site) && current == signature { continue }
            await stopNodeApp(site)
            await startNodeApp(site, version: version, signature: signature)
        }
        // Apps of deleted or renamed sites.
        for file in (try? FileManager.default.contentsOfDirectory(atPath: Paths.run)) ?? []
        where file.hasPrefix("node-") && file.hasSuffix(".pid") {
            let slug = String(file.dropFirst(5).dropLast(4))
            if !wanted.contains(slug), let pid = ProcessInfoHelper.livePID(pidFile: Paths.run + "/" + file) {
                await Self.terminateTree(pid)
                try? FileManager.default.removeItem(atPath: Paths.run + "/" + file)
            }
        }
        refreshNodeStates()
    }

    func refreshNodeStates() {
        let running = Set(config.websites.filter { $0.isNode && isNodeAppRunning($0) }.map(\.id))
        if running != nodeRunning { nodeRunning = running }
    }

    func restartNodeApp(_ site: Website) async {
        try? FileManager.default.removeItem(atPath: Self.nodeSignatureFile(site))
        await stopNodeApp(site)
        await syncNode()
    }

    private func startNodeApp(_ site: Website, version: String, signature: String) async {
        nodeErrors[site.id] = nil
        guard FileManager.default.fileExists(atPath: site.documentRoot) else {
            nodeErrors[site.id] = "The site folder doesn't exist: \(site.documentRoot)"; return
        }
        if let owner = await ProcessInfoHelper.portOwner(site.node.port) {
            nodeErrors[site.id] = "Port \(site.node.port) is already in use by \(owner). Choose another app port."; return
        }
        let log = Self.nodeLogFile(site)
        if !FileManager.default.fileExists(atPath: log) { FileManager.default.createFile(atPath: log, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: log) else { nodeErrors[site.id] = "Can't write \(log)"; return }
        handle.seekToEndOfFile()
        handle.write(Data("\n── \(Date().formatted()) · Node.js \(version) · \(site.node.command)\n".utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", site.node.command]
        process.currentDirectoryURL = URL(fileURLWithPath: site.documentRoot)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [NVM.binDir(version), brew.prefix + "/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        env["PORT"] = String(site.node.port)
        env["NVM_DIR"] = NVM.dir
        for (k, v) in site.node.environmentPairs where !k.isEmpty { env[k] = v }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            nodeErrors[site.id] = "Couldn't start the app: \(error.localizedDescription)"; return
        }
        try? String(process.processIdentifier).write(toFile: Self.nodePIDFile(site), atomically: true, encoding: .utf8)
        try? signature.write(toFile: Self.nodeSignatureFile(site), atomically: true, encoding: .utf8)
        // Catch apps that exit straight away (missing package.json, syntax errors…).
        try? await Task.sleep(for: .seconds(1.5))
        if !process.isRunning {
            nodeErrors[site.id] = "The app exited (status \(process.terminationStatus)).\n"
                + ProcessInfoHelper.tail(log, lines: 8)
            try? FileManager.default.removeItem(atPath: Self.nodePIDFile(site))
        }
    }

    func stopNodeApp(_ site: Website) async {
        if let pid = ProcessInfoHelper.livePID(pidFile: Self.nodePIDFile(site)) { await Self.terminateTree(pid) }
        try? FileManager.default.removeItem(atPath: Self.nodePIDFile(site))
        try? FileManager.default.removeItem(atPath: Self.nodeSignatureFile(site))
    }

    /// SIGTERM a process and everything it started (npm → node), then SIGKILL stragglers.
    static func terminateTree(_ pid: pid_t) async {
        var all: [pid_t] = [pid]
        var queue: [pid_t] = [pid]
        while let p = queue.popLast() {
            let r = await Shell.run("/usr/bin/pgrep", ["-P", String(p)])
            let kids = r.output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            all += kids
            queue += kids
        }
        for p in all.reversed() { kill(p, SIGTERM) }
        for _ in 0..<25 {
            if all.allSatisfy({ kill($0, 0) != 0 }) { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        for p in all where kill(p, 0) == 0 { kill(p, SIGKILL) }
    }
}
