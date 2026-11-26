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
        if let skipped = config.websites.first(where: { $0.enabled && $0.configProblem != nil }), let problem = skipped.configProblem {
            let message = "\(skipped.name) isn't being served: \(problem)"
            if notice != message { flash(message) }
        }

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
        for site in config.websites where site.enabled && site.ssl.enabled && site.ssl.mode == .selfSigned && site.isConfigSafe {
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
        case .memcached: MemcachedServer.formula
        case .mail: MailServer.formula
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
        case .ai: config.ai.httpsEnabled ? [config.ai.port, config.ai.httpsPort] : [config.ai.port]
        case .redis: [config.redis.port]
        case .memcached: [config.memcached.port]
        case .mail: [config.mail.imapPort, config.mail.imapsPort] + MailServer.smtpPorts(config.mail)
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
        case .memcached:
            await startMemcached()
        case .mail:
            await startMail()
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
            let login = mysqlLogin(password: mysqlRootPassword)
            let r = await Shell.run(g.mysqlBin("mysqladmin"), login.args + ["--socket=\(Paths.mysqlSocket)", "-uroot", "shutdown"])
            login.cleanup()
            if !r.ok, let pid = ProcessInfoHelper.livePID(pidFile: ConfigGenerator.mysqlPIDFile) { kill(pid, SIGTERM) }
            _ = await waitFor(pidFile: ConfigGenerator.mysqlPIDFile, alive: false, timeout: 30)
            mysqlNeedsRestart = false
        case .mail:
            await stopMail()
        case .memcached:
            await stopMemcached()
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
            if kind == .ftp { ftpNeedsRestart = true } else if kind == .mail { mailNeedsRestart = true } else { await restart(kind) }
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
        if config.ai.httpsEnabled {
            let tls = await prepareAIHTTPS()
            if let e = tls.error { errors[.ai] = e; return }
            env["SERVER_AI_TLS_PASS"] = tls.passphrase
        }
        defer { try? FileManager.default.removeItem(atPath: AIServer.tlsBundle) }
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
        if config.ftp.tls {
            if let id = config.ftp.certificateID {
                // pure-ftpd wants the certificate chain and the key in one file.
                let files = certificateFiles(id)
                guard let chain = try? String(contentsOfFile: files.cert, encoding: .utf8),
                      let key = try? String(contentsOfFile: files.key, encoding: .utf8) else {
                    errors[.ftp] = String(localized: "The certificate chosen for FTP is missing. Pick another one in FTP › Settings."); return
                }
                try? FileManager.default.createDirectory(atPath: (FTPServer.storedCertFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: FTPServer.storedCertFile, contents: Data((chain + "\n" + key).utf8), attributes: [.posixPermissions: 0o600])
            } else if let e = await FTPServer.ensureCertificate(hostName: SystemStatus.shared.hostName) {
                errors[.ftp] = e; return
            }
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

    /// Runs SQL as root. The SQL goes in through stdin and the password through a private option
    /// file, so neither shows up in the process list. `password` nil means the saved root password.
    func mysql(_ sql: String, password: String? = nil, socket: String = Paths.mysqlSocket) async -> ShellResult {
        let login = mysqlLogin(password: password ?? mysqlRootPassword)
        defer { login.cleanup() }
        return await Shell.run(generator.mysqlBin("mysql"), login.args + ["--socket=\(socket)", "-uroot", "-N", "-B"], input: sql)
    }

    /// Option-file arguments carrying the password (none when it's empty), plus a cleanup to call afterwards.
    func mysqlLogin(password: String) -> (args: [String], cleanup: () -> Void) {
        guard !password.isEmpty else { return ([], {}) }
        let file = Paths.run + "/mysql-login-\(UUID().uuidString).cnf"
        let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        FileManager.default.createFile(atPath: file, contents: Data("[client]\npassword=\"\(escaped)\"\n".utf8), attributes: [.posixPermissions: 0o600])
        return (["--defaults-extra-file=\(file)"], { try? FileManager.default.removeItem(atPath: file) })
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

// MARK: - MySQL root password

extension AppState {
    /// The saved root password for the MySQL version in use ("" when it has none).
    var mysqlRootPassword: String { config.mysqlRootPasswords[config.mysql.formula] ?? "" }

    /// A SQL string literal.
    static func sqlString(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    static func mysqlPasswordProblem(_ p: String) -> String? {
        if p.contains("\n") || p.contains("\r") || p.contains("\0") { return String(localized: "The password can't contain line breaks.") }
        if p.count > 128 { return String(localized: "Use at most 128 characters.") }
        return nil
    }

    private func saveMySQLRootPassword(_ password: String) {
        let formula = config.mysql.formula
        update { $0.mysqlRootPasswords[formula] = password.isEmpty ? nil : password }
    }

    /// Changes the root password while MySQL runs, using the saved one to log in.
    @discardableResult
    func changeMySQLRootPassword(to new: String) async -> String? {
        if let problem = Self.mysqlPasswordProblem(new) { return problem }
        guard await ensureMySQLRunning() else { return errors[.mysql] ?? "MySQL is not running." }
        let r = await mysql("ALTER USER 'root'@'localhost' IDENTIFIED BY \(Self.sqlString(new)); FLUSH PRIVILEGES;")
        guard r.ok else {
            if r.output.contains("Access denied") {
                return String(localized: "MySQL didn't accept the password Server has saved for root. Use Reset Password instead.")
            }
            return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        saveMySQLRootPassword(new)
        return nil
    }

    /// Sets a new root password without knowing the old one: MySQL restarts briefly with privilege
    /// checks off, reachable only through a private socket on this Mac, then restarts normally.
    @discardableResult
    func resetMySQLRootPassword(to new: String) async -> String? {
        if let problem = Self.mysqlPasswordProblem(new) { return problem }
        guard !transitional.contains(.mysql) else { return String(localized: "MySQL is busy. Try again in a moment.") }
        let g = generator
        guard FileManager.default.fileExists(atPath: Paths.mysqlDataDir(config.mysql.formula) + "/mysql") else {
            return String(localized: "MySQL hasn't been set up yet. Start it once first.")
        }
        let wasRunning = isRunning(.mysql)
        if wasRunning { await stop(.mysql) }
        if let pid = ProcessInfoHelper.livePID(pidFile: ConfigGenerator.mysqlPIDFile) {
            kill(pid, SIGTERM)
            _ = await waitFor(pidFile: ConfigGenerator.mysqlPIDFile, alive: false, timeout: 30)
        }

        transitional.insert(.mysql); states[.mysql] = .starting
        // The recovery server skips the privilege tables, so keep its socket where only you can reach it.
        let dir = Paths.run + "/reset-" + String(UUID().uuidString.prefix(8))
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = dir + "/mysql.sock"
        var error: String?
        let r = await Shell.launchDaemon(g.mysqld, ["--defaults-file=\(ConfigGenerator.mysqlConfFile)", "--skip-grant-tables",
                                                     "--skip-networking", "--socket=\(socket)", "--daemonize"],
                                         logFile: Paths.logs + "/mysql_start.log")
        if r.ok, await waitFor(pidFile: ConfigGenerator.mysqlPIDFile, alive: true, timeout: 30) {
            let q = await mysql("FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY \(Self.sqlString(new)); FLUSH PRIVILEGES;",
                                password: "", socket: socket)
            if !q.ok { error = q.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let pid = ProcessInfoHelper.livePID(pidFile: ConfigGenerator.mysqlPIDFile) { kill(pid, SIGTERM) }
            _ = await waitFor(pidFile: ConfigGenerator.mysqlPIDFile, alive: false, timeout: 30)
        } else {
            error = String(localized: "MySQL didn't start in recovery mode.") + "\n" + ProcessInfoHelper.tail(Paths.logs + "/mysql_error.log", lines: 8)
        }
        try? FileManager.default.removeItem(atPath: dir)
        transitional.remove(.mysql); refreshStates()
        if error == nil { saveMySQLRootPassword(new) }
        if wasRunning { await start(.mysql) }
        return error
    }
}
