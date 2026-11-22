// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// Owns every interaction with Homebrew. All brew commands go through one serial queue,
/// because brew holds a global lock and concurrent installs fail.
@MainActor @Observable
final class Homebrew {
    enum Phase: Equatable { case checking, installingBrew, updating, ready, failed(String) }

    static let phpFormulae = PHPCatalog.formulae
    static let mysqlFormulae = ["mysql@8.4", "mysql"]

    private(set) var brewPath: String?
    private(set) var phase: Phase = .checking
    private(set) var installed: [String: String] = [:]     // formula -> version
    private(set) var busyTask: String?                      // human readable current operation
    private(set) var activity: [String] = []                // recent brew output
    private(set) var lastUpgrade: Date?

    @ObservationIgnored private var tail: Task<Void, Never>?

    var prefix: String {
        guard let brewPath else { return Self.defaultPrefix }
        return ((brewPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }
    static var defaultPrefix: String {
        var info = utsname(); uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        return machine == "arm64" ? "/opt/homebrew" : "/usr/local"
    }

    /// Tapped formulae ("user/tap/name") live in opt/ under their short name.
    /// "user/tap/name" → "name".
    nonisolated static func shortName(_ formula: String) -> String { formula.split(separator: "/").last.map(String.init) ?? formula }

    func opt(_ formula: String) -> String { prefix + "/opt/" + (formula.split(separator: "/").last.map(String.init) ?? formula) }
    func isInstalled(_ formula: String) -> Bool { FileManager.default.fileExists(atPath: opt(formula)) }
    func version(_ formula: String) -> String? { installed[formula.split(separator: "/").last.map(String.init) ?? formula] }

    static func phpLabel(_ formula: String, version: String?) -> String {
        if formula.isEmpty { return "None (static files only)" }
        if formula == "php" { return version.map { "PHP \(shortVersion($0)) (latest)" } ?? "PHP (latest)" }
        return "PHP " + formula.replacingOccurrences(of: "php@", with: "")
    }
    nonisolated static func shortVersion(_ v: String) -> String { v.split(separator: ".").prefix(2).joined(separator: ".") }

    // MARK: Serial queue

    private func enqueue<T: Sendable>(_ label: String, _ op: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            _ = await previous?.value
            busyTask = label
            defer { busyTask = nil }
            return await op()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func log(_ line: String) {
        activity.append(line)
        if activity.count > 400 { activity.removeFirst(activity.count - 400) }
    }

    /// Runs brew. `quiet` keeps routine queries (like the installed list) out of the activity log.
    private func brew(_ args: [String], quiet: Bool = false) async -> ShellResult {
        guard let brewPath else { return ShellResult(status: -1, output: "Homebrew is not installed") }
        if quiet {
            return await Shell.run(brewPath, args, cwd: Paths.work)
        }
        log("$ brew " + args.joined(separator: " "))
        // Run from our own scratch dir: some bottles' post-install steps write relative paths into the cwd.
        return await Shell.run(brewPath, args, cwd: Paths.work) { line in
            Task { @MainActor [weak self] in self?.log(line) }
        }
    }

    // MARK: Lifecycle

    /// First-run bootstrap: install Homebrew if needed, then update and upgrade managed formulae.
    func bootstrap(managed: @escaping @MainActor () -> [String]) async -> [String] {
        phase = .checking
        brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if brewPath == nil {
            phase = .installingBrew
            let ok = await enqueue("Installing Homebrew…") { await self.installHomebrew() }
            brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
            guard ok, brewPath != nil else {
                phase = .failed("Homebrew could not be installed. See the activity log for details.")
                return []
            }
        }
        await refreshInstalled()
        if ProcessInfo.processInfo.environment["SERVER_APP_SKIP_UPGRADE"] != nil { phase = .ready; return [] }
        phase = .updating
        let upgraded = await enqueue("Updating Homebrew…") { () -> [String] in
            _ = await self.brew(["update", "--quiet"])
            let targets = managed().filter { self.isInstalled($0) }
            guard !targets.isEmpty else { return [] }
            let outdated = await self.brew(["outdated", "--formula", "--quiet"] + targets.map(PHPCatalog.installName))
            // Tapped formulae may be reported with their tap prefix ("user/tap/name").
            let list = outdated.output.split(separator: "\n")
                .map { Self.shortName(String($0).trimmingCharacters(in: .whitespaces)) }
                .filter { targets.contains($0) }
            guard !list.isEmpty else { return [] }
            _ = await self.brew(["upgrade", "--formula"] + list.map(PHPCatalog.installName))
            return list
        }
        await refreshInstalled()
        lastUpgrade = Date()
        phase = .ready
        return upgraded
    }

    func bootstrapDetectOnly() async {
        brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
        phase = brewPath == nil ? .failed("Homebrew not found") : .ready
    }

    func refreshInstalled() async {
        guard brewPath != nil else { return }
        let r = await brew(["list", "--versions", "--formula"], quiet: true)
        var map: [String: String] = [:]
        for line in r.output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            // Several versions can be installed side by side; use the newest.
            if parts.count >= 2 {
                map[String(parts[0])] = parts.dropFirst().map(String.init)
                    .max { $0.compare($1, options: .numeric) == .orderedAscending }
            }
        }
        installed = map
    }

    /// Installs a formula if needed. Success is judged by the `opt/` link, since some bottles
    /// report post-install errors while installing fine.
    @discardableResult
    func ensureInstalled(_ formula: String) async -> Bool {
        if isInstalled(formula) { return true }
        guard brewPath != nil else { return false }
        // Old PHP versions are installed by their tap name, which also adds the tap.
        _ = await enqueue("Installing \(formula)…") { await self.brew(["install", "--formula", PHPCatalog.installName(formula)]) }
        await refreshInstalled()
        return isInstalled(formula)
    }

    /// The newer version Homebrew can upgrade a formula to, or nil when it's current.
    func availableUpgrade(_ formula: String) async -> String? {
        guard brewPath != nil, isInstalled(formula) else { return nil }
        let r = await brew(["outdated", "--formula", "--json=v2", formula], quiet: true)
        guard let start = r.output.firstIndex(of: "{"),
              let data = String(r.output[start...]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let f = (o["formulae"] as? [[String: Any]])?.first else { return nil }
        return f["current_version"] as? String
    }

    /// Upgrades one formula (and only that one).
    @discardableResult
    func upgrade(_ formula: String) async -> Bool {
        let r = await enqueue("Upgrading \(formula)…") { await self.brew(["upgrade", "--formula", formula]) }
        await refreshInstalled()
        return r.ok
    }

    /// Makes `formula` the `php` on the PATH: unlinks the current one and links this one.
    func linkPHP(_ formula: String, replacing current: String?) async -> String? {
        let r = await enqueue("Setting default PHP…") { () -> ShellResult in
            if let current, current != formula { _ = await self.brew(["unlink", current]) }
            return await self.brew(["link", "--overwrite", "--force", formula])
        }
        return r.ok ? nil : r.output.split(separator: "\n").suffix(6).joined(separator: "\n")
    }

    func uninstall(_ formula: String) async {
        _ = await enqueue("Removing \(formula)…") { await self.brew(["uninstall", "--formula", PHPCatalog.installName(formula)]) }
        await refreshInstalled()
    }

    // MARK: Homebrew installer

    /// Runs the official installer non-interactively. If sudo needs a password, a native
    /// macOS password dialog is shown through SUDO_ASKPASS (the only prompt the user sees).
    private func installHomebrew() async -> Bool {
        Paths.ensureDirectories()
        let installer = Paths.work + "/brew-install.sh"
        let askpass = Paths.work + "/askpass.sh"
        let askpassScript = """
        #!/bin/sh
        /usr/bin/osascript -e 'text returned of (display dialog "Server needs an administrator password to install Homebrew." with title "Server" default answer "" with hidden answer with icon caution buttons {"Cancel", "OK"} default button "OK")'
        """
        do {
            try Paths.write(askpassScript, to: askpass)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass)
        } catch { log("Could not write askpass helper: \(error.localizedDescription)"); return false }

        log("Downloading Homebrew installer…")
        let dl = await Shell.run("/usr/bin/curl", ["-fsSL", "-o", installer,
                                                    "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"])
        guard dl.ok else { log(dl.output); return false }
        let r = await Shell.run("/bin/bash", [installer], env: ["NONINTERACTIVE": "1", "SUDO_ASKPASS": askpass],
                                cwd: Paths.work) { line in
            Task { @MainActor [weak self] in self?.log(line) }
        }
        try? FileManager.default.removeItem(atPath: installer)
        return r.ok
    }
}
