// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

extension CertificateInfo {
    /// Whether the certificate's names cover this host (wildcards match one label, like browsers do).
    func covers(_ host: String) -> Bool {
        let h = host.lowercased()
        return names.contains { raw in
            let n = raw.lowercased()
            if n == h { return true }
            guard n.hasPrefix("*.") else { return false }
            let suffix = String(n.dropFirst(1))          // ".test"
            return h.hasSuffix(suffix) && !h.dropLast(suffix.count).contains(".") && !h.dropLast(suffix.count).isEmpty
        }
    }
}

/// Picks one of the stored certificates. `automaticTitle` is the choice that means "none of them".
struct CertificatePicker: View {
    @Environment(AppState.self) private var app
    @Binding var selection: UUID?
    var automaticTitle: LocalizedStringKey = "Choose…"

    var body: some View {
        Picker("", selection: $selection) {
            Text(automaticTitle).tag(UUID?.none)
            if !app.config.certificates.isEmpty { Divider() }
            ForEach(app.config.certificates) { c in Text(c.name).tag(UUID?.some(c.id)) }
        }
        .labelsHidden().fixedSize()
    }
}

// MARK: - Page

struct CertificatesView: View {
    @Environment(AppState.self) private var app
    enum Sheet: Identifiable { case create, importing, rename(UUID); var id: String {
        switch self { case .create: "create"; case .importing: "import"; case .rename(let id): "rename-\(id)" } } }
    @State private var sheet: Sheet?
    @State private var error: String?

    var body: some View {
        let certs = app.config.certificates
        DetailPage {
            PageHeader(symbol: "checkmark.seal", title: "Certificates",
                       subtitle: certs.isEmpty ? "Keep SSL certificates for your websites and services" : "\(certs.count) stored",
                       tint: .green) {
                Menu("Add Certificate") {
                    Button("Create Self-Signed…") { sheet = .create }
                    Button("Import…") { sheet = .importing }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if let error { ErrorBanner(text: error) { self.error = nil } }
                if certs.isEmpty {
                    Card(footer: "Certificates stored here can be chosen for any website (Website Settings › SSL) and for FTP.") {
                        Text("No certificates yet.").foregroundStyle(.secondary)
                        HStack {
                            Button("Create Self-Signed…") { sheet = .create }.glassButton(prominent: true)
                            Button("Import…") { sheet = .importing }.glassButton()
                        }
                    }
                }
                ForEach(certs) { cert in
                    CertificateCard(cert: cert, rename: { sheet = .rename(cert.id) }, report: { error = $0 })
                }
            }
        }
        .task(id: certs.map(\.id)) { await app.loadAllCertificateInfo() }
        .sheet(item: $sheet) { s in
            switch s {
            case .create: CertificateCreateSheet()
            case .importing: CertificateImportSheet()
            case .rename(let id): CertificateRenameSheet(id: id)
            }
        }
    }
}

private struct CertificateCard: View {
    @Environment(AppState.self) private var app
    let cert: StoredCertificate
    let rename: () -> Void
    let report: (String?) -> Void
    @State private var confirmDelete = false
    @State private var working = false

    var body: some View {
        let info = app.certificateInfo[cert.id]
        let users = app.certificateUsers(cert.id)
        Card {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(statusColor(info))
                VStack(alignment: .leading, spacing: 2) {
                    Text(cert.name).font(.headline)
                    Text(cert.source == .selfSigned ? "Self-signed" : "Imported").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                if let info { Badge(text: statusText(info), symbol: info.isExpired ? "exclamationmark.triangle.fill" : nil,
                                    warning: info.isExpired || info.expiresSoon) }
            }
            if let info {
                FormRow(label: "Names") { Text(info.names.joined(separator: ", ")).textSelection(.enabled) }
                FormRow(label: "Issued By") { Text(info.isSelfIssued ? "Self-signed" : LocalizedStringKey(CertificateInfo.commonName(of: info.issuer).isEmpty ? info.issuer : CertificateInfo.commonName(of: info.issuer))).foregroundStyle(.secondary) }
                FormRow(label: "Valid") {
                    Text("\(info.notBefore?.formatted(date: .abbreviated, time: .omitted) ?? "—") – \(info.notAfter?.formatted(date: .abbreviated, time: .omitted) ?? "—")")
                        .foregroundStyle(.secondary)
                }
                FormRow(label: "Used By") {
                    Text(users.isEmpty ? "Not used" : "\(users.joined(separator: ", "))").foregroundStyle(.secondary)
                }
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        FormRow(label: "Subject") { Text(info.subject).font(.caption).textSelection(.enabled) }
                        FormRow(label: "Key") { Text(info.keyDescription).font(.caption).foregroundStyle(.secondary) }
                        FormRow(label: "Serial Number") { Text(info.serial).font(.caption.monospaced()).textSelection(.enabled) }
                        FormRow(label: "SHA-256") { Text(info.fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
                    }.padding(.top, 8)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Reading certificate…").foregroundStyle(.secondary) }
            }
            HStack {
                Button("Trust in Keychain…") { Task { await app.trustStoredCertificate(cert.id) } }.glassButton()
                if cert.source == .selfSigned {
                    Menu("Renew") {
                        Button("For 90 Days") { renew(90) }
                        Button("For 1 Year") { renew(365) }
                        Button("For 2 Years") { renew(730) }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Spacer()
                Button("Rename…", action: rename).glassButton()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.certificateFiles(cert.id).cert)])
                }.glassButton()
                Button("Delete…") { confirmDelete = true }.glassButton()
            }
        }
        .confirmationDialog("Delete “\(cert.name)”?", isPresented: $confirmDelete) {
            Button("Delete Certificate", role: .destructive) { report(app.deleteCertificate(cert.id)) }
        } message: {
            Text("The certificate and its private key are deleted from Server. This can't be undone.")
        }
    }

