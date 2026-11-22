// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var app
    private let system = SystemStatus.shared
    enum Tab: String, CaseIterable { case overview = "Overview", storage = "Storage", components = "Components" }
    @State private var tab: Tab = .overview
    @State private var editingName = false
    @State private var editingHost = false

    var body: some View {
        DetailPage {
            PageHeader(symbol: "macmini", title: "\(system.computerName)",
                       subtitle: "\(system.hostName)", tint: .gray, image: SystemIcon.thisMac)
            TabStrip(selection: $tab)
        } content: {
            switch tab {
            case .overview: overview
            case .storage: StorageTab()
            case .components: ComponentsList()
            }
        }
        .sheet(isPresented: $editingName) { ComputerNameSheet() }
        .sheet(isPresented: $editingHost) { HostNameSheet() }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                FormRow(label: "Computer Name") {
                    HStack(spacing: 10) {
                        Text(system.computerName)
                        Button("Edit…") { editingName = true }.glassButton()
                    }
                }
                FormRow(label: "Host Name") {
                    HStack(spacing: 10) {
                        Text(system.hostName).textSelection(.enabled)
                        Button("Edit…") { editingHost = true }.glassButton()
                    }
                }
                FormRow(label: "Version") {
                    Text("\(SystemInfo.osVersion) · \(Homebrew.defaultPrefix == "/opt/homebrew" ? "Apple Silicon" : "Intel")")
                }
                FormRow(label: "Uptime") {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(SystemStatus.format(uptime: system.uptime))
                            .help("Up since \(system.bootTime.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                FormRow(label: "Homebrew") {
                    HStack(spacing: 8) {
                        StatusDot(color: app.brew.brewPath == nil ? .orange : .green)
                        Text(app.brew.brewPath ?? "Not installed")
                    }
                }
                FormRow(label: "Websites") {
                    Text("\(app.config.websites.filter(\.enabled).count) enabled of \(app.config.websites.count)")
                }
            }
            ReachabilityCard()
            Card(title: "Services") {
                ForEach(ServiceKind.allCases) { kind in
                    FormRow(label: "\(kind.title)") { ServiceControl(kind: kind) }
                }
                FormRow(label: "PHP-FPM") {
                    Text(app.phpRunning.isEmpty ? "No PHP pools running"
                         : app.phpRunning.sorted().map { Homebrew.phpLabel($0, version: app.brew.version($0)) }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            Card(footer: "When off, services keep running in the background after you quit, like macOS Server.") {
                Toggle("Stop all services when Server quits", isOn: app.bind(\.stopServicesOnQuit))
            }
        }
    }
}

/// Internet reachability with the public and local addresses.
struct ReachabilityCard: View {
    private let system = SystemStatus.shared
    @State private var localIP: String?
    @State private var wifiName: String?

    var body: some View {
        Card(title: "Reachability",
             footer: "The public address is looked up with ipify.org. Whether others can reach this Mac also depends on your router and firewall.") {
            FormRow(label: "Status") {
                HStack(spacing: 8) {
                    StatusDot(color: color)
                    Text(system.reachability.label)
                    if !system.connection.isEmpty && system.reachability != .offline {
                        Text("via \(system.connection)\(wifiName.map { " (\($0))" } ?? "")").foregroundStyle(.secondary)
                    }
                }
            }
            FormRow(label: "Public IP Address") {
                HStack(spacing: 8) {
                    Text(system.publicIP ?? (system.checkingPublicIP ? "Looking up…" : "Unavailable"))
                        .textSelection(.enabled)
                        .foregroundStyle(system.publicIP == nil ? .secondary : .primary)
                    if system.checkingPublicIP {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await system.refreshPublicIP() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Check again").accessibilityLabel("Check Again")
                    }
                }
            }
            FormRow(label: "Local IP Address") {
                Text(localIP ?? "—").textSelection(.enabled).foregroundStyle(localIP == nil ? .secondary : .primary)
            }
        }
        .task(id: "\(system.reachability)\(system.connection)\(WiFiAccess.shared.status.rawValue)") {
            localIP = SystemStatus.demo ? "192.168.1.20" : await Task.detached { NetworkScanner.primaryIPv4() }.value
            wifiName = system.connection == "Wi-Fi" ? await Task.detached { WiFiAccess.ssid() }.value : nil
        }
    }

    private var color: Color {
        switch system.reachability {
        case .internet: .green
        case .localOnly: .orange
        case .offline: .red
        case .checking: .secondary
        }
    }
}

/// Edits the computer name, like General › Sharing in System Settings.
struct ComputerNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let system = SystemStatus.shared
    @State private var name = SystemStatus.shared.computerName
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NameSheet(title: "Computer Name", subtitle: "Shown in Finder, AirDrop and Sharing",
                  note: "macOS asks for an administrator password to change it.",
                  error: error, working: working,
                  canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty && name != system.computerName,
                  save: save) {
            FormRow(label: "Computer Name", labelWidth: 130) {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func save() {
        working = true
        Task {
            let result = await system.setComputerName(name)
            working = false
            if result == nil { dismiss() } else { error = result }
        }
    }
}

/// Edits the local host name, the "name.local" address other devices reach this Mac at.
struct HostNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let system = SystemStatus.shared
    @State private var host = SystemStatus.shared.localHostName
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NameSheet(title: "Host Name", subtitle: "The address other devices use to reach this Mac",
                  note: "Other devices on your network reach this Mac at \(host.isEmpty ? "…" : host).local. macOS asks for an administrator password to change it.",
                  error: error, working: working,
                  canSave: problem == nil && host != system.localHostName,
                  save: save) {
            FormRow(label: "Local Host Name", labelWidth: 130) {
                HStack(spacing: 6) {
                    TextField("Host name", text: $host).textFieldStyle(.roundedBorder)
                    Text(".local").foregroundStyle(.secondary)
                }
            }
            if let problem, !host.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.orange).padding(.leading, 142)
            }
            HStack {
                Spacer().frame(width: 142)
                Button("Use Name Based on Computer Name") { host = SystemStatus.localHostName(for: system.computerName) }
                    .buttonStyle(.link).font(.caption)
                    .disabled(host == SystemStatus.localHostName(for: system.computerName))
            }
        }
    }

    private var problem: String? { SystemStatus.hostNameProblem(host) }

    private func save() {
        working = true
        Task {
            let result = await system.setLocalHostName(host)
            working = false
            if result == nil { dismiss() } else { error = result }
        }
    }
}

