// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// A certificate kept in Server's store, ready to use for websites and other services.
struct StoredCertificate: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case selfSigned, imported }
    var id = UUID()
    var name: String
    var source: Source
    var created = Date()
}

/// What `openssl x509 -text` says about a certificate.
struct CertificateInfo: Equatable {
    var commonName = ""
    var subject = ""
    var issuer = ""
    var names: [String] = []
    var notBefore: Date?
    var notAfter: Date?
    var serial = ""
    var fingerprint = ""
    var keyDescription = ""
    var isSelfIssued = false

    var daysLeft: Int? {
        notAfter.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 }
    }
    var isExpired: Bool { notAfter.map { $0 < Date() } ?? false }
    var expiresSoon: Bool { !isExpired && (daysLeft ?? 99) <= 30 }

    static func parse(_ text: String) -> CertificateInfo {
        var info = CertificateInfo()
        let lines = text.components(separatedBy: "\n")
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "MMM d HH:mm:ss yyyy"
        func date(_ s: String) -> Date? {
            let parts = s.split(separator: " ").filter { !$0.isEmpty }
            guard parts.count >= 4 else { return nil }
            return parser.date(from: parts[0..<4].joined(separator: " "))
        }
        var inSAN = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inSAN {
                inSAN = false
                info.names = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { item in
                    if item.hasPrefix("DNS:") { return String(item.dropFirst(4)) }
                    if item.hasPrefix("IP Address:") { return String(item.dropFirst(11)) }
                    return nil
                }
                continue
            }
            if line.hasPrefix("Subject:") && info.subject.isEmpty { info.subject = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("Issuer:") { info.issuer = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("Not Before:") { info.notBefore = date(String(line.dropFirst(11))) }
            else if line.hasPrefix("Not After") , let colon = line.firstIndex(of: ":") { info.notAfter = date(String(line[line.index(after: colon)...])) }
            else if line.hasPrefix("X509v3 Subject Alternative Name") { inSAN = true }
            else if line.hasPrefix("Public-Key:") { info.keyDescription = line.replacingOccurrences(of: "Public-Key: ", with: "") }
            else if line.lowercased().hasSuffix("fingerprint=") || line.lowercased().contains("fingerprint=") {
                info.fingerprint = String(line.split(separator: "=", maxSplits: 1).last ?? "")
            } else if line.lowercased().hasPrefix("serial=") { info.serial = String(line.dropFirst(7)) }
            _ = i
        }
        info.commonName = Self.commonName(of: info.subject)
        info.isSelfIssued = !info.subject.isEmpty && info.subject == info.issuer
        if info.names.isEmpty, !info.commonName.isEmpty { info.names = [info.commonName] }
        return info
    }

    /// The CN of a subject line such as "CN=app.test, O=Example".
    static func commonName(of subject: String) -> String {
        for part in subject.components(separatedBy: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == "CN" { return kv[1] }
        }
        return ""
    }
}

extension AppState {
    static var certificateStore: String { Paths.ssl + "/store" }

    func certificateFiles(_ id: UUID) -> (cert: String, key: String) {
        let dir = Self.certificateStore + "/" + id.uuidString
        return (dir + "/cert.pem", dir + "/key.pem")
    }

    func storedCertificate(_ id: UUID?) -> StoredCertificate? { config.certificates.first { $0.id == id } }

    /// Where a website's certificate and key are: its own self-signed pair, the files you chose, or a stored certificate.
    func certificatePaths(for site: Website) -> (cert: String, key: String) {
        if site.ssl.mode == .stored, let id = site.ssl.certificateID { return certificateFiles(id) }
        return ConfigGenerator.certificatePaths(site)
    }

    /// Who uses a certificate: website names, and "FTP".
    func certificateUsers(_ id: UUID) -> [String] {
        var users = config.websites.filter { $0.ssl.mode == .stored && $0.ssl.certificateID == id }.map(\.name)
        if config.ftp.certificateID == id { users.append("FTP") }
        if config.ai.certificateID == id { users.append(String(localized: "AI Models")) }
        return users
    }

    func loadCertificateInfo(_ id: UUID) async {
        let files = certificateFiles(id)
        let r = await Shell.run("/usr/bin/openssl", ["x509", "-in", files.cert, "-noout", "-text", "-fingerprint", "-sha256", "-serial"])
        if r.ok { certificateInfo[id] = CertificateInfo.parse(r.output) } else { certificateInfo[id] = nil }
    }

    func loadAllCertificateInfo() async {
        for c in config.certificates where certificateInfo[c.id] == nil { await loadCertificateInfo(c.id) }
    }

    // MARK: Create

