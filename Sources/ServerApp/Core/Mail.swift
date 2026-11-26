// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import Security

// MARK: - Settings and data

/// Mail server settings: Postfix (macOS's built-in one) for SMTP, Dovecot (Homebrew) for IMAP.
struct MailSettings: Codable, Hashable {
    var hostName = ""                    // empty = this Mac's host name
    var smtpPort = 25
    var submissionPort = 587
    var smtpsPort = 465
    var imapPort = 143
    var imapsPort = 993
    var allowNetwork = false             // accept connections from other devices
    var requireEncryption = true         // sign-in only over TLS
    var certificateID: UUID? = nil       // a certificate from the Certificates page; nil = one Server generates
    var maxMessageMB = 50
    var relayHost = ""                   // e.g. smtp.provider.com:587 (empty = deliver directly)
    var relayUser = ""
    var relayPassword = ""
    var sandbox = false                  // catch all outgoing mail with Mailpit instead of the real SMTP server
    var sandboxWebPort = 8025

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostName = (try? c.decode(String.self, forKey: .hostName)) ?? ""
        smtpPort = (try? c.decode(Int.self, forKey: .smtpPort)) ?? 25
        submissionPort = (try? c.decode(Int.self, forKey: .submissionPort)) ?? 587
        smtpsPort = (try? c.decode(Int.self, forKey: .smtpsPort)) ?? 465
        imapPort = (try? c.decode(Int.self, forKey: .imapPort)) ?? 143
        imapsPort = (try? c.decode(Int.self, forKey: .imapsPort)) ?? 993
        allowNetwork = (try? c.decode(Bool.self, forKey: .allowNetwork)) ?? false
        requireEncryption = (try? c.decode(Bool.self, forKey: .requireEncryption)) ?? true
        certificateID = try? c.decodeIfPresent(UUID.self, forKey: .certificateID)
        maxMessageMB = (try? c.decode(Int.self, forKey: .maxMessageMB)) ?? 50
        relayHost = (try? c.decode(String.self, forKey: .relayHost)) ?? ""
        relayUser = (try? c.decode(String.self, forKey: .relayUser)) ?? ""
        relayPassword = (try? c.decode(String.self, forKey: .relayPassword)) ?? ""
        sandbox = (try? c.decode(Bool.self, forKey: .sandbox)) ?? false
        sandboxWebPort = (try? c.decode(Int.self, forKey: .sandboxWebPort)) ?? 8025
    }
}

struct MailDomain: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

struct MailAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var user: String                     // the part before the @
    var domain: String
    var passwordHash: String             // {SSHA512}…
    var address: String { "\(user)@\(domain)" }
}

struct MailAlias: Codable, Identifiable, Hashable {
    var id = UUID()
    var source: String                   // alias@domain, or @domain for everything on a domain
    var destination: String              // one or more addresses, separated by commas
}

// MARK: - Files and configuration

@MainActor
enum MailServer {
    static let formula = "dovecot"
    static let sandboxFormula = "mailpit"
    static func dovecot(prefix: String) -> String { prefix + "/opt/dovecot/sbin/dovecot" }
    static func mailpit(prefix: String) -> String { prefix + "/opt/mailpit/bin/mailpit" }
    static let postfix = "/usr/sbin/postfix"

    static var dir: String { Paths.support + "/mail" }
    static var vhosts: String { dir + "/vhosts" }
    static var dovecotConf: String { dir + "/dovecot.conf" }
    static var usersFile: String { dir + "/users" }
    static var mapsDir: String { "/Users/Shared/ServerMail" }   // Postfix reads these as its own user, so they can't live in your Library folder
    static var vmailboxFile: String { mapsDir + "/vmailbox" }
    static var valiasFile: String { mapsDir + "/valias" }
    static var stagedPostfix: String { dir + "/postfix" }
    static var saslFile: String { stagedPostfix + "/sasl_passwd" }
    static var dovecotBase: String { Paths.run + "/dovecot" }
    static var dovecotPID: String { dovecotBase + "/master.pid" }
    static var authSocket: String { queueDir + "/private/dovecot-auth" }
    static var mailpitPID: String { Paths.run + "/mailpit.pid" }
    static var mailpitDB: String { dir + "/mailpit.db" }
    static var logFile: String { Paths.logs + "/mail_dovecot.log" }
    static var mailpitLog: String { Paths.logs + "/mail_sandbox.log" }
    static var startLog: String { Paths.logs + "/mail_start.log" }

