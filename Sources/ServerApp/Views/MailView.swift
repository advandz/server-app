// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

struct MailView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", accounts = "Accounts", smtp = "SMTP", imap = "IMAP" }
    @State private var tab: Tab = .overview

    var body: some View {
        DetailPage {
            PageHeader(symbol: "envelope", title: "Mail", subtitle: "SMTP and IMAP mail server", tint: .blue) {
                ServiceControl(kind: .mail)
            }
            TabStrip(selection: $tab)
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if app.mailNeedsRestart && app.isRunning(.mail) {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                        Text("Restart Mail to apply your changes.")
                        Spacer()
                        Button("Restart") { Task { await app.restart(.mail) } }.glassButton(prominent: true)
                    }
                    .padding(14)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let err = app.errors[.mail] { ErrorBanner(text: err) { app.errors[.mail] = nil } }
                switch tab {
                case .overview: MailOverviewTab()
                case .accounts: MailAccountsTab()
                case .smtp: MailSMTPTab()
                case .imap: MailIMAPTab()
                }
            }
        }
    }
}

// MARK: - Overview

private struct MailOverviewTab: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let s = app.config.mail
        let host = MailServer.hostName(s)
        VStack(alignment: .leading, spacing: 20) {
            ServiceOverviewCard(kind: .mail, formula: MailServer.formula, configFile: MailServer.dovecotConf)
            Card(title: "Servers") {
                FormRow(label: "SMTP") {
                    if s.sandbox {
                        HStack { Text("Mailpit"); Badge(text: String(localized: "Sandbox"), symbol: "testtube.2", warning: true) }
                    } else {
                        Text("Postfix (built into macOS)")
                    }
                }
                FormRow(label: "IMAP") { Text("Dovecot") }
            }
            Card(title: "Connection",
                 footer: s.allowNetwork ? "Other devices on your network can connect. Sign in is encrypted unless you turn that off in IMAP."
                                        : "Only this Mac can connect. Turn on network access in SMTP to use it from other devices.") {
                FormRow(label: "Host Name") { CopyText(text: host) }
                FormRow(label: "SMTP") {
                    Text(s.sandbox ? "\(s.smtpPort)" : "\(s.smtpPort), \(s.submissionPort) (STARTTLS), \(s.smtpsPort) (TLS)").monospacedDigit().foregroundStyle(.secondary)
                }
                FormRow(label: "IMAP") { Text("\(s.imapPort) (STARTTLS), \(s.imapsPort) (TLS)").monospacedDigit().foregroundStyle(.secondary) }
                FormRow(label: "User Name") { Text("The full address, such as you@example.com").foregroundStyle(.secondary) }
            }
            if s.sandbox {
                Card(title: "Sandbox",
                     footer: "Mailpit catches every message sent to the SMTP port and keeps it for you to read. Nothing is delivered. It accepts any sign-in and can be reached by other devices on the network.") {
                    FormRow(label: "Inbox") {
                        HStack {
                            CopyText(text: "http://127.0.0.1:\(s.sandboxWebPort)/")
                            Button("Open") { if let u = URL(string: "http://127.0.0.1:\(s.sandboxWebPort)/") { NSWorkspace.shared.open(u) } }
                                .glassButton().disabled(!app.mailSandboxRunning)
                        }
                    }
                }
            }
            Card(title: "Mailboxes") {
                FormRow(label: "Domains") { Text("\(app.config.mailDomains.count)").foregroundStyle(.secondary) }
                FormRow(label: "Accounts") { Text("\(app.config.mailAccounts.count)").foregroundStyle(.secondary) }
                FormRow(label: "Mail Folder") { PathText(path: MailServer.vhosts) }
            }
        }
    }
}

// MARK: - Accounts

private struct MailAccountsTab: View {
    @Environment(AppState.self) private var app
    enum Sheet: Identifiable {
        case domain, account, alias, password(UUID)
        var id: String { switch self { case .domain: "d"; case .account: "a"; case .alias: "l"; case .password(let id): "p\(id)" } }
    }
    @State private var sheet: Sheet?
    @State private var removingAccount: MailAccount?
    @State private var removingDomain: MailDomain?