    static func certificateNames(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: " ,\n\t")).filter { !$0.isEmpty }
    }

    static func isValidCertificateName(_ s: String) -> Bool {
        var addr = in6_addr()
        if inet_pton(AF_INET, s, &addr) == 1 || inet_pton(AF_INET6, s, &addr) == 1 { return true }
        guard s.count <= 253, !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "*" || $0 == "_") }
    }

    private func selfSignedConfig(names: [String]) -> String {
        var addr = in6_addr()
        let sans = names.map { n -> String in
            (inet_pton(AF_INET, n, &addr) == 1 || inet_pton(AF_INET6, n, &addr) == 1) ? "IP:\(n)" : "DNS:\(n)"
        }.joined(separator: ",")
        return """
        [req]
        distinguished_name=dn
        x509_extensions=v3
        prompt=no
        [dn]
        CN=\(names[0])
        O=Server Development Certificate
        [v3]
        subjectAltName=\(sans)
        basicConstraints=CA:FALSE
        keyUsage=digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        """
    }

    /// Writes a new self-signed certificate and key into `folder`.
    func generateSelfSigned(names: [String], days: Int, folder: String) async -> String? {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cnf = folder + "/openssl.cnf"
        try? Paths.write(selfSignedConfig(names: names), to: cnf)
        defer { try? FileManager.default.removeItem(atPath: cnf) }
        let r = await Shell.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", String(days),
                                                     "-keyout", folder + "/key.pem", "-out", folder + "/cert.pem", "-config", cnf])
        guard r.ok else { return r.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder + "/key.pem")
        return nil
    }

    @discardableResult
    func createSelfSignedCertificate(name: String, names text: String, days: Int) async -> String? {
        let label = name.trimmingCharacters(in: .whitespaces)
        let names = Self.certificateNames(from: text)
        guard !label.isEmpty else { return String(localized: "Give the certificate a name.") }
        guard !names.isEmpty else { return String(localized: "Add at least one host name or address.") }
        if let bad = names.first(where: { !Self.isValidCertificateName($0) }) { return String(localized: "“\(bad)” isn't a valid host name or address.") }
        let cert = StoredCertificate(name: label, source: .selfSigned)
        let folder = Self.certificateStore + "/" + cert.id.uuidString
        if let error = await generateSelfSigned(names: names, days: days, folder: folder) {
            try? FileManager.default.removeItem(atPath: folder)
            return error
        }
        update { $0.certificates.append(cert) }
        await loadCertificateInfo(cert.id)
        return nil
    }

    /// Issues a fresh self-signed certificate with the same names (the key changes too).
    @discardableResult
    func renewSelfSignedCertificate(_ id: UUID, days: Int) async -> String? {
        guard let cert = storedCertificate(id), cert.source == .selfSigned, let info = certificateInfo[id], !info.names.isEmpty else {
            return String(localized: "Only self-signed certificates can be renewed here.")
        }
        let folder = Self.certificateStore + "/" + id.uuidString
        if let error = await generateSelfSigned(names: info.names, days: days, folder: folder) { return error }
        await loadCertificateInfo(id)
        await applyConfiguration()
        if isRunning(.ftp) && config.ftp.certificateID == id { ftpNeedsRestart = true }
        return nil
    }

    // MARK: Import

    private func pem(_ path: String) -> String? { try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) }

    /// Imports a certificate (PEM) with its private key. The key can be in the same file, and a chain file is optional.
    @discardableResult
    func importCertificate(name: String, certificatePath: String, keyPath: String, chainPath: String) async -> String? {
        let label = name.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return String(localized: "Give the certificate a name.") }
        guard let certText = pem(certificatePath), certText.contains("BEGIN CERTIFICATE") else {
            return String(localized: "Choose a certificate file in PEM format (it starts with BEGIN CERTIFICATE).")
        }
        let keyText = keyPath.isEmpty ? certText : (pem(keyPath) ?? "")
        guard keyText.contains("PRIVATE KEY") else {
            return keyPath.isEmpty ? String(localized: "Choose the private key file.") : String(localized: "Choose a private key file in PEM format.")
        }
        if keyText.contains("ENCRYPTED") { return String(localized: "The private key is protected by a passphrase. Remove the passphrase first, then import it.") }
        let chainText = chainPath.isEmpty ? "" : (pem(chainPath) ?? "")
        if !chainPath.isEmpty && !chainText.contains("BEGIN CERTIFICATE") { return String(localized: "The chain file isn't a PEM certificate file.") }

        // Keep just the certificates from the certificate file and the key from the key file.
        func blocks(_ text: String, _ kind: String) -> [String] {
            var out: [String] = [], current: [String] = [], inside = false
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("-----BEGIN") && line.contains(kind) { inside = true; current = [] }
                if inside { current.append(line) }
                if inside && line.hasPrefix("-----END") && line.contains(kind) { out.append(current.joined(separator: "\n")); inside = false }
            }
            return out
        }
        let certs = blocks(certText, "CERTIFICATE") + blocks(chainText, "CERTIFICATE")
        guard let key = blocks(keyText, "PRIVATE KEY").first else { return String(localized: "Choose a private key file in PEM format.") }
        let cert = StoredCertificate(name: label, source: .imported)
        let folder = Self.certificateStore + "/" + cert.id.uuidString
        let files = certificateFiles(cert.id)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func fail(_ message: String) -> String { try? FileManager.default.removeItem(atPath: folder); return message }
        do {
            try (certs.joined(separator: "\n") + "\n").write(toFile: files.cert, atomically: true, encoding: .utf8)
            try (key + "\n").write(toFile: files.key, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.key)
        } catch { return fail(error.localizedDescription) }

        // The first certificate must be readable, and the key has to belong to it.
        let a = await Shell.run("/usr/bin/openssl", ["x509", "-in", files.cert, "-noout", "-pubkey"])
        guard a.ok else { return fail(String(localized: "OpenSSL couldn't read the certificate.")) }
        let b = await Shell.run("/usr/bin/openssl", ["pkey", "-in", files.key, "-pubout"])
        guard b.ok else { return fail(String(localized: "OpenSSL couldn't read the private key.")) }
        guard a.output.trimmingCharacters(in: .whitespacesAndNewlines) == b.output.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return fail(String(localized: "The private key doesn't belong to this certificate."))
        }
        update { $0.certificates.append(cert) }
        await loadCertificateInfo(cert.id)
        return nil
    }

    // MARK: Manage

    func renameCertificate(_ id: UUID, to name: String) {
        let label = name.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        update { c in if let i = c.certificates.firstIndex(where: { $0.id == id }) { c.certificates[i].name = label } }
    }

    @discardableResult
    func deleteCertificate(_ id: UUID) -> String? {
        let users = certificateUsers(id)
        if !users.isEmpty { return String(localized: "It's used by \(users.joined(separator: ", ")). Switch those to another certificate first.") }
        try? FileManager.default.removeItem(atPath: Self.certificateStore + "/" + id.uuidString)
        certificateInfo[id] = nil
        update { $0.certificates.removeAll { $0.id == id } }
        return nil
    }

    /// Adds the certificate to the login keychain as trusted, so browsers stop warning about it.
    func trustStoredCertificate(_ id: UUID) async {
        let keychain = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        let r = await Shell.run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, certificateFiles(id).cert])
        flash(r.ok ? String(localized: "The certificate is now trusted.") : String(localized: "Could not trust the certificate: \(r.output)"))
    }
}