    // Postfix is installed under root-owned folders, as it insists on.
    static let installedPostfix = "/private/etc/server-postfix"
    static let queueDir = "/private/var/spool/server-postfix"
    static let dataDir = "/private/var/lib/server-postfix"
    static var postfixPID: String { queueDir + "/pid/master.pid" }

    static func hostName(_ s: MailSettings) -> String { s.hostName.isEmpty ? SystemStatus.shared.hostName : s.hostName }

    static func isValidDomain(_ s: String) -> Bool {
        guard s.count <= 253, s.contains("."), !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    static func isValidLocalPart(_ s: String) -> Bool {
        // No leading or trailing dot: "." and ".." would be folder names, not mailboxes.
        !s.isEmpty && s.count <= 64 && !s.hasPrefix(".") && !s.hasSuffix(".")
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-+".contains($0)) }
    }

    static func isValidAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 && isValidLocalPart(parts[0]) && isValidDomain(parts[1])
    }

    /// The SMTP ports Server listens on (only the one SMTP port in sandbox mode).
    static func smtpPorts(_ s: MailSettings) -> [Int] { s.sandbox ? [s.smtpPort] : [s.smtpPort, s.submissionPort, s.smtpsPort] }

    // MARK: Dovecot

    static func dovecotConfig(_ s: MailSettings, cert: String, key: String) -> String {
        let uid = getuid(), gid = getgid()
        return """
        # Generated by Server. Do not edit: changes are overwritten.
        dovecot_config_version = 2.4.5
        dovecot_storage_version = 2.4.5
        base_dir = \(dovecotBase)
        state_dir = \(dir)/dovecot-state
        log_path = \(logFile)
        listen = \(s.allowNetwork ? "*" : "127.0.0.1")
        protocols {
          imap = yes
        }
        default_internal_user = _dovecot
        default_login_user = _dovecot
        default_internal_group = mail
        default_vsz_limit = unlimited
        mail_driver = maildir
        mail_home = \(vhosts)/%{user | domain}/%{user | username}
        mail_path = ~/Maildir
        mail_uid = \(uid)
        mail_gid = \(gid)
        first_valid_uid = \(uid)
        last_valid_uid = \(uid)
        namespace inbox {
          inbox = yes
          separator = /
        }
        auth_mechanisms = plain login
        auth_allow_cleartext = \(s.requireEncryption ? "no" : "yes")
        passdb passwd-file {
          passwd_file_path = \(usersFile)
        }
        userdb static {
        }
        service imap-login {
          inet_listener imap {
            port = \(s.imapPort)
          }
          inet_listener imaps {
            port = \(s.imapsPort)
            ssl = yes
          }
        }
        service auth {
          user = root
        \(s.sandbox ? "" : """
          unix_listener \(authSocket) {
            mode = 0660
            user = _postfix
            group = _postfix
          }
        """)
        }
        ssl = yes
        ssl_server {
          cert_file = \(cert)
          key_file = \(key)
        }

        """
    }

    /// passwd-file: address:{scheme}hash
    static func usersContent(_ accounts: [MailAccount]) -> String {
        accounts.map { "\($0.address):\($0.passwordHash)" }.joined(separator: "\n") + "\n"
    }

    static func vmailboxContent(_ accounts: [MailAccount]) -> String {
        accounts.map { "\($0.address) \($0.domain)/\($0.user)/Maildir/" }.joined(separator: "\n") + "\n"
    }

    static func valiasContent(_ aliases: [MailAlias]) -> String {
        aliases.map { "\($0.source) \($0.destination)" }.joined(separator: "\n") + "\n"
    }

    // MARK: Postfix

