// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

struct DNSView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", records = "Records", settings = "Settings" }
    @State private var tab: Tab = .overview

    var body: some View {
        DetailPage {
            PageHeader(symbol: "point.3.filled.connected.trianglepath.dotted", title: "DNS",
                       subtitle: "Local DNS server (dnsmasq)", tint: .teal) {
                ServiceControl(kind: .dns)
            }
            TabStrip(selection: $tab)
        } content: {
            switch tab {
            case .overview: DNSOverviewTab()
            case .records: DNSRecordsTab()
            case .settings: DNSSettingsTab()
            }
        }
    }
}

// MARK: - Overview

struct DNSOverviewTab: View {
    @Environment(AppState.self) private var app
    @State private var name = ""
    @State private var type = "A"
    @State private var answer: String?
    @State private var localIP: String?

    var body: some View {
        let s = app.config.dns
        VStack(alignment: .leading, spacing: 20) {
            ServiceOverviewCard(kind: .dns, formula: DNSServer.formula, configFile: DNSServer.confFile)
            Card(title: "Answering",
                 footer: s.allowNetwork
                    ? "Other devices can use this Mac as their DNS server by setting it in their network settings."
                    : "Only this Mac can query the server. Turn on network access in Settings to serve other devices.") {
                FormRow(label: "Answers") { Text(s.allowNetwork ? "This Mac and devices on the network" : "This Mac only") }
                FormRow(label: "Server Address") {
                    Text(s.allowNetwork ? (localIP ?? "—") + (s.port == 53 ? "" : " port \(s.port)") : "127.0.0.1" + (s.port == 53 ? "" : " port \(s.port)"))
                        .textSelection(.enabled)
                }
                FormRow(label: "Forwards To") {
                    Text(s.useCustomUpstream ? s.upstreamServers.joined(separator: ", ") : "This Mac's DNS servers").foregroundStyle(.secondary)
                }
                FormRow(label: "Local Domains") {
                    Text(s.domains.isEmpty ? "None" : s.domains.map { "*.\($0.name)" }.joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
            Card(title: "Look Up") {
                HStack {
                    TextField("name.test", text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
                        .onSubmit(lookUp)
                    Picker("", selection: $type) { ForEach(["A", "AAAA", "CNAME", "TXT", "MX"], id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().fixedSize()
                    Button("Look Up", action: lookUp).glassButton().disabled(name.isEmpty || !app.isRunning(.dns))
                }
                if let answer {
                    Text(answer).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !app.isRunning(.dns) { Text("Start the DNS server to look up names.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task { localIP = await Task.detached { NetworkScanner.primaryIPv4() }.value }
    }

    private func lookUp() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task { answer = await DNSServer.lookUp(n, type: type, port: app.config.dns.port) }
    }
}

// MARK: - Records

struct DNSRecordsTab: View {
    @Environment(AppState.self) private var app
    @State private var editingDomain: DNSDomain?
    @State private var editingRecord: DNSRecord?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let s = app.config.dns
        VStack(alignment: .leading, spacing: 20) {
            if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
            if let err = app.errors[.dns] { ErrorBanner(text: err) { app.errors[.dns] = nil } }
            Card(title: "Local Domains",
                 footer: "Every name under a local domain answers with its address, like *.test → this Mac. “Use on this Mac” sends those lookups to this server (/etc/resolver; asks for an administrator password).") {
                if s.domains.isEmpty { Text("No local domains.").foregroundStyle(.secondary) }
                ForEach(s.domains) { d in
                    HStack(spacing: 10) {
                        Text("*.\(d.name)").font(.body.monospaced()).frame(width: 180, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(d.address).font(.body.monospaced())
                        Spacer()
                        Toggle("Use on this Mac", isOn: Binding(get: { d.resolveOnMac }, set: { v in
                            update { c in if let i = c.domains.firstIndex(where: { $0.id == d.id }) { c.domains[i].resolveOnMac = v } }
                        }))
                        .toggleStyle(.checkbox)
                        // macOS ignores /etc/resolver entries for 127.0.0.1 on any port but 53.
                        .disabled(s.port != 53 && !d.resolveOnMac)
                        .help(s.port == 53 ? "Send *.\(d.name) lookups on this Mac to this server"
                              : "Only works when the DNS server uses port 53")
                        Button { editingDomain = d } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Edit").accessibilityLabel("Edit Domain")
                        Button {
                            update(removing: d) { c in c.domains.removeAll { $0.id == d.id } }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove Domain")
                    }
                    if d.id != s.domains.last?.id { Divider() }
                }
                HStack { Button("Add Domain…") { editingDomain = DNSDomain(name: "", address: "127.0.0.1") }.glassButton(); Spacer() }
            }
            Card(title: "Records") {
                if s.records.isEmpty { Text("No records. Add A, AAAA, CNAME, TXT or MX records for specific names.").foregroundStyle(.secondary) }
                ForEach(s.records) { r in
                    HStack(spacing: 10) {
                        Badge(text: r.kind.rawValue).frame(width: 60, alignment: .leading)
                        Text(r.name).font(.body.monospaced()).lineLimit(1).frame(width: 200, alignment: .leading)
                        Text(r.kind == .mx ? "\(r.value) (priority \(r.priority))" : r.value)
                            .font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { editingRecord = r } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Edit").accessibilityLabel("Edit Record")
                        Button { update { c in c.records.removeAll { $0.id == r.id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove Record")
                    }
                    if r.id != s.records.last?.id { Divider() }
                }
                HStack { Button("Add Record…") { editingRecord = DNSRecord() }.glassButton(); Spacer() }
            }
        }
        .disabled(working)
        .sheet(item: $editingDomain) { d in
            DNSDomainSheet(domain: d) { updated in
                update { c in
                    if let i = c.domains.firstIndex(where: { $0.id == updated.id }) { c.domains[i] = updated } else { c.domains.append(updated) }
                }
            }
        }
        .sheet(item: $editingRecord) { r in
            DNSRecordSheet(record: r) { updated in
                update { c in
                    if let i = c.records.firstIndex(where: { $0.id == updated.id }) { c.records[i] = updated } else { c.records.append(updated) }
                }
            }
        }
    }

    /// Saves the change, syncs /etc/resolver (one password prompt, only when something changes there)
    /// and restarts the server if it's running.
    private func update(removing domain: DNSDomain? = nil, _ change: @escaping (inout DNSSettings) -> Void) {
        working = true
        Task {
            var cmds: [[String]] = []
            if let domain, DNSServer.resolverInstalled(domain.name) { cmds.append(["/bin/rm", "-f", DNSServer.resolverFile(domain.name)]) }
            app.update { change(&$0.dns) }
            cmds += DNSServer.resolverCommands(app.config.dns)
            if !cmds.isEmpty, let result = await Privileged.run(cmds), !result.isEmpty { error = result }
            await app.applyDNS()
            working = false
        }
    }
}

struct DNSDomainSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var domain: DNSDomain
    var onSave: (DNSDomain) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "globe", title: "Local Domain", subtitle: "Answer every name under a domain", tint: .teal)
            FormRow(label: "Domain", labelWidth: 100) {
                HStack(spacing: 4) {
                    Text("*.").font(.body.monospaced()).foregroundStyle(.secondary)
                    TextField("test", text: $domain.name).textFieldStyle(.roundedBorder)
                }
            }
            FormRow(label: "Address", labelWidth: 100) {
                TextField("127.0.0.1", text: $domain.address).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            FormRow(label: "", labelWidth: 100) { Toggle("Use on this Mac", isOn: $domain.resolveOnMac) }
            Text("Use a name you don't need on the internet, such as test or localhost. Avoid .local, which macOS uses for Bonjour.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    domain.name = domain.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                    onSave(domain); dismiss()
                }
                .keyboardShortcut(.defaultAction).glassButton(prominent: true).disabled(problem != nil)
            }
        }
        .padding(26).frame(width: 500)
    }

    private var problem: String? {
        let n = domain.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if !DNSServer.isValidName(n) { return "Enter a domain such as test." }
        if n == "local" { return ".local is reserved for Bonjour on macOS." }
        if !HostEntry.isValidAddress(domain.address) { return "Enter a valid IPv4 or IPv6 address." }
        return nil
    }
}

struct DNSRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var record: DNSRecord
    var onSave: (DNSRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "list.bullet.rectangle", title: "DNS Record", subtitle: "Answer for a specific name", tint: .teal)
            FormRow(label: "Type", labelWidth: 100) {
                Picker("", selection: $record.kind) { ForEach(DNSRecord.Kind.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            FormRow(label: "Name", labelWidth: 100) {
                TextField("app.test", text: $record.name).textFieldStyle(.roundedBorder)
            }
            FormRow(label: record.kind == .cname || record.kind == .mx ? "Target" : record.kind == .txt ? "Text" : "Address", labelWidth: 100) {
                TextField(record.kind.valueHint, text: $record.value).textFieldStyle(.roundedBorder)
            }
            if record.kind == .mx {
                FormRow(label: "Priority", labelWidth: 100) { NumberField(value: $record.priority) }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    record.name = record.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                    record.value = record.value.trimmingCharacters(in: .whitespaces)
                    onSave(record); dismiss()
                }
                .keyboardShortcut(.defaultAction).glassButton(prominent: true).disabled(problem != nil)
            }
        }
        .padding(26).frame(width: 520)
    }

    private var problem: String? {
        let name = record.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let value = record.value.trimmingCharacters(in: .whitespaces)
        if !DNSServer.isValidName(name) { return "Enter a host name such as app.test." }
        if value.isEmpty { return "Enter a value." }
        switch record.kind {
        case .a: if !value.contains(".") || !HostEntry.isValidAddress(value) { return "Enter an IPv4 address." }
        case .aaaa: if !value.contains(":") || !HostEntry.isValidAddress(value) { return "Enter an IPv6 address." }
        case .cname, .mx: if !DNSServer.isValidName(value) { return "Enter a host name." }
        case .txt: break
        }
        return nil
    }
}

// MARK: - Settings

struct DNSSettingsTab: View {
    @Environment(AppState.self) private var app
    @State private var draft = DNSSettings()
    @State private var loaded = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let err = app.errors[.dns] { ErrorBanner(text: err) { app.errors[.dns] = nil } }
            Card(title: "Server") {
                FormRow(label: "Port") { NumberField(value: $draft.port) }
                FormRow(label: "Network") { Toggle("Answer devices on the local network, not just this Mac", isOn: $draft.allowNetwork) }
                FormRow(label: "Cache Size") { NumberField(value: $draft.cacheSize) }
            }
            Card(title: "Forwarding", footer: "Names the server doesn't know are looked up with these servers.") {
                FormRow(label: "Forward To") {
                    Picker("", selection: $draft.useCustomUpstream) {
                        Text("This Mac's DNS servers").tag(false)
                        Text("These servers").tag(true)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }
                if draft.useCustomUpstream {
                    FormRow(label: "Servers") {
                        TextField("1.1.1.1 1.0.0.1", text: $draft.upstream).textFieldStyle(.roundedBorder).frame(width: 300)
                    }
                }
            }
            Card(title: "Options") {
                FormRow(label: "Hosts File") { Toggle("Also answer with entries from /etc/hosts", isOn: $draft.answerFromHostsFile) }
                FormRow(label: "Logging") { Toggle("Log every query (Logs › DNS)", isOn: $draft.logQueries) }
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Revert") { draft = app.config.dns }.glassButton().disabled(draft == app.config.dns || saving)
                Button("Save") {
                    saving = true
                    let previousPort = app.config.dns.port
                    Task {
                        var d = draft
                        d.domains = app.config.dns.domains
                        d.records = app.config.dns.records
                        app.update { $0.dns = d }
                        // Resolver files carry the port; rewrite them if it changed.
                        if previousPort != d.port {
                            let cmds = DNSServer.resolverCommands(d, rewrite: true)
                            if !cmds.isEmpty { _ = await Privileged.run(cmds) }
                        }
                        await app.applyDNS()
                        saving = false
                    }
                }
                .glassButton(prominent: true)
                .disabled(draft == app.config.dns || saving)
            }
        }
        .onAppear { if !loaded { draft = app.config.dns; loaded = true } }
    }
}