// MARK: - HTTPS for the AI chat

extension AppState {
    /// Builds the PKCS#12 bundle the AI server loads for HTTPS (its certificate and key, under a one-time
    /// passphrase). With no stored certificate chosen, it uses a self-signed one for this Mac's names.
    func prepareAIHTTPS() async -> (passphrase: String, error: String?) {
        var files: (cert: String, key: String)
        if let id = config.ai.certificateID, storedCertificate(id) != nil {
            files = certificateFiles(id)
        } else {
            let folder = Paths.ssl + "/ai"
            var names = [SystemStatus.shared.hostName, "localhost", "127.0.0.1"]
            if let ip = await Task.detached(operation: { NetworkScanner.primaryIPv4() }).value { names.append(ip) }
            var seen = Set<String>()
            names = names.filter { !$0.isEmpty && Self.isValidCertificateName($0) && seen.insert($0).inserted }
            let joined = names.joined(separator: " ")
            let marker = folder + "/names.txt"
            let current = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
            var fresh = current == joined && FileManager.default.fileExists(atPath: folder + "/cert.pem")
            if fresh {
                // Replace it a day before it runs out.
                fresh = (await Shell.run("/usr/bin/openssl", ["x509", "-in", folder + "/cert.pem", "-noout", "-checkend", "86400"])).ok
            }
            if !fresh {
                if let e = await generateSelfSigned(names: names, days: 825, folder: folder) {
                    return ("", String(localized: "Couldn't create the HTTPS certificate: \(e)"))
                }
                try? Paths.write(joined, to: marker)
            }
            files = (folder + "/cert.pem", folder + "/key.pem")
        }
        guard FileManager.default.fileExists(atPath: files.cert), FileManager.default.fileExists(atPath: files.key) else {
            return ("", String(localized: "The certificate chosen for HTTPS is missing. Pick another one in AI Models › Settings."))
        }
        let passphrase = UUID().uuidString
        try? FileManager.default.removeItem(atPath: AIServer.tlsBundle)
        let r = await Shell.run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", files.key, "-in", files.cert, "-out", AIServer.tlsBundle,
                                                     "-passout", "env:SERVER_AI_P12", "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
                                env: ["SERVER_AI_P12": passphrase])
        guard r.ok else { return ("", String(localized: "Couldn't prepare the HTTPS certificate: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AIServer.tlsBundle)
        return (passphrase, nil)
    }
}