    static func postfixMain(_ s: MailSettings, domains: [MailDomain], cert: String, key: String) -> String {
        let uid = getuid(), gid = getgid()
        var c = """
        # Generated by Server. Do not edit: changes are overwritten.
        config_directory = \(installedPostfix)
        queue_directory = \(queueDir)
        data_directory = \(dataDir)
        command_directory = /usr/sbin
        daemon_directory = /usr/libexec/postfix
        mail_owner = _postfix
        setgid_group = _postdrop
        myhostname = \(hostName(s))
        myorigin = $myhostname
        inet_interfaces = \(s.allowNetwork ? "all" : "loopback-only")
        inet_protocols = ipv4
        mydestination =
        local_recipient_maps =
        mynetworks = 127.0.0.0/8
        message_size_limit = \(max(1, s.maxMessageMB) * 1_048_576)
        mailbox_size_limit = 0
        virtual_mailbox_limit = 0
        smtpd_banner = $myhostname ESMTP
        virtual_mailbox_domains = \(domains.map(\.name).joined(separator: ", "))
        virtual_mailbox_base = \(vhosts)
        virtual_mailbox_maps = texthash:\(vmailboxFile)
        virtual_alias_maps = texthash:\(valiasFile)
        virtual_uid_maps = static:\(uid)
        virtual_gid_maps = static:\(gid)
        virtual_minimum_uid = \(uid)
        virtual_transport = virtual
        smtpd_tls_cert_file = \(cert)
        smtpd_tls_key_file = \(key)
        smtpd_tls_security_level = may
        smtp_tls_security_level = may
        smtpd_sasl_type = dovecot
        smtpd_sasl_path = private/dovecot-auth
        smtpd_sasl_auth_enable = no
        smtpd_sasl_security_options = noanonymous
        smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination

        """
        if !s.relayHost.isEmpty {
            let target = s.relayHost.hasPrefix("[") ? s.relayHost : "[\(s.relayHost.split(separator: ":").first.map(String.init) ?? s.relayHost)]"
                + (s.relayHost.contains(":") ? ":" + (s.relayHost.split(separator: ":").last.map(String.init) ?? "587") : ":587")
            c += "relayhost = \(target)\n"
            if !s.relayUser.isEmpty {
                c += "smtp_sasl_auth_enable = yes\nsmtp_sasl_password_maps = texthash:\(installedPostfix)/sasl_passwd\nsmtp_sasl_security_options = noanonymous\nsmtp_tls_security_level = encrypt\n"
            }
        }
        return c
    }

    static func postfixMaster(_ s: MailSettings) -> String {
        """
        # Generated by Server. Do not edit: changes are overwritten.
        # service type private unpriv chroot wakeup maxproc command
        \(s.smtpPort)      inet  n       -       n       -       -       smtpd
        \(s.submissionPort)      inet  n       -       n       -       -       smtpd
          -o syslog_name=postfix/submission
          -o smtpd_tls_security_level=encrypt
          -o smtpd_sasl_auth_enable=yes
          -o smtpd_tls_auth_only=yes
          -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
        \(s.smtpsPort)      inet  n       -       n       -       -       smtpd
          -o syslog_name=postfix/smtps
          -o smtpd_tls_wrappermode=yes
          -o smtpd_sasl_auth_enable=yes
          -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
        pickup    fifo  n       -       n       60      1       pickup
        cleanup   unix  n       -       n       -       0       cleanup
        qmgr      fifo  n       -       n       300     1       qmgr
        tlsmgr    unix  -       -       n       1000?   1       tlsmgr
        rewrite   unix  -       -       n       -       -       trivial-rewrite
        bounce    unix  -       -       n       -       0       bounce
        defer     unix  -       -       n       -       0       bounce
        trace     unix  -       -       n       -       0       bounce
        verify    unix  -       -       n       -       1       verify
        flush     unix  n       -       n       1000?   0       flush
        proxymap  unix  -       -       n       -       -       proxymap
        proxywrite unix -       -       n       -       1       proxymap
        smtp      unix  -       -       n       -       -       smtp
        relay     unix  -       -       n       -       -       smtp
        showq     unix  n       -       n       -       -       showq
        error     unix  -       -       n       -       -       error
        retry     unix  -       -       n       -       -       error
        discard   unix  -       -       n       -       -       discard
        local     unix  -       n       n       -       -       local
        virtual   unix  -       n       n       -       -       virtual
        lmtp      unix  -       -       n       -       -       lmtp
        anvil     unix  -       -       n       -       1       anvil
        scache    unix  -       -       n       -       1       scache

        """
    }

