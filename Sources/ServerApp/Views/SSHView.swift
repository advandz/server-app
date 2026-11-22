// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

/// macOS Remote Login: the built-in OpenSSH server. Like File Sharing, it's a system service
/// Server only switches and configures; quitting Server never turns it off.
enum SSHService {
    static let daemon = "/System/Library/LaunchDaemons/ssh.plist"
    static let accessGroup = "com.apple.access_ssh"
    static let adminGroupGUID = "ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000050"
    static let dseditgroup = "/usr/sbin/dseditgroup"

    struct MacUser: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let realName: String
        let isAdmin: Bool
    }

    /// Who may log in. No access group = every user; otherwise its members (and admins, when
    /// the admin group is nested in it).
    struct Access: Equatable {
        var restricted = false
        var admins = false
        var users: Set<String> = []
    }

    struct HostKey: Identifiable {
        var id: String { type }
        let type: String
        let fingerprint: String
    }

    struct AuthorizedKey: Identifiable, Hashable {
        let id = UUID()
        let line: String
        let type: String
        let comment: String
        var fingerprint = ""
    }

    // MARK: Read (no privileges needed)

    static func isOn() async -> Bool {
        async let disabled = Shell.run("/bin/launchctl", ["print-disabled", "system"])
        async let net = Shell.run("/usr/sbin/netstat", ["-an", "-p", "tcp"])
        let (d, n) = await (disabled, net)
        let line = d.output.split(separator: "\n").first { $0.contains("\"com.openssh.sshd\"") } ?? ""
        let listening = n.output.split(separator: "\n").contains { $0.contains(".22 ") && $0.contains("LISTEN") }
        return !line.contains("disabled") && listening
    }

    private static func plist(_ args: [String]) async -> Any? {
        let r = await Shell.run("/usr/bin/dscl", ["-plist", "."] + args)
        guard r.ok, let data = r.output.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func values(_ dict: [String: Any], _ key: String) -> [String] {
        (dict["dsAttrTypeStandard:\(key)"] as? [String]) ?? []
    }

    /// Members of a macOS service access group (SSH, Screen Sharing…).
    static func access(group name: String = accessGroup) async -> Access {
        guard let group = await plist(["-read", "/Groups/\(name)"]) as? [String: Any] else { return Access() }
        return Access(restricted: true,
                      admins: values(group, "NestedGroups").contains(adminGroupGUID),
                      users: Set(values(group, "GroupMembership")))
    }

    /// People who can log in to this Mac (not system or service accounts).
    static func users() async -> [MacUser] {
        let admins = Set(values((await plist(["-read", "/Groups/admin", "GroupMembership"]) as? [String: Any]) ?? [:], "GroupMembership"))
        let all = (await plist(["-readall", "/Users", "RecordName", "RealName", "UniqueID", "UserShell"]) as? [[String: Any]]) ?? []
        return all.compactMap { u in
            guard let name = values(u, "RecordName").first, !name.hasPrefix("_"),
                  let uid = Int(values(u, "UniqueID").first ?? ""), uid >= 501,
                  let shell = values(u, "UserShell").first, shell != "/usr/bin/false", shell != "/sbin/nologin" else { return nil }
            return MacUser(name: name, realName: values(u, "RealName").first ?? name, isAdmin: admins.contains(name))
        }
        .sorted { $0.realName.localizedStandardCompare($1.realName) == .orderedAscending }
    }

    static func hostKeys() async -> [HostKey] {
        var keys: [HostKey] = []
        for type in ["ed25519", "ecdsa", "rsa"] {
            let r = await Shell.run("/usr/bin/ssh-keygen", ["-lf", "/etc/ssh/ssh_host_\(type)_key.pub"])
            let parts = r.output.split(separator: " ")
            if r.ok, parts.count >= 2 { keys.append(HostKey(type: type.uppercased(), fingerprint: String(parts[1]))) }
        }
        return keys
    }

    static func version() async -> String {
        let r = await Shell.run("/usr/bin/ssh", ["-V"])
        return r.output.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Changes (administrator password)

    static func setOn(_ on: Bool) -> [[String]] {
        on
            ? [["/bin/launchctl", "enable", "system/com.openssh.sshd"], ["/bin/launchctl", "load", "-w", daemon]]
            : [["/bin/launchctl", "unload", "-w", daemon], ["/bin/launchctl", "disable", "system/com.openssh.sshd"]]
    }

    /// Commands that turn `from` into `to`.
    static func changeAccess(from: Access, to: Access, group accessGroup: String = accessGroup) -> [[String]] {
        if !to.restricted {
            return from.restricted ? [[dseditgroup, "-o", "delete", "-t", "group", accessGroup]] : []
        }
        var cmds: [[String]] = []
        if !from.restricted { cmds.append([dseditgroup, "-o", "create", "-q", accessGroup]) }
        if to.admins != from.admins || !from.restricted {
            if to.admins { cmds.append([dseditgroup, "-o", "edit", "-a", "admin", "-t", "group", accessGroup]) }
            else if from.admins { cmds.append([dseditgroup, "-o", "edit", "-d", "admin", "-t", "group", accessGroup]) }
        }
        for u in to.users.subtracting(from.users).sorted() { cmds.append([dseditgroup, "-o", "edit", "-a", u, "-t", "user", accessGroup]) }
        for u in from.users.subtracting(to.users).sorted() { cmds.append([dseditgroup, "-o", "edit", "-d", u, "-t", "user", accessGroup]) }
        return cmds
    }

    // MARK: Your authorized keys (~/.ssh/authorized_keys, no privileges needed)

    static var authorizedKeysFile: String { NSHomeDirectory() + "/.ssh/authorized_keys" }

    static func authorizedKeys() async -> [AuthorizedKey] {
        guard let text = try? String(contentsOfFile: authorizedKeysFile, encoding: .utf8) else { return [] }
        var keys: [AuthorizedKey] = []
        for line in text.split(separator: "\n").map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#") else { continue }
            let parts = t.split(separator: " ", maxSplits: 2).map(String.init)
            // Options may come first ("from=… ssh-ed25519 AAAA… comment"); find the key type.
            let typeIndex = parts.firstIndex { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") || $0.hasPrefix("sk-") } ?? 0
            var key = AuthorizedKey(line: line, type: parts[safe: typeIndex] ?? "key",
                                    comment: parts.count > typeIndex + 2 ? parts[typeIndex + 2] : "")
            let r = await Shell.run("/usr/bin/ssh-keygen", ["-lf", "-"], input: t + "\n")
            if r.ok { key.fingerprint = r.output.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
            keys.append(key)
        }
        return keys
    }

    /// Validates a public key with ssh-keygen; returns an error message or nil.
    static func validate(_ key: String) async -> String? {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return "Paste a single public key line." }
        if t.contains("PRIVATE KEY") { return "That's a private key. Paste the public key (the .pub file) instead." }
        let r = await Shell.run("/usr/bin/ssh-keygen", ["-lf", "-"], input: t + "\n")
        return r.ok ? nil : "That doesn't look like an SSH public key."
    }

    static func saveAuthorizedKeys(_ lines: [String]) throws {
        let dir = NSHomeDirectory() + "/.ssh"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(toFile: authorizedKeysFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedKeysFile)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Page

struct SSHView: View {
    @State private var on: Bool?
    @State private var access: SSHService.Access?
    @State private var users: [SSHService.MacUser] = []
    @State private var hostKeys: [SSHService.HostKey] = []
    @State private var keys: [SSHService.AuthorizedKey] = []
    @State private var version = ""
    @State private var working = false
    @State private var error: String?
    @State private var confirmOff = false
    @State private var addingKey = false
    private let system = SystemStatus.shared

    var body: some View {
        DetailPage {
            PageHeader(symbol: "terminal", title: "SSH",
                       subtitle: on == nil ? "Remote Login (OpenSSH)" : on! ? "On · ssh \(NSUserName())@\(system.hostName)" : "Off",
                       tint: .gray) {
                if working { ProgressView().controlSize(.small) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
                statusCard
                if let access { accessCard(access) }
                connectCard
                keysCard
            }
        }
        .task { await reload() }
        .confirmationDialog("Turn off Remote Login?", isPresented: $confirmOff) {
            Button("Turn Off", role: .destructive) { apply(SSHService.setOn(false)) }
        } message: {
            Text("New SSH and SFTP connections to this Mac are refused. Sessions already open stay connected until they end.")
        }
        .sheet(isPresented: $addingKey) {
            AddSSHKeySheet { key in
                var lines = keys.map(\.line)
                lines.append(key)
                do { try SSHService.saveAuthorizedKeys(lines) } catch { self.error = error.localizedDescription }
                Task { keys = await SSHService.authorizedKeys() }
            }
        }
    }

    private var statusCard: some View {
        Card(footer: "Lets users of this Mac log in from other computers with ssh, and copy files with scp or SFTP. Uses macOS's built-in OpenSSH server (Remote Login). Changes ask for an administrator password.") {
            FormRow(label: "Remote Login") {
                Toggle("Allow users to log in with SSH", isOn: Binding(get: { on ?? false }, set: { value in
                    if value { apply(SSHService.setOn(true)) } else { confirmOff = true }
                }))
                .disabled(on == nil || working)
            }
            if !version.isEmpty { FormRow(label: "Server") { Text(version).foregroundStyle(.secondary) } }
        }
    }

    private func accessCard(_ a: SSHService.Access) -> some View {
        Card(title: "Allow Access For") {
            FormRow(label: "Users") {
                Picker("", selection: Binding(get: { a.restricted }, set: { restricted in
                    var to = a
                    to.restricted = restricted
                    if restricted && !a.restricted { to.admins = true }   // like System Settings
                    apply(SSHService.changeAccess(from: a, to: to))
                })) {
                    Text("All users").tag(false)
                    Text("Only these users").tag(true)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .disabled(working)
            }
            if a.restricted {
                FormRow(label: "") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Administrators", isOn: Binding(get: { a.admins }, set: { v in
                            var to = a; to.admins = v
                            apply(SSHService.changeAccess(from: a, to: to))
                        }))
                        ForEach(users) { u in
                            Toggle(isOn: Binding(get: { a.users.contains(u.name) || (a.admins && u.isAdmin) }, set: { v in
                                var to = a
                                if v { to.users.insert(u.name) } else { to.users.remove(u.name) }
                                apply(SSHService.changeAccess(from: a, to: to))
                            })) {
                                Text("\(u.realName) (\(u.name))") + Text(u.isAdmin ? "  · Admin" : "").foregroundStyle(.secondary)
                            }
                            .disabled(a.admins && u.isAdmin)
                        }
                    }
                    .disabled(working)
                }
            }
        }
    }

    private var connectCard: some View {
        Card(title: "Connect",
             footer: "The first time someone connects, ssh shows this Mac's key fingerprint; it should match one of these.") {
            FormRow(label: "Command") {
                HStack {
                    Text("ssh \(NSUserName())@\(system.hostName)").font(.body.monospaced()).textSelection(.enabled)
                    Button { copy("ssh \(NSUserName())@\(system.hostName)") } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy").accessibilityLabel("Copy Command")
                }
            }
            ForEach(hostKeys) { k in
                FormRow(label: "\(k.type)") {
                    Text(k.fingerprint).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
    }

    private var keysCard: some View {
        Card(title: "Your Authorized Keys",
             footer: "Public keys that can log in as \(NSUserName()) without a password (~/.ssh/authorized_keys).") {
            if keys.isEmpty { Text("No keys yet. You can still log in with your Mac password.").foregroundStyle(.secondary) }
            ForEach(keys) { key in
                HStack(spacing: 10) {
                    Image(systemName: "key").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.comment.isEmpty ? key.type : key.comment).fontWeight(.medium)
                        Text("\(key.type)  \(key.fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { remove(key) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove key").accessibilityLabel("Remove Key")
                }
                if key.id != keys.last?.id { Divider() }
            }
            HStack {
                Button("Add Key…") { addingKey = true }.glassButton()
                Spacer()
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func remove(_ key: SSHService.AuthorizedKey) {
        do { try SSHService.saveAuthorizedKeys(keys.filter { $0.id != key.id }.map(\.line)) } catch { self.error = error.localizedDescription }
        Task { keys = await SSHService.authorizedKeys() }
    }

    private func apply(_ commands: [[String]]) {
        guard !commands.isEmpty else { return }
        working = true
        Task {
            if let result = await Privileged.run(commands), !result.isEmpty { error = result }
            await reload()
            working = false
        }
    }

    private func reload() async {
        async let o = SSHService.isOn()
        async let a = SSHService.access()
        async let u = SSHService.users()
        async let h = SSHService.hostKeys()
        async let k = SSHService.authorizedKeys()
        async let v = SSHService.version()
        (on, access, users, hostKeys, keys, version) = await (o, a, u, h, k, v)
        await SystemServices.shared.refresh()
    }
}

struct AddSSHKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (String) -> Void
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "key", title: "Add Public Key", subtitle: "Log in as \(NSUserName()) with this key", tint: .gray)
            TextEditor(text: $key)
                .font(.callout.monospaced())
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text("Paste the contents of the other computer's public key, e.g. ~/.ssh/id_ed25519.pub.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Key") {
                    Task {
                        problem = await SSHService.validate(key)
                        if problem == nil { onAdd(key.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .glassButton(prominent: true)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 560)
    }
}
