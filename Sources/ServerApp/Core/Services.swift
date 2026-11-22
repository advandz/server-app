// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// Starting, stopping and reloading services. Every action uses only our own pid and config
/// files, so it never touches other servers on the machine (MAMP, brew services, etc).
extension AppState {

    // MARK: Configuration

    func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.applyConfiguration()
        }
    }

    /// Writes all config files. Each server config is written to a staging file, validated
    /// with the server's own syntax check and only then swapped in, so a bad edit never
    /// leaves a broken config behind. Running servers are reloaded gracefully.
    func applyConfiguration() async {
        Paths.ensureDirectories()
        writeDefaultPage()
        await ensureCertificates()
        let g = generator

        // Apache
        if FileManager.default.isExecutableFile(atPath: g.httpdBinary) {
            let ok = await stageAndSwap(g.apacheConfig(), target: ConfigGenerator.apacheConfFile, kind: .apache) { staging in
                await Shell.run(g.httpdBinary, ["-t", "-f", staging])
            }
            if ok && isRunning(.apache) {
                _ = await Shell.run(g.httpdBinary, ["-f", ConfigGenerator.apacheConfFile, "-k", "graceful"])
            }
        }
        // Nginx
        if FileManager.default.isExecutableFile(atPath: g.nginxBinary) {
            let ok = await stageAndSwap(g.nginxConfig(), target: ConfigGenerator.nginxConfFile, kind: .nginx) { staging in
                await Shell.run(g.nginxBinary, ["-t", "-c", staging, "-e", Paths.logs + "/nginx_error.log"])
            }
            if ok && isRunning(.nginx) {
                _ = await Shell.run(g.nginxBinary, ["-c", ConfigGenerator.nginxConfFile, "-e", Paths.logs + "/nginx_error.log", "-s", "reload"])
            }
        }
        // PHP-FPM
        for formula in Homebrew.phpFormulae where brew.isInstalled(formula) {
            try? Paths.write(g.phpFPMConfig(formula), to: ConfigGenerator.phpConfFile(formula))
        }
        if isRunning(.apache) || isRunning(.nginx) { await syncPHP() }
        await syncNode()
        // MySQL (applies on next restart)
        let my = g.mysqlConfig()
        try? Paths.write(my, to: ConfigGenerator.mysqlConfFile)
        if isRunning(.mysql), !lastMySQLConfValue.isEmpty, lastMySQLConfValue != my { mysqlNeedsRestart = true }
        if !isRunning(.mysql) { lastMySQLConfValue = my }
    }

    private func stageAndSwap(_ text: String, target: String, kind: ServiceKind,
                              test: (String) async -> ShellResult) async -> Bool {
        let staging = target + ".staging"
        do { try Paths.write(text, to: staging) } catch {
            errors[kind] = "Could not write configuration: \(error.localizedDescription)"; return false
        }
        let r = await test(staging)
        if r.ok {
            _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: staging))
            if !FileManager.default.fileExists(atPath: target) { try? FileManager.default.moveItem(atPath: staging, toPath: target) }
            if errors[kind]?.hasPrefix("Configuration error") == true { errors[kind] = nil }
            return true
        }
        errors[kind] = "Configuration error — the previous configuration is still in use:\n" + r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return false
    }

    // MARK: Certificates

    func ensureCertificates() async {
        for site in config.websites where site.enabled && site.ssl.enabled && site.ssl.mode == .selfSigned {
            let paths = ConfigGenerator.certificatePaths(site)
            let dir = (paths.cert as NSString).deletingLastPathComponent
            let sanFile = dir + "/names.txt"
            let names = site.allHostnames.joined(separator: " ")
            let existing = (try? String(contentsOfFile: sanFile, encoding: .utf8)) ?? ""
            if existing == names && FileManager.default.fileExists(atPath: paths.cert) { continue }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let cnf = """
            [req]
            distinguished_name=dn
            x509_extensions=v3
            prompt=no
            [dn]
            CN=\(site.hostname)
            O=Server Development Certificate
            [v3]
            subjectAltName=\(site.allHostnames.map { "DNS:\($0)" }.joined(separator: ","))
            basicConstraints=CA:FALSE
            keyUsage=digitalSignature,keyEncipherment
            extendedKeyUsage=serverAuth
            """
            let cnfPath = dir + "/openssl.cnf"
            try? Paths.write(cnf, to: cnfPath)
            let r = await Shell.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "825",
                                                         "-keyout", paths.key, "-out", paths.cert, "-config", cnfPath])
            if r.ok { try? Paths.write(names, to: sanFile) }
            else { errors[site.server == .apache ? .apache : .nginx] = "Certificate for \(site.hostname) failed: \(r.output)" }
        }
    }

    /// Adds a self-signed certificate to the login keychain as trusted (asks for the user's password).
    func trustCertificate(_ site: Website) async {
        let cert = ConfigGenerator.certificatePaths(site).cert
        let keychain = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        let r = await Shell.run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, cert])
        flash(r.ok ? "Certificate for \(site.hostname) is now trusted." : "Could not trust certificate: \(r.output)")
    }

    // MARK: Start / stop

    func start(_ kind: ServiceKind) async {
        guard !transitional.contains(kind) else { return }
        transitional.insert(kind); states[kind] = .starting; errors[kind] = nil
        defer { transitional.remove(kind); refreshStates() }

        let formula = switch kind {
        case .apache: "httpd"
        case .nginx: "nginx"
        case .mysql: config.mysql.formula
        case .ftp: FTPServer.formula
        case .dns: DNSServer.formula
        case .ai: AIServer.formula
        case .redis: RedisServer.formula
        }
        guard await brew.ensureInstalled(formula) else {
            errors[kind] = "Could not install \(formula) with Homebrew. See Overview → Activity for details."; return
        }
        await applyConfiguration()
        if kind == .apache || kind == .nginx, errors[kind]?.hasPrefix("Configuration error") == true { return }

        // Refuse to start if another program owns one of our ports.
        let ports: [Int] = switch kind {
        case .mysql: [config.mysql.port]
        case .ftp: [config.ftp.port]
        case .dns: []          // checked below, over UDP
        case .ai: [config.ai.port]
        case .redis: [config.redis.port]
        case .apache: config.ports(for: .apache).sorted()
        case .nginx: config.ports(for: .nginx).sorted()
        }
        for port in ports {
            if let owner = await ProcessInfoHelper.portOwner(port) {
                errors[kind] = "Port \(port) is already in use by \(owner). Stop that program or change the port in Settings."
                return
            }
        }

        if kind == .dns, let owner = await ProcessInfoHelper.portOwner(config.dns.port, udp: true) {
            errors[kind] = "Port \(config.dns.port) is already in use by \(owner). Stop that program or change the port in Settings."
            return
        }

        let g = generator
        switch kind {
        case .apache:
            await syncPHP(including: .apache)
            let r = await Shell.launchDaemon(g.httpdBinary, ["-f", ConfigGenerator.apacheConfFile, "-k", "start"],
                                             logFile: Paths.logs + "/apache_start.log")
            if !r.ok { errors[kind] = r.output.isEmpty ? "Apache exited with status \(r.status)." : r.output }
            else if !(await waitFor(pidFile: Paths.run + "/httpd.pid", alive: true)) {
                errors[kind] = "Apache did not start. Check the error log.\n" + ProcessInfoHelper.tail(Paths.logs + "/apache_error.log", lines: 8)
            }
        case .nginx:
            await syncPHP(including: .nginx)
            let r = await Shell.launchDaemon(g.nginxBinary, ["-c", ConfigGenerator.nginxConfFile, "-e", Paths.logs + "/nginx_error.log"],
                                             logFile: Paths.logs + "/nginx_start.log")
            if !r.ok { errors[kind] = r.output.isEmpty ? "Nginx exited with status \(r.status)." : r.output }
            else if !(await waitFor(pidFile: Paths.run + "/nginx.pid", alive: true)) {
                errors[kind] = "Nginx did not start. Check the error log."
            }
        case .mysql:
            await startMySQL()
        case .ftp:
            await startFTP()
        case .dns:
            await startDNS()
        case .ai:
            await startAI()
        case .redis:
            await startRedis()
        }
        if kind == .apache || kind == .nginx {
            // Leave the "starting" state first so the sync sees this server as running.
            transitional.remove(kind)
            refreshStates()
            await syncNode()
        }
    }

    func stop(_ kind: ServiceKind) async {
        guard !transitional.contains(kind) else { return }
        transitional.insert(kind); states[kind] = .stopping
        defer { transitional.remove(kind); refreshStates() }
        let g = generator
        switch kind {
        case .apache:
            _ = await Shell.run(g.httpdBinary, ["-f", ConfigGenerator.apacheConfFile, "-k", "stop"])
            _ = await waitFor(pidFile: Paths.run + "/httpd.pid", alive: false)
        case .nginx:
            _ = await Shell.run(g.nginxBinary, ["-c", ConfigGenerator.nginxConfFile, "-e", Paths.logs + "/nginx_error.log", "-s", "stop"])
            _ = await waitFor(pidFile: Paths.run + "/nginx.pid", alive: false)
        case .mysql:
            let r = await Shell.run(g.mysqlBin("mysqladmin"), ["--socket=\(Paths.mysqlSocket)", "-uroot", "shutdown"])
            if !r.ok, let pid = ProcessInfoHelper.livePID(pidFile: ConfigGenerator.mysqlPIDFile) { kill(pid, SIGTERM) }
            _ = await waitFor(pidFile: ConfigGenerator.mysqlPIDFile, alive: false, timeout: 30)
            mysqlNeedsRestart = false
        case .redis:
            // SIGTERM makes Redis save its data (when snapshots are on) before exiting.
            if let pid = ProcessInfoHelper.livePID(pidFile: RedisServer.pidFile) { kill(pid, SIGTERM) }
            _ = await waitFor(pidFile: RedisServer.pidFile, alive: false, timeout: 30)
            redisNeedsRestart = false
        case .ai:
            if let pid = ProcessInfoHelper.livePID(pidFile: AIServer.pidFile) { kill(pid, SIGTERM) }
            _ = await waitFor(pidFile: AIServer.pidFile, alive: false)
            try? FileManager.default.removeItem(atPath: AIServer.pidFile)
        case .dns:
            if let pid = ProcessInfoHelper.livePID(pidFile: DNSServer.pidFile) { kill(pid, SIGTERM) }
            _ = await waitFor(pidFile: DNSServer.pidFile, alive: false)
            try? FileManager.default.removeItem(atPath: DNSServer.pidFile)
        case .ftp:
            await stopFTP()
            if ProcessInfoHelper.livePID(pidFile: FTPServer.pidFile) == nil {
                try? FileManager.default.removeItem(atPath: FTPServer.pidFile)
                ftpNeedsRestart = false
            }
        }
        states[kind] = .stopped
        if kind == .apache || kind == .nginx { await syncPHP(); await syncNode() }
    }

    func restart(_ kind: ServiceKind) async {
        // FTP runs as root: stop and start in a single password prompt.
        if kind == .ftp, let pid = ProcessInfoHelper.livePID(pidFile: FTPServer.pidFile), !transitional.contains(.ftp) {
            transitional.insert(.ftp); states[.ftp] = .starting; errors[.ftp] = nil
            defer { transitional.remove(.ftp); refreshStates() }
            await startFTP(restartingPID: pid)
            return
        }
        if isRunning(kind) { await stop(kind) }
        await start(kind)
    }

    /// After upgrades. FTP isn't restarted automatically (it would ask for a password at launch).
    func restartRunningServices() async {
        for kind in ServiceKind.allCases where isRunning(kind) {
            if kind == .ftp { ftpNeedsRestart = true } else { await restart(kind) }
        }
    }

    func stopAll() async {
        for kind in ServiceKind.allCases where isRunning(kind) { await stop(kind) }
        await syncPHP()
    }

    private func waitFor(pidFile: String, alive: Bool, timeout: Double = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (ProcessInfoHelper.livePID(pidFile: pidFile) != nil) == alive { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    // MARK: PHP-FPM

    /// Restarts one PHP version's FPM pool (if running) so php.ini and extension changes apply.
    func restartPHP(_ formula: String) async {
        guard let pid = ProcessInfoHelper.livePID(pidFile: ConfigGenerator.phpPIDFile(formula)) else { return }
        kill(pid, SIGQUIT)
        _ = await waitFor(pidFile: ConfigGenerator.phpPIDFile(formula), alive: false)
        await syncPHP()
    }

    /// Starts one PHP-FPM master per PHP version used by a running web server, and stops the rest.
    func syncPHP(including starting: WebServer? = nil) async {
        var needed = Set<String>()
        for site in config.websites where site.enabled && !site.servedPHP.isEmpty {
            let serving = site.server == starting
                || (site.server == .apache && isRunning(.apache))
                || (site.server == .nginx && isRunning(.nginx))
            if serving { needed.insert(site.servedPHP) }
        }
        let g = generator
        for formula in needed.sorted() where ProcessInfoHelper.livePID(pidFile: ConfigGenerator.phpPIDFile(formula)) == nil {
            // Old versions come from a community tap: never installed silently, only from the PHP page.
            if PHPCatalog.needsTap(formula) && !brew.isInstalled(formula) {
                errors[starting == .nginx ? .nginx : .apache] =
                    "\(Homebrew.phpLabel(formula, version: nil)) isn't installed. Install it from the PHP page, then start the server again."
                continue
            }
            guard await brew.ensureInstalled(formula) else {
                errors[starting == .nginx ? .nginx : .apache] = "Could not install \(formula)."; continue
            }
            try? Paths.write(g.phpFPMConfig(formula), to: ConfigGenerator.phpConfFile(formula))
            try? FileManager.default.removeItem(atPath: Paths.phpSocket(formula))
            let r = await Shell.launchDaemon(g.phpFPMBinary(formula), ["-y", ConfigGenerator.phpConfFile(formula)],
                                             logFile: Paths.logs + "/\(Paths.phpTag(formula))-start.log")
            if !r.ok { errors[starting == .nginx ? .nginx : .apache] = "PHP-FPM (\(formula)) failed to start:\n\(r.output)" }
        }
        for formula in Homebrew.phpFormulae where !needed.contains(formula) {
            if let pid = ProcessInfoHelper.livePID(pidFile: ConfigGenerator.phpPIDFile(formula)) { kill(pid, SIGQUIT) }
        }
        try? await Task.sleep(for: .milliseconds(300))
        refreshStates()
    }

    // MARK: Redis

    private func startRedis() async {
        let s = config.redis
        if s.allowNetwork && s.password.isEmpty {
            errors[.redis] = "Set a password before letting other devices connect to Redis."; return
        }
        do { try RedisServer.writeConfig(s) } catch { errors[.redis] = "Couldn't write the Redis configuration: \(error.localizedDescription)"; return }
        try? FileManager.default.removeItem(atPath: RedisServer.pidFile)
        let r = await Shell.launchDaemon(RedisServer.binary(prefix: brew.prefix), [RedisServer.confFile], logFile: RedisServer.startLog)
        if !r.ok { errors[.redis] = r.output.isEmpty ? "Redis exited with status \(r.status)." : r.output }
        else if !(await waitFor(pidFile: RedisServer.pidFile, alive: true)) {
            errors[.redis] = "Redis did not start.\n" + ProcessInfoHelper.tail(RedisServer.logFile, lines: 8)
        }
    }

    // MARK: AI Models

    /// Runs this app's own binary as the headless OpenAI-compatible server (`Server --ai-server`),
    /// detached so it keeps serving after the app quits.
    private func startAI() async {
        guard let exe = Bundle.main.executablePath else { errors[.ai] = "Can't find the Server executable."; return }
        try? FileManager.default.removeItem(atPath: AIServer.pidFile)
        FileManager.default.createFile(atPath: AIServer.startLog, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = AIServer.arguments(config.ai, prefix: brew.prefix)
        var env = ProcessInfo.processInfo.environment
        env["SERVER_AI_API_KEY"] = config.ai.apiKey
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let log = FileHandle(forWritingAtPath: AIServer.startLog)
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        do { try process.run() } catch { errors[.ai] = "Couldn't start the AI server: \(error.localizedDescription)"; return }
        if !(await waitFor(pidFile: AIServer.pidFile, alive: true)) {
            errors[.ai] = "The AI server did not start.\n" + ProcessInfoHelper.tail(AIServer.startLog, lines: 8)
        }
    }

    // MARK: DNS

    private func startDNS() async {
        if let e = await DNSServer.writeConfig(config.dns, prefix: brew.prefix) { errors[.dns] = "Configuration error:\n" + e; return }
        try? FileManager.default.removeItem(atPath: DNSServer.pidFile)
        let r = await Shell.launchDaemon(DNSServer.binary(prefix: brew.prefix), DNSServer.arguments(), logFile: DNSServer.startLog)
        if !r.ok { errors[.dns] = r.output.isEmpty ? "The DNS server exited with status \(r.status)." : r.output }
        else if !(await waitFor(pidFile: DNSServer.pidFile, alive: true)) {
            errors[.dns] = "The DNS server did not start.\n" + ProcessInfoHelper.tail(DNSServer.startLog, lines: 8)
        }
    }

    /// Applies DNS settings: rewrites the config and restarts the server if it's running.
    func applyDNS() async {
        if let e = await DNSServer.writeConfig(config.dns, prefix: brew.prefix) {
            errors[.dns] = "Configuration error:\n" + e; return
        }
        errors[.dns] = nil
        if isRunning(.dns) { await restart(.dns) }
    }

    // MARK: FTP

    /// Starts pure-ftpd as root (one administrator prompt). With `restartingPID`, stops that
    /// process first in the same prompt.
    private func startFTP(restartingPID: pid_t? = nil) async {
        let prefix = brew.prefix
        if let e = await FTPServer.prepare(prefix: prefix) { errors[.ftp] = "Couldn't prepare FTP users:\n" + e; return }
        if config.ftp.tls, let e = await FTPServer.ensureCertificate(hostName: SystemStatus.shared.hostName) {
            errors[.ftp] = e; return
        }
        // Create the transfer log as this user, so root appends to a file the Logs page can clear.
        if !FileManager.default.fileExists(atPath: FTPServer.transferLog) {
            FileManager.default.createFile(atPath: FTPServer.transferLog, contents: nil)
        }
        var commands: [[String]] = []
        if let pid = restartingPID { commands += [["/bin/kill", String(pid)], ["/bin/sleep", "1"]] }
        commands.append(FTPServer.startCommand(config.ftp, prefix: prefix))
        switch await Privileged.execute(commands) {
        case .cancelled:
            errors[.ftp] = "FTP needs an administrator password to start."; return
        case .failed(let message):
            errors[.ftp] = "The FTP server did not start:\n" + message; return
        case .success:
            if !(await waitFor(pidFile: FTPServer.pidFile, alive: true)) { errors[.ftp] = "The FTP server did not start." }
        }
        ftpNeedsRestart = false
    }

    /// Stops pure-ftpd (root) with one administrator prompt.
    private func stopFTP() async {
        guard let pid = ProcessInfoHelper.livePID(pidFile: FTPServer.pidFile) else { return }
        switch await Privileged.execute([["/bin/kill", String(pid)]]) {
        case .cancelled: errors[.ftp] = "FTP needs an administrator password to stop."
        case .failed(let m): errors[.ftp] = m
        case .success: _ = await waitFor(pidFile: FTPServer.pidFile, alive: false)
        }
    }

    // MARK: MySQL

    private func startMySQL() async {
        let g = generator
        let dataDir = Paths.mysqlDataDir(config.mysql.formula)
        if !FileManager.default.fileExists(atPath: dataDir + "/mysql") {
            try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            let r = await Shell.run(g.mysqld, ["--defaults-file=\(ConfigGenerator.mysqlConfFile)", "--initialize-insecure"])
            if !r.ok {
                errors[.mysql] = "Could not initialize the data directory:\n" + ProcessInfoHelper.tail(Paths.logs + "/mysql_error.log", lines: 10)
                return
            }
        }
        let r = await Shell.launchDaemon(g.mysqld, ["--defaults-file=\(ConfigGenerator.mysqlConfFile)", "--daemonize"],
                                         logFile: Paths.logs + "/mysql_start.log")
        let alive = r.ok ? await waitFor(pidFile: ConfigGenerator.mysqlPIDFile, alive: true, timeout: 30) : false
        if !alive {
            errors[.mysql] = "MySQL did not start.\n" + ProcessInfoHelper.tail(Paths.logs + "/mysql_error.log", lines: 10)
            return
        }
        lastMySQLConfValue = g.mysqlConfig()
        mysqlNeedsRestart = false
    }

    func mysql(_ sql: String) async -> ShellResult {
        await Shell.run(generator.mysqlBin("mysql"), ["--socket=\(Paths.mysqlSocket)", "-uroot", "-N", "-B", "-e", sql])
    }

    func ensureMySQLRunning() async -> Bool {
        if !isRunning(.mysql) { await start(.mysql) }
        return isRunning(.mysql)
    }

    static func isValidIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func randomPassword(_ n: Int = 20) -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    /// Creates a database plus a dedicated user with full access to it.
    @discardableResult
    func createDatabase(name: String, user: String? = nil, for siteID: UUID?) async -> String? {
        guard Self.isValidIdentifier(name) else { return "Use only letters, numbers and underscores (max 64)." }
        let user = String((user ?? name).prefix(32))
        guard Self.isValidIdentifier(user) else { return "Invalid user name." }
        if config.databases.contains(where: { $0.name == name }) { return "A database named \(name) already exists." }
        guard await ensureMySQLRunning() else { return errors[.mysql] ?? "MySQL is not running." }
        let password = Self.randomPassword()
        let m = config.mysql
        var sql = "CREATE DATABASE IF NOT EXISTS `\(name)` CHARACTER SET \(m.characterSet) COLLATE \(m.collation);"
        for host in ["localhost", "127.0.0.1"] {
            sql += "CREATE USER IF NOT EXISTS '\(user)'@'\(host)' IDENTIFIED BY '\(password)';"
            sql += "ALTER USER '\(user)'@'\(host)' IDENTIFIED BY '\(password)';"
            sql += "GRANT ALL PRIVILEGES ON `\(name)`.* TO '\(user)'@'\(host)';"
        }
        sql += "FLUSH PRIVILEGES;"
        let r = await mysql(sql)
        guard r.ok else { return r.output }
        update { $0.databases.append(DatabaseRecord(name: name, user: user, password: password, websiteID: siteID)) }
        return nil
    }

    @discardableResult
    func dropDatabase(_ record: DatabaseRecord) async -> String? {
        guard Self.isValidIdentifier(record.name), Self.isValidIdentifier(record.user) else { return "Invalid name." }
        guard await ensureMySQLRunning() else { return errors[.mysql] ?? "MySQL is not running." }
        let r = await mysql("DROP DATABASE IF EXISTS `\(record.name)`; DROP USER IF EXISTS '\(record.user)'@'localhost'; DROP USER IF EXISTS '\(record.user)'@'127.0.0.1';")
        guard r.ok else { return r.output }
        update { $0.databases.removeAll { $0.id == record.id } }
        return nil
    }

    func assign(_ record: DatabaseRecord, to siteID: UUID?) {
        update { c in if let i = c.databases.firstIndex(where: { $0.id == record.id }) { c.databases[i].websiteID = siteID } }
    }

    func serverDatabases() async -> [String] {
        guard isRunning(.mysql) else { return [] }
        let r = await mysql("SHOW DATABASES")
        let system: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]
        return r.output.split(separator: "\n").map(String.init).filter { !system.contains($0) }
    }
}

extension ConfigGenerator {
    var mysqld: String { mysqlBin("mysqld") }
}