/// Shared layout for the two name sheets.
struct NameSheet<Fields: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let note: String
    let error: String?
    let working: Bool
    let canSave: Bool
    let save: () -> Void
    @ViewBuilder var fields: Fields

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(symbol: "macmini", title: "\(title)", subtitle: "\(subtitle)", image: SystemIcon.thisMac)
            fields
            if let error, !error.isEmpty { ErrorBanner(text: error) }
            Text(note).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
                    .disabled(working || !canSave)
            }
        }
        .padding(26)
        .frame(width: 520)
    }
}

/// Homebrew formulae Server can manage, with install / remove buttons.
struct ComponentsList: View {
    @Environment(AppState.self) private var app
    @State private var working: String?

    /// Everything Server can install. Old PHP versions (community tap) appear once installed; add them on the PHP page.
    private var componentItems: [(String, String)] {
        var items: [(String, String)] = [("httpd", "Apache HTTP Server"), ("nginx", "Nginx")]
        for f in Homebrew.mysqlFormulae { items.append((f, f == "mysql@8.4" ? "MySQL 8.4 LTS" : "MySQL (latest)")) }
        for f in Homebrew.phpFormulae where !PHPCatalog.needsTap(f) || app.brew.isInstalled(f) {
            items.append((f, phpTitle(f, brew: app.brew)))
        }
        items.append((FTPServer.formula, "Pure-FTPd (FTP server)"))
        items.append((DNSServer.formula, "dnsmasq (DNS server)"))
        items.append((AIServer.formula, "afm-cli (Apple Foundation Model)"))
        items.append((RedisServer.formula, "Redis (key-value store)"))
        return items
    }

    var body: some View {
        let items = componentItems
        Card(footer: "Installed with Homebrew. Upgrades for the components your websites use run automatically every time Server opens.") {
            ForEach(items, id: \.0) { formula, title in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(formula).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let v = app.brew.version(formula), app.brew.isInstalled(formula) {
                        Text(v).foregroundStyle(.secondary).monospacedDigit()
                        StatusDot(color: .green)
                    } else if working == formula {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Install") {
                            working = formula
                            Task { await app.brew.ensureInstalled(formula); await app.applyConfiguration(); working = nil }
                        }
                        .glassButton()
                        .disabled(app.brew.brewPath == nil)
                    }
                }
                if formula != items.last?.0 { Divider() }
            }
        }
    }
}