    private func renew(_ days: Int) {
        working = true; report(nil)
        Task { report(await app.renewSelfSignedCertificate(cert.id, days: days)); working = false }
    }

    private func statusColor(_ info: CertificateInfo?) -> Color {
        guard let info else { return .secondary }
        return info.isExpired ? .red : info.expiresSoon ? .orange : .green
    }

    private func statusText(_ info: CertificateInfo) -> String {
        if info.isExpired { return String(localized: "Expired") }
        let days = info.daysLeft ?? 0
        return days <= 30 ? String(localized: "Expires in \(days) days") : String(localized: "Valid")
    }
}

// MARK: - Sheets

private struct CertificateCreateSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var names = ""
    @State private var days = 365
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "checkmark.seal", title: "Create Self-Signed Certificate", subtitle: "Certificates", tint: .green)
            FormRow(label: "Name", labelWidth: 120) { TextField("My dev certificate", text: $name).textFieldStyle(.roundedBorder) }
            FormRow(label: "Names", labelWidth: 120) {
                TextField("mysite.localhost *.test 127.0.0.1", text: $names).textFieldStyle(.roundedBorder).font(.body.monospaced())
            }
            Text("Host names and IP addresses the certificate covers, separated by spaces. Wildcards such as *.test are fine.")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 132)
            FormRow(label: "Valid For", labelWidth: 120) {
                Picker("", selection: $days) {
                    Text("90 Days").tag(90); Text("1 Year").tag(365); Text("2 Years").tag(730)
                }.labelsHidden().fixedSize()
            }
            if let error { ErrorBanner(text: error) { self.error = nil } }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Create") {
                    working = true; error = nil
                    Task {
                        let problem = await app.createSelfSignedCertificate(name: name, names: names, days: days)
                        working = false
                        if let problem { error = problem } else { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).glassButton(prominent: true).disabled(working)
            }
        }
        .padding(26).frame(width: 560)
    }
}

private struct CertificateImportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var certificate = ""
    @State private var key = ""
    @State private var chain = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "square.and.arrow.down", title: "Import Certificate", subtitle: "Certificates", tint: .green)
            FormRow(label: "Name", labelWidth: 120) { TextField("example.com", text: $name).textFieldStyle(.roundedBorder) }
            FormRow(label: "Certificate", labelWidth: 120) { fileField($certificate, prompt: "Certificate file (.pem, .crt)") }
            FormRow(label: "Private Key", labelWidth: 120) { fileField($key, prompt: "Key file (.pem, .key)") }
            FormRow(label: "Chain", labelWidth: 120) { fileField($chain, prompt: "Optional") }
            Text("PEM files only. Leave the private key empty if it's in the certificate file. The chain holds intermediate certificates, if your provider gave you a separate file.")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 132)
            if let error { ErrorBanner(text: error) { self.error = nil } }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Import") {
                    working = true; error = nil
                    Task {
                        let problem = await app.importCertificate(name: name, certificatePath: certificate, keyPath: key, chainPath: chain)
                        working = false
                        if let problem { error = problem } else { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).glassButton(prominent: true).disabled(working)
            }
        }
        .padding(26).frame(width: 580)
    }

    private func fileField(_ path: Binding<String>, prompt: LocalizedStringKey) -> some View {
        HStack {
            TextField(prompt, text: path).textFieldStyle(.roundedBorder)
            Button("Choose…") {
                if let p = FolderPicker.choose(files: true) {
                    path.wrappedValue = p
                    if name.isEmpty { name = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent }
                }
            }
        }
    }
}

private struct CertificateRenameSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "pencil", title: "Rename Certificate", subtitle: "Certificates", tint: .green)
            FormRow(label: "Name", labelWidth: 100) { TextField("", text: $name).textFieldStyle(.roundedBorder) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { app.renameCertificate(id, to: name); dismiss() }
                    .keyboardShortcut(.defaultAction).glassButton(prominent: true)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(26).frame(width: 440)
        .onAppear { name = app.storedCertificate(id)?.name ?? "" }
    }
}
