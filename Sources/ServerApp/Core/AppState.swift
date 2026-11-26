// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SwiftUI

enum ServiceKind: String, CaseIterable, Identifiable {
    case apache, nginx, mysql, ftp, dns, ai, redis, memcached, mail
    var id: String { rawValue }
    var title: String {
        switch self { case .apache: "Apache"; case .nginx: "Nginx"; case .mysql: "MySQL"; case .ftp: "FTP"; case .dns: "DNS"; case .ai: "AI Models"; case .redis: "Redis"; case .memcached: "Object Caching"; case .mail: "Mail" }
    }
    var formulaHint: String {
        switch self { case .apache: "httpd"; case .nginx: "nginx"; case .mysql: "mysql"; case .ftp: "pure-ftpd"; case .dns: "dnsmasq"; case .ai: "afm-cli"; case .redis: "redis"; case .memcached: "memcached"; case .mail: "dovecot" }
    }
}

enum RunState: Equatable {
    case notInstalled, stopped, starting, running, stopping
    var label: String {
        switch self {
        case .notInstalled: String(localized: "Not installed")
        case .stopped: String(localized: "Stopped")
        case .starting: String(localized: "Starting…")
        case .running: String(localized: "Running")
        case .stopping: String(localized: "Stopping…")
        }
    }
    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping: .orange
        case .stopped: .secondary
        case .notInstalled: .secondary.opacity(0.5)
        }
    }
}

@MainActor @Observable
final class AppState {
    let brew = Homebrew()
    private(set) var config = AppConfig()

    var states: [ServiceKind: RunState] = [:]
    var errors: [ServiceKind: String] = [:]        // last start / config error per service
    var nodeErrors: [UUID: String] = [:]           // last start error per Node.js website
    var nodeRunning: Set<UUID> = []                // Node.js websites whose app is running
    var phpRunning: Set<String> = []
    var mysqlNeedsRestart = false
    var ftpNeedsRestart = false          // FTP settings changed while it was running
    var mailNeedsRestart = false         // Mail settings changed while it was running
    var memcachedNeedsRestart = false    // Object cache settings changed while it was running
    var redisNeedsRestart = false        // Redis settings changed while it was running
    let tunnels = CloudflareTunnels()        // Cloudflare quick tunnels (stop when the app quits)
    var tunnelInstalling: Set<String> = []   // tunnels waiting for cloudflared to install
    var phpInstalling: Set<String> = []  // PHP versions being installed or removed
    var phpInstallErrors: [String: String] = [:]
    var notice: String?                            // transient banner text
    var certificateInfo: [UUID: CertificateInfo] = [:]   // parsed details of stored certificates
    var showSettings = false                       // the Settings sheet

    @ObservationIgnored var transitional: Set<ServiceKind> = []
    @ObservationIgnored var applyTask: Task<Void, Never>?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored var lastMySQLConfValue = ""

    var generator: ConfigGenerator { ConfigGenerator(config: config, prefix: brew.prefix) }

