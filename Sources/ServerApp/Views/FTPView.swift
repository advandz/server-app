// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

struct FTPView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", users = "Users", settings = "Settings" }
    @State private var tab: Tab = .overview

    var body: some View {
        DetailPage {
            PageHeader(symbol: "arrow.up.arrow.down.square", title: "FTP",
                       subtitle: "File transfer server (Pure-FTPd)", tint: .cyan) {
                ServiceControl(kind: .ftp)
            }
            TabStrip(selection: $tab)
        } content: {
            switch tab {
            case .overview: FTPOverviewTab()
            case .users: FTPUsersTab()
            case .settings: FTPSettingsTab()
            }
        }
    }
}

private struct RestartBar: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if app.ftpNeedsRestart && app.isRunning(.ftp) {
            HStack {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                Text("Restart FTP to apply your changes.")
                Spacer()
                Button("Restart") { Task { await app.restart(.ftp) } }.glassButton(prominent: true)
            }
            .padding(14)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct FTPOverviewTab: View {
    @Environment(AppState.self) private var app
    @State private var userCount = 0

    var body: some View {
        let s = app.config.ftp
        let host = SystemStatus.shared.hostName
        VStack(alignment: .leading, spacing: 20) {
            RestartBar()
            ServiceOverviewCard(kind: .ftp, formula: FTPServer.formula, configFile: FTPServer.passwdFile)
            Card(title: "Connection",
                 footer: "FTP users are separate from your Mac accounts. Each one is locked inside its own folder and reads and writes files as you. Starting and stopping FTP asks for an administrator password.") {
                FormRow(label: "Address") {
                    Text("ftp://\(host)\(s.port == 21 ? "" : ":\(s.port)")").textSelection(.enabled)
                }
                FormRow(label: "Passive Ports") { Text("\(String(s.passiveFrom))–\(String(s.passiveTo))") }
                FormRow(label: "Encryption") {
                    Text(!s.tls ? "Off (plain FTP)" : s.requireTLS ? "FTPS required" : "FTPS allowed")
                }
                FormRow(label: "Users") { Text("\(userCount) user\(userCount == 1 ? "" : "s")") }
            }
        }
        .task(id: app.state(.ftp)) { userCount = await FTPServer.users(prefix: app.brew.prefix).count }
    }
}

// MARK: - Users

struct FTPUsersTab: View {
    @Environment(AppState.self) private var app
    @State private var users: [FTPServer.User] = []
    @State private var adding = false
    @State private var passwordFor: FTPServer.User?
    @State private var deleting: FTPServer.User?
    @State private var error: String?

    private var installed: Bool { app.brew.isInstalled(FTPServer.formula) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
            if !installed {
                Card {
                    HStack {
                        Text("Pure-FTPd isn't installed yet.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Install") { Task { await app.brew.ensureInstalled(FTPServer.formula); await reload() } }
                            .glassButton(prominent: true)
                    }
                }
            } else {
                Card(footer: "Changes to users take effect immediately, without restarting the server.") {
                    if users.isEmpty { Text("No FTP users yet.").foregroundStyle(.secondary) }
                    ForEach(users) { user in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name).fontWeight(.medium)
                                Text(user.home).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Password…") { passwordFor = user }.glassButton()
                            Button("Folder…") {
                                if let path = FolderPicker.choose(startingAt: user.home) {
                                    Task { show(await FTPServer.setHome(user.name, home: path, prefix: app.brew.prefix)); await reload() }
                                }
                            }
                            .glassButton()
                            Button { deleting = user } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove user").accessibilityLabel("Remove User")
                        }
                        if user.id != users.last?.id { Divider() }
                    }
                    HStack {
                        Button("Add User…") { adding = true }.glassButton(prominent: true)
                        Spacer()
                    }
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $adding) {
            FTPUserSheet(existing: Set(users.map(\.name))) { name, password, home in
                show(await FTPServer.addUser(name, password: password, home: home, prefix: app.brew.prefix))
                await reload()
            }
        }
        .sheet(item: $passwordFor) { user in
            FTPPasswordSheet(user: user) { password in
                show(await FTPServer.setPassword(user.name, password: password, prefix: app.brew.prefix))
            }
        }
        .confirmationDialog("Remove the FTP user “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { user in
            Button("Remove User", role: .destructive) {
                Task { show(await FTPServer.deleteUser(user.name, prefix: app.brew.prefix)); await reload() }
            }
        } message: { _ in
            Text("Their folder and files are kept.")
        }
    }