    static func saslContent(_ s: MailSettings) -> String {
        guard !s.relayHost.isEmpty, !s.relayUser.isEmpty else { return "" }
        let host = s.relayHost.hasPrefix("[") ? s.relayHost : "[\(s.relayHost.split(separator: ":").first.map(String.init) ?? s.relayHost)]"
            + (s.relayHost.contains(":") ? ":" + (s.relayHost.split(separator: ":").last.map(String.init) ?? "587") : ":587")
        return "\(host) \(s.relayUser):\(s.relayPassword)\n"
    }

    // MARK: Commands (run as root through one administrator prompt)

    /// The administrator prompt starts programs with SIGTERM blocked and ignored, which would make a daemon impossible to stop.
    static func unmasked(_ argv: [String]) -> [String] {
        ["/usr/bin/perl", "-MPOSIX", "-e", "sigprocmask(SIG_SETMASK, POSIX::SigSet->new); $SIG{TERM} = 'DEFAULT'; $SIG{INT} = 'DEFAULT'; $SIG{HUP} = 'DEFAULT'; exec @ARGV or die $!;", "--"] + argv
    }

    /// Installs the Postfix files where Postfix wants them and starts (or reloads) it.
    static func postfixStartCommands(running: Bool) -> [[String]] {
        if running { return [[postfix, "-c", installedPostfix, "reload"] + [Privileged.quiet]] }
        return [
            ["/bin/rm", "-rf", installedPostfix],
            ["/bin/mkdir", "-p", installedPostfix, queueDir, dataDir],
            ["/usr/sbin/chown", "_postfix", dataDir],
            ["/bin/chmod", "700", dataDir],
            ["/usr/bin/ditto", stagedPostfix, installedPostfix],
            ["/usr/sbin/chown", "-R", "root:wheel", installedPostfix],
            ["/bin/chmod", "-R", "go-w", installedPostfix],
            [postfix, "-c", installedPostfix, "check"],
            unmasked([postfix, "-c", installedPostfix, "start"]) + [Privileged.quiet],
            // So Server can read the process id without a password.
            ["/bin/chmod", "644", postfixPID],
        ]
    }

    static func dovecotStartCommands(prefix: String) -> [[String]] {
        [unmasked([dovecot(prefix: prefix), "-c", dovecotConf]) + [Privileged.quiet], ["/bin/chmod", "644", dovecotPID]]
    }
}

// MARK: - App integration

extension AppState {
    var mailPostfixRunning: Bool { ProcessInfoHelper.livePID(pidFile: MailServer.postfixPID) != nil }
    var mailSandboxRunning: Bool { ProcessInfoHelper.livePID(pidFile: MailServer.mailpitPID) != nil }