    init() {
        Paths.ensureDirectories()
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Paths.support)
        load()
        refreshStates()
    }

    func startup() async {
        tunnels.cleanupOrphans()          // tunnels left behind by a crash must not stay public
        writeDefaultPage()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStates() }
        }
        let upgraded = await brew.bootstrap { [weak self] in self?.managedFormulae() ?? [] }
        await applyConfiguration()
        refreshStates()
        if !upgraded.isEmpty {
            flash("Upgraded: " + upgraded.joined(separator: ", "))
            await restartRunningServices()
        }
    }

    /// Only formulae this app uses are ever upgraded. Never a bare `brew upgrade`.
    func managedFormulae() -> [String] {
        var set: Set<String> = ["httpd", "nginx", config.mysql.formula, FTPServer.formula, DNSServer.formula, AIServer.formula, RedisServer.formula, MemcachedServer.formula, MailServer.formula, "cloudflared"]
        for s in config.websites where !s.servedPHP.isEmpty { set.insert(s.servedPHP) }
        if NVM.isInstalled(prefix: brew.prefix) { set.insert(NVM.formula) }
        set.insert(Composer.formula)
        return set.sorted()
    }

    // MARK: Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: Paths.configFile) else { return }
        do {
            config = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            // Unreadable settings are set aside, never silently overwritten by the next change.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = Paths.configFile + ".unreadable-" + stamp
            try? FileManager.default.copyItem(atPath: Paths.configFile, toPath: aside)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside)
            notice = "Your settings file couldn't be read. A copy was kept as \((aside as NSString).lastPathComponent)."
            return
        }
        backUpConfig(data)
    }

    /// Keeps the last few different versions of the settings (newest 5), so a bad edit or a
    /// future format change can always be undone by hand. Private, since they hold passwords.
    private func backUpConfig(_ data: Data) {
        let fm = FileManager.default
        let dir = Paths.support + "/config-backups"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let existing = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("config-") && $0.hasSuffix(".json") }.sorted()
        if let latest = existing.last, fm.contents(atPath: dir + "/" + latest) == data { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let path = dir + "/config-\(stamp).json"
        if fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) {
            for old in existing.dropLast(4) { try? fm.removeItem(atPath: dir + "/" + old) }
        }
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.configFile), options: .atomic)
        // It holds database, Redis and API-key passwords: only this account may read it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.configFile)
    }

    /// Every mutation goes through here: persist, then regenerate configs (debounced).
    func update(_ change: (inout AppConfig) -> Void) {
        change(&config)
        save()
        scheduleApply()
    }

    func bind<T>(_ kp: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: kp] }, set: { v in self.update { $0[keyPath: kp] = v } })
    }

    func bindSite<T>(_ id: UUID, _ kp: WritableKeyPath<Website, T>) -> Binding<T> {
        Binding(
            get: { self.config.websites.first { $0.id == id }.map { $0[keyPath: kp] } ?? Website.placeholder[keyPath: kp] },
            set: { v in self.update { c in
                if let i = c.websites.firstIndex(where: { $0.id == id }) { c.websites[i][keyPath: kp] = v }
            } })
    }

    func site(_ id: UUID?) -> Website? { config.websites.first { $0.id == id } }

    // MARK: Status

    func refreshStates() {
        let g = generator
        let pidFiles: [ServiceKind: String] = [
            .apache: Paths.run + "/httpd.pid", .nginx: Paths.run + "/nginx.pid", .mysql: ConfigGenerator.mysqlPIDFile,
            .ftp: FTPServer.pidFile, .dns: DNSServer.pidFile, .ai: AIServer.pidFile, .redis: RedisServer.pidFile, .memcached: MemcachedServer.pidFile, .mail: MailServer.dovecotPID,
        ]
        let binaries: [ServiceKind: String] = [.apache: g.httpdBinary, .nginx: g.nginxBinary, .mysql: g.mysqlBin("mysqld"),
                                               .ftp: FTPServer.binary(prefix: brew.prefix),
                                               .dns: DNSServer.binary(prefix: brew.prefix),
                                               .ai: AIServer.afm(prefix: brew.prefix),
                                               .redis: RedisServer.binary(prefix: brew.prefix),
                                               .memcached: MemcachedServer.binary(prefix: brew.prefix),
                                               .mail: MailServer.dovecot(prefix: brew.prefix)]
        for kind in ServiceKind.allCases where !transitional.contains(kind) {
            let new: RunState
            if let pid = pidFiles[kind], ProcessInfoHelper.livePID(pidFile: pid) != nil { new = .running }
            else if !FileManager.default.isExecutableFile(atPath: binaries[kind] ?? "") { new = .notInstalled }
            else { new = .stopped }
            if states[kind] != new { states[kind] = new }
        }
        let php = Set(Homebrew.phpFormulae.filter { ProcessInfoHelper.livePID(pidFile: ConfigGenerator.phpPIDFile($0)) != nil })
        if php != phpRunning { phpRunning = php }
        refreshNodeStates()
    }

    func state(_ kind: ServiceKind) -> RunState { states[kind] ?? .stopped }
    func isRunning(_ kind: ServiceKind) -> Bool { state(kind) == .running }

    // MARK: Helpers

    func flash(_ text: String) {
        notice = text
        Task { try? await Task.sleep(for: .seconds(5)); if notice == text { notice = nil } }
    }

    func writeDefaultPage() {
        let index = ConfigGenerator.defaultDocRoot + "/index.html"
        guard !FileManager.default.fileExists(atPath: index) else { return }
        try? Paths.write("""
        <!doctype html><html><head><meta charset="utf-8"><title>Server</title>
        <style>body{font:16px -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;background:#f5f5f7;color:#1d1d1f}
        @media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}</style></head>
        <body><div><h1>It works.</h1><p>This server is managed by Server. No website matches this host name.</p></div></body></html>
        """, to: index)
    }
}

extension Website {
    static let placeholder = Website(name: "", hostname: "", documentRoot: "")
}