    var body: some View {
        let domains = app.config.mailDomains
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Domains", footer: "Mail for these domains is kept on this Mac. Point each domain's MX record at this Mac to receive mail from the internet.") {
                if domains.isEmpty { Text("No domains yet.").foregroundStyle(.secondary) }
                ForEach(domains) { d in
                    HStack {
                        Text(d.name).fontWeight(.medium)
                        Spacer()
                        Button { removingDomain = d } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove Domain")
                    }
                }
                HStack { Button("Add Domain…") { sheet = .domain }.glassButton(); Spacer() }
            }
            Card(title: "Accounts", footer: "Each account is a mailbox that signs in with its full address.") {
                if app.config.mailAccounts.isEmpty { Text("No accounts yet.").foregroundStyle(.secondary) }
                ForEach(app.config.mailAccounts) { a in
                    HStack {
                        Text(a.address).fontWeight(.medium).textSelection(.enabled)
                        Spacer()
                        Button("Change Password…") { sheet = .password(a.id) }.glassButton()
                        Button { removingAccount = a } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove Account")
                    }
                }
                HStack { Button("Add Account…") { sheet = .account }.glassButton().disabled(domains.isEmpty); Spacer() }
            }
            Card(title: "Aliases", footer: "An alias forwards mail to other addresses. Use @example.com to catch everything sent to a domain.") {
                if app.config.mailAliases.isEmpty { Text("No aliases yet.").foregroundStyle(.secondary) }
                ForEach(app.config.mailAliases) { l in
                    HStack {
                        Text(l.source).fontWeight(.medium)
                        Text("→ \(l.destination)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { Task { await app.removeMailAlias(l.id) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove Alias")
                    }
                }
                HStack { Button("Add Alias…") { sheet = .alias }.glassButton().disabled(domains.isEmpty); Spacer() }
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .domain: MailTextSheet(title: "Add Domain", field: "Domain", placeholder: "example.com", action: { await app.addMailDomain($0) })
            case .account: MailAccountSheet()
            case .alias: MailAliasSheet()
            case .password(let id): MailPasswordSheet(accountID: id)
            }
        }
        .confirmationDialog("Remove “\(removingAccount?.address ?? "")”?", isPresented: Binding(get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } }), presenting: removingAccount) { a in
            Button("Remove Account") { Task { await app.removeMailAccount(a.id, deleteMail: false) } }
            Button("Remove and Delete Mail", role: .destructive) { Task { await app.removeMailAccount(a.id, deleteMail: true) } }
        } message: { _ in Text("The mailbox stops working. Its messages stay on disk unless you delete them.") }
        .confirmationDialog("Remove “\(removingDomain?.name ?? "")”?", isPresented: Binding(get: { removingDomain != nil }, set: { if !$0 { removingDomain = nil } }), presenting: removingDomain) { d in
            Button("Remove Domain", role: .destructive) { Task { await app.removeMailDomain(d.id) } }
        } message: { _ in Text("Its accounts and aliases are removed too. Messages stay on disk.") }
    }
}

private struct MailTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let field: LocalizedStringKey
    let placeholder: String
    let action: (String) async -> String?
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "envelope", title: title, subtitle: "Mail", tint: .blue)
            FormRow(label: field, labelWidth: 100) { TextField(placeholder, text: $text).textFieldStyle(.roundedBorder) }
            if let error { ErrorBanner(text: error) { self.error = nil } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { Task { if let e = await action(text) { error = e } else { dismiss() } } }
                    .keyboardShortcut(.defaultAction).glassButton(prominent: true)
            }
        }
        .padding(26).frame(width: 460)
    }
}

private struct MailAccountSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var domain = ""
    @State private var password = AppState.randomPassword(16)
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "person.crop.circle.badge.plus", title: "Add Account", subtitle: "Mail", tint: .blue)
            FormRow(label: "Address", labelWidth: 100) {
                HStack {
                    TextField("you", text: $user).textFieldStyle(.roundedBorder)
                    Text("@")
                    Picker("", selection: $domain) {
                        ForEach(app.config.mailDomains) { Text($0.name).tag($0.name) }
                    }.labelsHidden().fixedSize()
                }
            }
            FormRow(label: "Password", labelWidth: 100) {
                HStack {
                    TextField("", text: $password).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    Button("Generate") { password = AppState.randomPassword(16) }.glassButton()
                }
            }
            Text("Write the password down now. Server only keeps a scrambled copy.").font(.caption).foregroundStyle(.secondary).padding(.leading, 112)
            if let error { ErrorBanner(text: error) { self.error = nil } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task { if let e = await app.addMailAccount(user: user, domain: domain, password: password) { error = e } else { dismiss() } }
                }.keyboardShortcut(.defaultAction).glassButton(prominent: true)
            }
        }
        .padding(26).frame(width: 520)
        .onAppear { if domain.isEmpty { domain = app.config.mailDomains.first?.name ?? "" } }
    }
}

private struct MailPasswordSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let accountID: UUID
    @State private var password = AppState.randomPassword(16)
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "key", title: "Change Password", subtitle: "\(app.config.mailAccounts.first { $0.id == accountID }?.address ?? "")", tint: .blue)
            FormRow(label: "New Password", labelWidth: 120) {
                HStack {
                    TextField("", text: $password).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    Button("Generate") { password = AppState.randomPassword(16) }.glassButton()
                }
            }
            if let error { ErrorBanner(text: error) { self.error = nil } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { if let e = await app.changeMailPassword(accountID, to: password) { error = e } else { dismiss() } } }
                    .keyboardShortcut(.defaultAction).glassButton(prominent: true)
            }
        }
        .padding(26).frame(width: 520)
    }
}

