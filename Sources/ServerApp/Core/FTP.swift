// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// FTP server settings (Homebrew pure-ftpd).
struct FTPSettings: Codable, Hashable {
    var port = 21
    var allowNetwork = false         // accept other devices; off = this Mac only
    var passiveFrom = 30000
    var passiveTo = 30009
    var maxClients = 20
    var maxPerIP = 5
    var tls = false                  // allow FTPS (explicit TLS) with a self-signed certificate
    var requireTLS = false
    var certificateID: UUID? = nil   // a certificate from the Certificates page; nil = one Server generates
    var passiveAddress = ""          // address announced for passive mode (for NAT); empty = automatic

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 21
        allowNetwork = (try? c.decode(Bool.self, forKey: .allowNetwork)) ?? true   // settings saved before this option existed keep working as they did
        passiveFrom = (try? c.decode(Int.self, forKey: .passiveFrom)) ?? 30000
        passiveTo = (try? c.decode(Int.self, forKey: .passiveTo)) ?? 30009
        maxClients = (try? c.decode(Int.self, forKey: .maxClients)) ?? 20
        maxPerIP = (try? c.decode(Int.self, forKey: .maxPerIP)) ?? 5
        tls = (try? c.decode(Bool.self, forKey: .tls)) ?? false
        requireTLS = (try? c.decode(Bool.self, forKey: .requireTLS)) ?? false
        certificateID = try? c.decodeIfPresent(UUID.self, forKey: .certificateID)
        passiveAddress = (try? c.decode(String.self, forKey: .passiveAddress)) ?? ""
    }
}

/// pure-ftpd, started as root through the administrator prompt (Homebrew builds it without
/// non-root support). Virtual users live in a PureDB file; each is locked inside its folder
/// (chroot) and reads and writes files as this Mac user.
enum FTPServer {
    static let formula = "pure-ftpd"
    static var dir: String { Paths.conf + "/ftp" }
    static var passwdFile: String { dir + "/pureftpd.passwd" }
    static var pdbFile: String { dir + "/pureftpd.pdb" }
    static var certFile: String { Paths.ssl + "/ftp/pure-ftpd.pem" }
    static var storedCertFile: String { Paths.ssl + "/ftp/stored.pem" }
    /// The PEM pure-ftpd loads: the one Server generates, or a copy of a stored certificate.
    static func certPath(_ s: FTPSettings) -> String { s.certificateID != nil ? storedCertFile : certFile }
    static var pidFile: String { Paths.run + "/pure-ftpd.pid" }
    static var transferLog: String { Paths.logs + "/ftp_transfer.log" }
    static var startLog: String { Paths.logs + "/ftp_start.log" }

    static func binary(prefix: String) -> String { prefix + "/opt/pure-ftpd/sbin/pure-ftpd" }
    static func pw(prefix: String) -> String { prefix + "/opt/pure-ftpd/bin/pure-pw" }

    struct User: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let home: String
    }

    static func arguments(_ s: FTPSettings) -> [String] {
        var args = [
            "-B",                                   // run in the background
            "-S", "\(s.allowNetwork ? "" : "127.0.0.1"),\(s.port)",   // this port, on all addresses or this Mac only
            "-p", "\(s.passiveFrom):\(s.passiveTo)",
            "-g", pidFile,
            "-l", "puredb:\(pdbFile)",
            "-E",                                   // no anonymous logins
            "-A",                                   // lock every user inside their folder
            "-j",                                   // create missing home folders
            "-H",                                   // don't resolve client host names
            "-c", String(s.maxClients),
            "-C", String(s.maxPerIP),
            "-O", "clf:\(transferLog)",
        ]
        if !s.passiveAddress.isEmpty { args += ["-P", s.passiveAddress] }
        if s.tls { args += ["-Y", s.requireTLS ? "2" : "1", "-2", certPath(s)] }
        return args
    }

    /// Makes sure the user database exists (pure-ftpd refuses to start without it).
    static func prepare(prefix: String) async -> String? {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: passwdFile) {
            FileManager.default.createFile(atPath: passwdFile, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let r = await Shell.run(pw(prefix: prefix), ["mkdb", pdbFile, "-f", passwdFile])
        return r.ok ? nil : r.output
    }

    /// Self-signed certificate + key in one PEM file, as pure-ftpd expects.
    static func ensureCertificate(hostName: String) async -> String? {
        if FileManager.default.fileExists(atPath: certFile) { return nil }
        let folder = (certFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let key = folder + "/key.pem", cert = folder + "/cert.pem"
        let r = await Shell.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "825",
                                                     "-keyout", key, "-out", cert, "-subj", "/CN=\(hostName)"])
        guard r.ok, let k = try? String(contentsOfFile: key, encoding: .utf8),
              let c = try? String(contentsOfFile: cert, encoding: .utf8) else { return "Couldn't create the FTP certificate: \(r.output)" }
        do {
            try (c + k).write(toFile: certFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certFile)
        } catch { return error.localizedDescription }
        try? FileManager.default.removeItem(atPath: key)
        return nil
    }

    // MARK: Users

    /// Reads pureftpd.passwd directly (`pure-pw list` can't open it):
    /// name:hash:uid:gid:gecos:/home/./:…
    static func users(prefix: String) async -> [User] {
        guard let text = try? String(contentsOfFile: passwdFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6, !f[0].isEmpty else { return nil }
            var home = f[5]
            if home.hasSuffix("/./") { home.removeLast(3) }
            return User(name: f[0], home: home)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The root command that starts the server (it backgrounds itself).
    static func startCommand(_ s: FTPSettings, prefix: String) -> [String] {
        [binary(prefix: prefix)] + arguments(s) + [Privileged.quiet]
    }

    static func isValidUserName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 32
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    /// Adds a virtual user that is kept inside `home`. The password goes through stdin.
    static func addUser(_ name: String, password: String, home: String, prefix: String) async -> String? {
        if let e = await prepare(prefix: prefix) { return e }
        let r = await Shell.run(pw(prefix: prefix),
                                ["useradd", name, "-u", String(getuid()), "-g", String(getgid()), "-d", home,
                                 "-f", passwdFile, "-m", "-F", pdbFile],
                                input: password + "\n" + password + "\n")
        return r.ok ? nil : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setPassword(_ name: String, password: String, prefix: String) async -> String? {
        let r = await Shell.run(pw(prefix: prefix), ["passwd", name, "-f", passwdFile, "-m", "-F", pdbFile],
                                input: password + "\n" + password + "\n")
        return r.ok ? nil : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setHome(_ name: String, home: String, prefix: String) async -> String? {
        let r = await Shell.run(pw(prefix: prefix), ["usermod", name, "-d", home, "-f", passwdFile, "-m", "-F", pdbFile])
        return r.ok ? nil : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deleteUser(_ name: String, prefix: String) async -> String? {
        let r = await Shell.run(pw(prefix: prefix), ["userdel", name, "-f", passwdFile, "-m", "-F", pdbFile])
        return r.ok ? nil : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