    private func show(_ result: String?) { if let result { error = result } }
    private func reload() async { users = await FTPServer.users(prefix: app.brew.prefix) }
}

struct FTPUserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: Set<String>
    var onAdd: (String, String, String) async -> Void
    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var home = NSHomeDirectory() + "/Public"
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "person.crop.circle.badge.plus", title: "New FTP User", subtitle: "Kept to one folder", tint: .cyan)
            FormRow(label: "User Name", labelWidth: 120) { TextField("name", text: $name).textFieldStyle(.roundedBorder) }
            FormRow(label: "Password", labelWidth: 120) { SecureField("", text: $password).textFieldStyle(.roundedBorder) }
            FormRow(label: "Confirm", labelWidth: 120) { SecureField("", text: $confirm).textFieldStyle(.roundedBorder) }
            FormRow(label: "Folder", labelWidth: 120) {
                HStack {
                    Text(home).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { if let p = FolderPicker.choose(startingAt: home) { home = p } }
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).padding(.leading, 132) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add User") {
                    working = true
                    Task { await onAdd(name, password, home); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .glassButton(prominent: true)
                .disabled(problem != nil || working)
            }
        }
        .padding(26)
        .frame(width: 520)
    }

    private var problem: String? {
        if name.isEmpty || password.isEmpty { return "Enter a user name and password." }
        if !FTPServer.isValidUserName(name) { return "Use letters, numbers, dots, hyphens and underscores." }
        if existing.contains(name) { return "There's already a user named \(name)." }
        if password.count < 8 { return "Use at least 8 characters for the password." }
        if password != confirm { return "The passwords don't match." }
        return nil
    }
}

struct FTPPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let user: FTPServer.User
    var onSave: (String) async -> Void
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "key", title: "Change Password", subtitle: "\(user.name)", tint: .cyan)
            FormRow(label: "New Password", labelWidth: 120) { SecureField("", text: $password).textFieldStyle(.roundedBorder) }
            FormRow(label: "Confirm", labelWidth: 120) { SecureField("", text: $confirm).textFieldStyle(.roundedBorder) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change Password") { Task { await onSave(password); dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
                    .disabled(password.count < 8 || password != confirm)
            }
        }
        .padding(26)
        .frame(width: 480)
    }
}

// MARK: - Settings

struct FTPSettingsTab: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RestartBar()
            Card(title: "Ports", footer: "Passive mode uses one port per transfer from this range; open them in your router to allow FTP from the internet.") {
                FormRow(label: "FTP Port") { NumberField(value: bind(\.port)) }
                FormRow(label: "Passive Ports") {
                    HStack {
                        NumberField(value: bind(\.passiveFrom))
                        Text("to")
                        NumberField(value: bind(\.passiveTo))
                    }
                }
                FormRow(label: "Passive Address") {
                    TextField("Automatic", text: bind(\.passiveAddress)).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            Card(title: "Connections") {
                FormRow(label: "Max Clients") { NumberField(value: bind(\.maxClients)) }
                FormRow(label: "Max per Address") { NumberField(value: bind(\.maxPerIP)) }
            }
            Card(title: "Encryption", footer: "Uses a self-signed certificate created for this Mac. FTP clients ask you to trust it the first time.") {
                FormRow(label: "FTPS") { Toggle("Allow encrypted connections (explicit TLS)", isOn: bind(\.tls)) }
                FormRow(label: "") {
                    Toggle("Require encryption", isOn: bind(\.requireTLS)).disabled(!app.config.ftp.tls)
                }
            }
        }
    }

    private func bind<T>(_ key: WritableKeyPath<FTPSettings, T>) -> Binding<T> {
        Binding(
            get: { app.config.ftp[keyPath: key] },
            set: { v in
                app.update { $0.ftp[keyPath: key] = v }
                if app.isRunning(.ftp) { app.ftpNeedsRestart = true }
            }
        )
    }
}