private struct MailAliasSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var destination = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "arrowshape.turn.up.right", title: "Add Alias", subtitle: "Mail", tint: .blue)
            FormRow(label: "Alias", labelWidth: 110) { TextField("info@example.com", text: $source).textFieldStyle(.roundedBorder) }
            FormRow(label: "Forward To", labelWidth: 110) { TextField("you@example.com, other@example.com", text: $destination).textFieldStyle(.roundedBorder) }
            if let error { ErrorBanner(text: error) { self.error = nil } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { Task { if let e = await app.addMailAlias(source: source, destination: destination) { error = e } else { dismiss() } } }
                    .keyboardShortcut(.defaultAction).glassButton(prominent: true)
            }
        }
        .padding(26).frame(width: 540)
    }
}

// MARK: - SMTP

private struct MailSMTPTab: View {
    @Environment(AppState.self) private var app

    private func bind<T>(_ key: WritableKeyPath<MailSettings, T>) -> Binding<T> {
        Binding(get: { app.config.mail[keyPath: key] }, set: { v in
            app.update { $0.mail[keyPath: key] = v }
            if app.isRunning(.mail) { app.mailNeedsRestart = true }
        })
    }

    var body: some View {
        let s = app.config.mail
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Sandbox",
                 footer: s.sandbox
                 ? "Mailpit answers on the SMTP port instead of the real mail server. Messages are caught, never delivered. Submission and SMTPS are closed while the sandbox is on."
                 : "For testing: catch all mail your apps send instead of delivering it.") {
                FormRow(label: "Sandbox") {
                    Toggle("Replace the real SMTP server with Mailpit on the same port", isOn: bind(\.sandbox)).toggleStyle(.checkbox)
                }
                if s.sandbox { FormRow(label: "Inbox Port") { NumberField(value: bind(\.sandboxWebPort)) } }
            }
            Card(title: "Server") {
                FormRow(label: "Host Name") {
                    TextField(SystemStatus.shared.hostName, text: bind(\.hostName)).textFieldStyle(.roundedBorder).frame(width: 280)
                }
                FormRow(label: "Network") { Toggle("Accept connections from other devices", isOn: bind(\.allowNetwork)) }
                FormRow(label: "Certificate") {
                    CertificatePicker(selection: bind(\.certificateID), automaticTitle: "Automatic (self-signed by Server)")
                }
                FormRow(label: "Max Message Size") { NumberField(value: bind(\.maxMessageMB)) }
            }
            Card(title: "Ports", footer: "25 receives mail from other servers. 587 (STARTTLS) and 465 (TLS) are for mail apps, which must sign in.") {
                FormRow(label: "SMTP") { NumberField(value: bind(\.smtpPort)) }
                FormRow(label: "Submission") { NumberField(value: bind(\.submissionPort)).disabled(s.sandbox) }
                FormRow(label: "SMTPS") { NumberField(value: bind(\.smtpsPort)).disabled(s.sandbox) }
            }
            Card(title: "Relay", footer: "Many internet providers block port 25. A relay sends your outgoing mail through another SMTP server instead. Leave empty to deliver directly.") {
                FormRow(label: "Relay Host") { TextField("smtp.example.com:587", text: bind(\.relayHost)).textFieldStyle(.roundedBorder).frame(width: 280) }
                FormRow(label: "User Name") { TextField("Optional", text: bind(\.relayUser)).textFieldStyle(.roundedBorder).frame(width: 280) }
                FormRow(label: "Password") { SecureField("Optional", text: bind(\.relayPassword)).textFieldStyle(.roundedBorder).frame(width: 280) }
            }
        }
    }
}

// MARK: - IMAP

private struct MailIMAPTab: View {
    @Environment(AppState.self) private var app

    private func bind<T>(_ key: WritableKeyPath<MailSettings, T>) -> Binding<T> {
        Binding(get: { app.config.mail[keyPath: key] }, set: { v in
            app.update { $0.mail[keyPath: key] = v }
            if app.isRunning(.mail) { app.mailNeedsRestart = true }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Ports", footer: "143 starts plain and switches to encryption (STARTTLS). 993 is encrypted from the start (TLS).") {
                FormRow(label: "IMAP") { NumberField(value: bind(\.imapPort)) }
                FormRow(label: "IMAPS") { NumberField(value: bind(\.imapsPort)) }
            }
            Card(title: "Sign In", footer: app.config.mail.requireEncryption
                 ? "Passwords are only accepted over an encrypted connection."
                 : "Passwords can be sent unencrypted. Use this only on a network you trust.") {
                FormRow(label: "Encryption") { Toggle("Require encryption to sign in", isOn: bind(\.requireEncryption)) }
            }
        }
    }
}