    /// Certificate and key for mail: a stored one, or a self-signed one for the mail host name.
    private func mailCertificate() async -> (cert: String, key: String, error: String?) {
        if let id = config.mail.certificateID, storedCertificate(id) != nil {
            let f = certificateFiles(id); return (f.cert, f.key, nil)
        }
        let folder = Paths.ssl + "/mail"
        let host = MailServer.hostName(config.mail)
        let names = ([host] + config.mailDomains.map { "mail." + $0.name } + config.mailDomains.map(\.name))
            .filter { Self.isValidCertificateName($0) }
        let joined = names.joined(separator: " ")
        let marker = folder + "/names.txt"
        var fresh = ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "") == joined
            && FileManager.default.fileExists(atPath: folder + "/cert.pem")
        if fresh { fresh = (await Shell.run("/usr/bin/openssl", ["x509", "-in", folder + "/cert.pem", "-noout", "-checkend", "86400"])).ok }
        if !fresh {
            if let e = await generateSelfSigned(names: names.isEmpty ? [host] : names, days: 825, folder: folder) {
                return ("", "", String(localized: "Couldn't create the mail certificate: \(e)"))
            }
            try? Paths.write(joined, to: marker)
        }
        return (folder + "/cert.pem", folder + "/key.pem", nil)
    }

    /// Writes every mail file. Account and alias changes are picked up without restarting.
    @discardableResult
    func writeMailFiles() async -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: MailServer.vhosts, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: MailServer.stagedPostfix, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: MailServer.mapsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        // Dovecot (root) writes its log here; making the file first keeps it readable for the Logs page.
        if !fm.fileExists(atPath: MailServer.logFile) { fm.createFile(atPath: MailServer.logFile, contents: nil, attributes: [.posixPermissions: 0o644]) }
        let cert = await mailCertificate()
        if let e = cert.error { return e }
        // Files Postfix expects next to its config.
        for name in ["postfix-files", "dynamicmaps.cf"] where fm.fileExists(atPath: "/private/etc/postfix/" + name) {
            let target = MailServer.stagedPostfix + "/" + name
            if !fm.fileExists(atPath: target) { try? fm.copyItem(atPath: "/private/etc/postfix/" + name, toPath: target) }
        }
        let s = config.mail
        do {
            try Paths.write(MailServer.dovecotConfig(s, cert: cert.cert, key: cert.key), to: MailServer.dovecotConf)
            try Paths.write(MailServer.postfixMain(s, domains: config.mailDomains, cert: cert.cert, key: cert.key), to: MailServer.stagedPostfix + "/main.cf")
            try Paths.write(MailServer.postfixMaster(s), to: MailServer.stagedPostfix + "/master.cf")
            for (text, path) in [(MailServer.usersContent(config.mailAccounts), MailServer.usersFile),
                                 (MailServer.vmailboxContent(config.mailAccounts), MailServer.vmailboxFile),
                                 (MailServer.valiasContent(config.mailAliases), MailServer.valiasFile),
                                 (MailServer.saslContent(s), MailServer.saslFile)] {
                try Paths.write(text, to: path)
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            }
            // The password files stay readable only by you (root reads them anyway).
            for path in [MailServer.usersFile, MailServer.saslFile] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
            // Postfix reads these maps as its own user.
            for path in [MailServer.vmailboxFile, MailServer.valiasFile] { try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        } catch { return error.localizedDescription }
        return nil
    }

    // MARK: Start / stop

    func startMail() async {
        let prefix = brew.prefix
        if config.mail.sandbox, !brew.isInstalled(MailServer.sandboxFormula) {
            guard await brew.ensureInstalled(MailServer.sandboxFormula) else {
                errors[.mail] = String(localized: "Couldn't install Mailpit with Homebrew. See Logs › Homebrew Activity."); return
            }
        }
        if let e = await writeMailFiles() { errors[.mail] = e; return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: MailServer.dovecotBase, withIntermediateDirectories: true)

        if config.mail.sandbox { if let e = await startSandbox(prefix: prefix) { errors[.mail] = e; return } }

        var commands: [[String]] = []
        if !config.mail.sandbox { commands += MailServer.postfixStartCommands(running: mailPostfixRunning) }
        if ProcessInfoHelper.livePID(pidFile: MailServer.dovecotPID) == nil { commands += MailServer.dovecotStartCommands(prefix: prefix) }
        if !commands.isEmpty {
            switch await Privileged.execute(commands) {
            case .cancelled: errors[.mail] = String(localized: "Mail needs an administrator password to start."); stopSandboxNow(); return
            case .failed(let m): errors[.mail] = String(localized: "The mail server did not start:") + "\n" + m; stopSandboxNow(); return
            case .success: break
            }
        }
        let started = await waitForMail(timeout: 15)
        if !started {
            errors[.mail] = String(localized: "The mail server did not start.") + "\n" + ProcessInfoHelper.tail(MailServer.logFile, lines: 8)
            return
        }
        mailNeedsRestart = false
    }

    private func waitForMail(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let imap = ProcessInfoHelper.livePID(pidFile: MailServer.dovecotPID) != nil
            let smtp = config.mail.sandbox ? mailSandboxRunning : mailPostfixRunning
            if imap && smtp { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    func stopMail() async {
        var commands: [[String]] = []
        if mailPostfixRunning { commands.append([MailServer.postfix, "-c", MailServer.installedPostfix, "stop", Privileged.quiet]) }
        if ProcessInfoHelper.livePID(pidFile: MailServer.dovecotPID) != nil {
            commands.append([MailServer.dovecot(prefix: brew.prefix), "-c", MailServer.dovecotConf, "stop", Privileged.quiet])
        }
        stopSandboxNow()
        if !commands.isEmpty {
            switch await Privileged.execute(commands) {
            case .cancelled: errors[.mail] = String(localized: "Mail needs an administrator password to stop."); return
            case .failed(let m): errors[.mail] = m; return
            case .success: break
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, ProcessInfoHelper.livePID(pidFile: MailServer.dovecotPID) != nil || mailPostfixRunning {
            try? await Task.sleep(for: .milliseconds(300))
        }
        mailNeedsRestart = false
    }

    /// Mailpit takes over the SMTP port. It runs as you: macOS lets any program listen on a low port on all addresses.
    private func startSandbox(prefix: String) async -> String? {
        if mailSandboxRunning { return nil }
        let s = config.mail
        // The SMTP port may only just have been freed by Postfix, so a failed start is tried again a few times.
        for attempt in 1...4 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: MailServer.mailpit(prefix: prefix))
            process.arguments = ["--smtp", (s.allowNetwork || s.smtpPort < 1024 ? "0.0.0.0" : "127.0.0.1") + ":\(s.smtpPort)",
                                 "--listen", "127.0.0.1:\(s.sandboxWebPort)",
                                 "--database", MailServer.mailpitDB,
                                 "--smtp-auth-accept-any", "--smtp-auth-allow-insecure"]
            process.standardInput = FileHandle.nullDevice
            FileManager.default.createFile(atPath: MailServer.mailpitLog, contents: nil)
            let log = FileHandle(forWritingAtPath: MailServer.mailpitLog)
            process.standardOutput = log ?? FileHandle.nullDevice
            process.standardError = log ?? FileHandle.nullDevice
            do { try process.run() } catch { return String(localized: "Couldn't start Mailpit: \(error.localizedDescription)") }
            try? await Task.sleep(for: .milliseconds(1200))
            if process.isRunning {
                try? String(process.processIdentifier).write(toFile: MailServer.mailpitPID, atomically: true, encoding: .utf8)
                return nil
            }
            if attempt == 4 { return String(localized: "Mailpit did not start.") + "\n" + ProcessInfoHelper.tail(MailServer.mailpitLog, lines: 4) }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        return nil
    }

    func stopSandboxNow() {
        if let pid = ProcessInfoHelper.livePID(pidFile: MailServer.mailpitPID) { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(atPath: MailServer.mailpitPID)
    }

    // MARK: Domains, accounts, aliases

    @discardableResult
    func addMailDomain(_ name: String) async -> String? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard MailServer.isValidDomain(n) else { return String(localized: "Enter a domain name such as example.com.") }
        guard !config.mailDomains.contains(where: { $0.name == n }) else { return String(localized: "That domain is already added.") }
        update { $0.mailDomains.append(MailDomain(name: n)) }
        await refreshMailFiles()
        return nil
    }

    func removeMailDomain(_ id: UUID) async {
        guard let d = config.mailDomains.first(where: { $0.id == id }) else { return }
        update { c in
            c.mailDomains.removeAll { $0.id == id }
            c.mailAccounts.removeAll { $0.domain == d.name }
            c.mailAliases.removeAll { $0.source.hasSuffix("@" + d.name) }
        }
        await refreshMailFiles()
    }

    /// Salted SSHA512 hash of a password (Dovecot's format; macOS's crypt() has no SHA512-CRYPT).
    func mailPasswordHash(_ password: String) async -> String? {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { return nil }
        let digest = SHA512.hash(data: Data(password.utf8) + Data(salt))
        return "{SSHA512}" + (Data(digest) + Data(salt)).base64EncodedString()
    }

    @discardableResult
    func addMailAccount(user: String, domain: String, password: String) async -> String? {
        let u = user.trimmingCharacters(in: .whitespaces).lowercased()
        guard MailServer.isValidLocalPart(u) else { return String(localized: "Use letters, numbers and . _ - + for the name.") }
        guard config.mailDomains.contains(where: { $0.name == domain }) else { return String(localized: "Add the domain first.") }
        guard !config.mailAccounts.contains(where: { $0.user == u && $0.domain == domain }) else { return String(localized: "That mailbox already exists.") }
        if let problem = Self.mailPasswordProblem(password) { return problem }
        guard let hash = await mailPasswordHash(password) else { return String(localized: "Couldn't protect the password.") }
        update { $0.mailAccounts.append(MailAccount(user: u, domain: domain, passwordHash: hash)) }
        let folder = "\(MailServer.vhosts)/\(domain)/\(u)/Maildir"
        for sub in ["cur", "new", "tmp"] { try? FileManager.default.createDirectory(atPath: folder + "/" + sub, withIntermediateDirectories: true) }
        await refreshMailFiles()
        return nil
    }

    @discardableResult
    func changeMailPassword(_ id: UUID, to password: String) async -> String? {
        if let problem = Self.mailPasswordProblem(password) { return problem }
        guard let hash = await mailPasswordHash(password) else { return String(localized: "Couldn't protect the password.") }
        update { c in if let i = c.mailAccounts.firstIndex(where: { $0.id == id }) { c.mailAccounts[i].passwordHash = hash } }
        await refreshMailFiles()
        return nil
    }

    static func mailPasswordProblem(_ p: String) -> String? {
        if p.count < 8 { return String(localized: "Use at least 8 characters.") }
        if p.contains("\n") || p.contains("\r") || p.contains(":") { return String(localized: "The password can't contain colons or line breaks.") }
        return nil
    }

    func removeMailAccount(_ id: UUID, deleteMail: Bool) async {
        guard let a = config.mailAccounts.first(where: { $0.id == id }) else { return }
        update { $0.mailAccounts.removeAll { $0.id == id } }
        if deleteMail, MailServer.isValidDomain(a.domain), MailServer.isValidLocalPart(a.user) {
            // Only ever a mailbox folder two levels under the mail store, never the store itself.
            let box = "\(MailServer.vhosts)/\(a.domain)/\(a.user)"
            if (box as NSString).standardizingPath.hasPrefix(MailServer.vhosts + "/\(a.domain)/") {
                try? FileManager.default.removeItem(atPath: box)
            }
        }
        await refreshMailFiles()
    }

    @discardableResult
    func addMailAlias(source: String, destination: String) async -> String? {
        let s = source.trimmingCharacters(in: .whitespaces).lowercased()
        let targets = destination.components(separatedBy: CharacterSet(charactersIn: ", \n")).filter { !$0.isEmpty }
        let sourceDomain = s.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard (s.hasPrefix("@") ? MailServer.isValidDomain(sourceDomain) : MailServer.isValidAddress(s)) else {
            return String(localized: "Enter an address such as info@example.com, or @example.com for everything.")
        }
        guard config.mailDomains.contains(where: { $0.name == sourceDomain }) else { return String(localized: "Add the domain first.") }
        guard !targets.isEmpty, targets.allSatisfy(MailServer.isValidAddress) else { return String(localized: "Enter one or more destination addresses.") }
        guard !config.mailAliases.contains(where: { $0.source == s }) else { return String(localized: "That alias already exists.") }
        update { $0.mailAliases.append(MailAlias(source: s, destination: targets.joined(separator: ", "))) }
        await refreshMailFiles()
        return nil
    }

    func removeMailAlias(_ id: UUID) async {
        update { $0.mailAliases.removeAll { $0.id == id } }
        await refreshMailFiles()
    }

    /// Rewrites the files after a change. Settings (ports, host name, sandbox…) need a restart; accounts don't.
    func refreshMailFiles() async {
        await writeMailFiles()
    }
}
