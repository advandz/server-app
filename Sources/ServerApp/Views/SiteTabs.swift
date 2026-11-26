// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

// MARK: - Node.js

/// Node.js version for a site: nvm's default, or a specific installed version.
struct NodeVersionPicker: View {
    @Binding var selection: String
    var body: some View {
        let installed = NVM.installed()
        Picker("", selection: $selection) {
            Text("Default (nvm)").tag("")
            if !installed.isEmpty { Divider() }
            ForEach(installed, id: \.self) { Text("Node.js \($0.dropFirst())").tag($0) }
            if !selection.isEmpty && !installed.contains(selection) {
                Text("Node.js \(selection.dropFirst()) — not installed").tag(selection)
            }
        }
        .labelsHidden().fixedSize()
    }
}

/// How the Node.js app is started, and whether it's running.
struct NodeAppCard: View {
    @Environment(AppState.self) private var app
    let siteID: UUID

    var body: some View {
        let site = app.site(siteID) ?? .placeholder
        let running = app.nodeRunning.contains(siteID)
        Card(title: "Node.js App",
             footer: "Server runs this command in the site folder while \(site.server.title) is running, with PORT set, and forwards requests for \(site.hostname) to it.") {
            FormRow(label: "Start Command") {
                TextField("npm start", text: app.bindSite(siteID, \.node.command)).textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
            FormRow(label: "App Port") { NumberField(value: app.bindSite(siteID, \.node.port)) }
            FormRow(label: "Environment") {
                TextEditor(text: app.bindSite(siteID, \.node.environment))
                    .font(.callout.monospaced())
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if site.node.environment.isEmpty {
                            Text("NODE_ENV=development").font(.callout.monospaced()).foregroundStyle(.tertiary)
                                .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                        }
                    }
            }
            FormRow(label: "Status") {
                HStack(spacing: 10) {
                    StatusDot(color: running ? .green : .secondary)
                    Text(running ? "Running on port \(String(site.node.port))"
                         : app.isRunning(site.server == .apache ? .apache : .nginx) ? "Not running" : "Starts with \(site.server.title)")
                        .foregroundStyle(.secondary)
                    if running {
                        Button("Restart") { Task { await app.restartNodeApp(site) } }.glassButton()
                    }
                    Button("Show Output") {
                        let log = AppState.nodeLogFile(site)
                        if FileManager.default.fileExists(atPath: log) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log)])
                        }
                    }
                    .buttonStyle(.link)
                }
            }
            if let err = app.nodeErrors[siteID] {
                ErrorBanner(text: err) { app.nodeErrors[siteID] = nil }
            }
        }
    }
}

// MARK: - General

struct SiteGeneralTab: View {
    @Environment(AppState.self) private var app
    let siteID: UUID

    var body: some View {
        let site = app.site(siteID) ?? .placeholder
        let conflicts = app.config.portConflicts
        VStack(alignment: .leading, spacing: 20) {
            Card {
                FormRow(label: "Status") {
                    Toggle("Website enabled", isOn: app.bindSite(siteID, \.enabled)).toggleStyle(.switch)
                }
                FormRow(label: "Name") {
                    TextField("", text: app.bindSite(siteID, \.name)).textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Host Name") {
                    TextField("", text: app.bindSite(siteID, \.hostname)).textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Aliases") {
                    TextField("www.mysite.localhost (space separated)", text: app.bindSite(siteID, \.aliases))
                        .textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Document Root") {
                    HStack {
                        Text(site.documentRoot).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Choose…") {
                            if let p = FolderPicker.choose(startingAt: site.documentRoot) { app.bindSite(siteID, \.documentRoot).wrappedValue = p }
                        }
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: site.documentRoot)) } label: { Image(systemName: "folder") }
                            .help("Show in Finder")
                    }
                }
            }
            Card(title: "Runtime") {
                FormRow(label: "Web Server") {
                    Picker("", selection: app.bindSite(siteID, \.server)) {
                        ForEach(WebServer.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                FormRow(label: "Runtime") {
                    Picker("", selection: app.bindSite(siteID, \.runtime)) {
                        ForEach(SiteRuntime.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if site.isNode {
                    FormRow(label: "Node.js Version") { NodeVersionPicker(selection: app.bindSite(siteID, \.node.version)) }
                } else {
                    FormRow(label: "PHP Version") { PHPPicker(selection: app.bindSite(siteID, \.phpFormula)) }
                    PHPNotice(formula: site.phpFormula)
                }
            }
            if site.isNode { NodeAppCard(siteID: siteID) }
            Card(title: "Ports", footer: "Defaults come from the \(site.server.title) settings in the sidebar.") {
                PortRow(label: "HTTP Port", value: app.bindSite(siteID, \.customHTTPPort),
                        defaultPort: site.server == .apache ? app.config.apache.httpPort : app.config.nginx.httpPort)
                PortRow(label: "HTTPS Port", value: app.bindSite(siteID, \.customHTTPSPort),
                        defaultPort: site.server == .apache ? app.config.apache.httpsPort : app.config.nginx.httpsPort)
                if !conflicts.isEmpty {
                    ErrorBanner(text: "Apache and Nginx are both configured to use port \(conflicts.sorted().map(String.init).joined(separator: ", ")). Only one server can use a port at a time.")
                }
            }
        }
    }
}

struct PortRow: View {
    let label: String
    @Binding var value: Int?
    let defaultPort: Int
    var body: some View {
        FormRow(label: "\(label)") {
            HStack(spacing: 12) {
                Toggle("Use default (\(String(defaultPort)))", isOn: Binding(
                    get: { value == nil },
                    set: { value = $0 ? nil : defaultPort }))
                if value != nil {
                    NumberField(value: Binding(get: { value ?? defaultPort }, set: { value = $0 }))
                }
            }
        }
    }
}

extension AppConfig {
    var portConflicts: Set<Int> {
        guard !websites.isEmpty else { return [] }
        return ports(for: .apache).intersection(ports(for: .nginx))
    }
}

// MARK: - Apache overrides

struct SiteApacheTab: View {
    @Environment(AppState.self) private var app
    let siteID: UUID

    var body: some View {
        let site = app.site(siteID) ?? .placeholder
        let b = { (kp: WritableKeyPath<ApacheSiteOverrides, Bool>) in app.bindSite(siteID, (\Website.apache).appending(path: kp)) }
        let s = { (kp: WritableKeyPath<ApacheSiteOverrides, String>) in app.bindSite(siteID, (\Website.apache).appending(path: kp)) }
        VStack(alignment: .leading, spacing: 20) {
            if site.server != .apache {
                InactiveNote(server: "Apache", active: site.server.title)
            }
            Card(title: "Options for <Directory> directive") {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow { Toggle("Indexes", isOn: b(\.indexes)); Toggle("FollowSymLinks", isOn: b(\.followSymLinks)); Toggle("MultiViews", isOn: b(\.multiViews)) }
                    GridRow { Toggle("Includes", isOn: b(\.includes)); Toggle("IncludesNOEXEC", isOn: b(\.includesNoExec)); Color.clear.frame(width: 1, height: 1) }
                    GridRow { Toggle("SymLinksIfOwnerMatch", isOn: b(\.symLinksIfOwnerMatch)); Toggle("ExecCGI", isOn: b(\.execCGI)); Color.clear.frame(width: 1, height: 1) }
                }
                Divider()
                FormRow(label: "AllowOverride", labelWidth: 120) {
                    HStack {
                        Picker("", selection: s(\.allowOverride)) {
                            Text("All").tag("All"); Text("None").tag("None")
                            if !["All", "None"].contains(site.apache.allowOverride) { Text("Custom").tag(site.apache.allowOverride) }
                        }.labelsHidden().fixedSize()
                        TextField("e.g. AuthConfig FileInfo", text: s(\.allowOverride)).textFieldStyle(.roundedBorder)
                    }
                }
                FormRow(label: "Require", labelWidth: 120) {
                    VStack(alignment: .leading, spacing: 4) {
                        CodeEditor(text: s(\.require), height: 54)
                        Text("“all granted”, or one IP address / range per line (e.g. 127.0.0.1).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Card(title: "Additional parameters for <Directory> directive") { CodeEditor(text: s(\.directoryParams)) }
            Card {
                FormRow(label: "Directory Index", labelWidth: 120) {
                    TextField("index.php index.html (empty = default)", text: s(\.directoryIndex)).textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Server Admin", labelWidth: 120) {
                    TextField("e-mail address or empty", text: s(\.serverAdmin)).textFieldStyle(.roundedBorder)
                }
            }
            Card(title: "Additional parameters for <VirtualHost> directive",
                 footer: "Entered exactly as it should appear in httpd.conf. Changes are validated with httpd -t before they are applied.") {
                CodeEditor(text: s(\.virtualHostParams), height: 100)
            }
        }
    }
}

struct InactiveNote: View {
    let server: String
    let active: String
    var body: some View {
        Label("This website is served by \(active). These \(server) settings are kept and apply if you switch it to \(server).",
              systemImage: "info.circle")
            .font(.callout).foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Nginx overrides

struct SiteNginxTab: View {
    @Environment(AppState.self) private var app
    let siteID: UUID

    var body: some View {
        let site = app.site(siteID) ?? .placeholder
        let s = { (kp: WritableKeyPath<NginxSiteOverrides, String>) in app.bindSite(siteID, (\Website.nginx).appending(path: kp)) }
        VStack(alignment: .leading, spacing: 20) {
            if site.server != .nginx {
                InactiveNote(server: "Nginx", active: site.server.title)
            }
            Card {
                FormRow(label: "Directory Index", labelWidth: 120) {
                    HStack {
                        TextField("index.php index.html (empty = default)", text: s(\.directoryIndex)).textFieldStyle(.roundedBorder)
                        Toggle("AutoIndex", isOn: app.bindSite(siteID, \.nginx.autoindex))
                    }
                }
                FormRow(label: "try_files", labelWidth: 120) {
                    TextField(site.phpFormula.isEmpty ? "$uri $uri/ =404" : "$uri $uri/ /index.php?$query_string",
                              text: s(\.tryFiles)).textFieldStyle(.roundedBorder)
                }
            }
            Card(title: "Additional parameters for location /") { CodeEditor(text: s(\.locationParams)) }
            Card(title: "Access Limits", footer: "One value per line: an IP address, a range (192.168.1.0/24), unix: or all. Leave allow empty to allow everyone.") {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading) { Text("allow").font(.callout); CodeEditor(text: s(\.allow), height: 60) }
                    VStack(alignment: .leading) { Text("deny").font(.callout); CodeEditor(text: s(\.deny), height: 60) }
                }
            }
            Card(title: "Additional parameters for server directive",
                 footer: "Entered exactly as it should appear in nginx.conf; don't forget the semicolons. Validated with nginx -t before it is applied.") {
                CodeEditor(text: s(\.serverParams), height: 100)
            }
        }
    }
}

// MARK: - SSL

struct SiteSSLTab: View {
    @Environment(AppState.self) private var app
    let siteID: UUID

    var body: some View {
        let site = app.site(siteID) ?? .placeholder
        let paths = ConfigGenerator.certificatePaths(site)
        VStack(alignment: .leading, spacing: 20) {
            Card {
                FormRow(label: "HTTPS") {
                    Toggle("Enable SSL for this website", isOn: app.bindSite(siteID, \.ssl.enabled)).toggleStyle(.switch)
                }
                if site.ssl.enabled {
                    FormRow(label: "Port") { Text("\(app.config.httpsPort(site))").monospacedDigit() }
                    FormRow(label: "Redirect") {
                        Toggle("Redirect HTTP requests to HTTPS", isOn: app.bindSite(siteID, \.ssl.redirectHTTP))
                    }
                }
            }
            if site.ssl.enabled {
                Card(title: "Certificate") {
                    FormRow(label: "Source") {
                        Picker("", selection: app.bindSite(siteID, \.ssl.mode)) {
                            Text("Self-signed (generated by Server)").tag(SSLSettings.Mode.selfSigned)
                            Text("Custom certificate files").tag(SSLSettings.Mode.custom)
                            Text("A stored certificate").tag(SSLSettings.Mode.stored)
                        }.labelsHidden().fixedSize()
                    }
                    if site.ssl.mode == .selfSigned {
                        FormRow(label: "Covers") { Text(site.allHostnames.joined(separator: ", ")).foregroundStyle(.secondary) }
                        FormRow(label: "Certificate") {
                            Text(FileManager.default.fileExists(atPath: paths.cert) ? paths.cert : "Generated when settings are applied")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        FormRow(label: "") {
                            HStack {
                                Button("Trust in Keychain…") { Task { await app.trustCertificate(site) } }
                                    .glassButton()
                                    .disabled(!FileManager.default.fileExists(atPath: paths.cert))
                                Button("Regenerate") {
                                    try? FileManager.default.removeItem(atPath: (paths.cert as NSString).deletingLastPathComponent)
                                    Task { await app.applyConfiguration() }
                                }.glassButton()
                            }
                        }
                        Text("Trusting the certificate stops browser warnings for this website. macOS asks for your password.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if site.ssl.mode == .custom {
                        FileRow(label: "Certificate File", path: app.bindSite(siteID, \.ssl.certificatePath))
                        FileRow(label: "Key File", path: app.bindSite(siteID, \.ssl.keyPath))
                    } else {
                        FormRow(label: "Certificate") {
                            CertificatePicker(selection: app.bindSite(siteID, \.ssl.certificateID))
                        }
                        if let id = site.ssl.certificateID, let info = app.certificateInfo[id] {
                            FormRow(label: "Covers") { Text(info.names.joined(separator: ", ")).foregroundStyle(.secondary) }
                            FormRow(label: "Expires") {
                                Text(info.notAfter?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                                    .foregroundStyle(info.isExpired ? Color.red : info.expiresSoon ? Color.orange : Color.secondary)
                            }
                            if let missing = site.allHostnames.first(where: { !info.covers($0) }) {
                                Text("This certificate doesn't cover \(missing). Browsers will warn about it.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        } else if site.ssl.certificateID == nil {
                            Text(app.config.certificates.isEmpty ? "Add a certificate on the Certificates page first." : "Choose a certificate to use for this website.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task { await app.loadAllCertificateInfo() }
    }
}

struct FileRow: View {
    let label: String
    @Binding var path: String
    var body: some View {
        FormRow(label: "\(label)") {
            HStack {
                TextField("/path/to/file.pem", text: $path).textFieldStyle(.roundedBorder)
                Button("Choose…") { if let p = FolderPicker.choose(files: true) { path = p } }
            }
        }
    }
}

// MARK: - Databases

struct SiteDatabasesTab: View {
    @Environment(AppState.self) private var app
    let siteID: UUID
    @State private var showingCreate = false
    @State private var error: String?
    @State private var pendingDrop: DatabaseRecord?

    var body: some View {
        let mine = app.config.databases.filter { $0.websiteID == siteID }
        let free = app.config.databases.filter { $0.websiteID == nil }
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                StatusDot(color: app.state(.mysql).color)
                Text("MySQL \(app.state(.mysql).label.lowercased())").foregroundStyle(.secondary)
                Spacer()
                if !free.isEmpty {
                    Menu("Assign Existing") {
                        ForEach(free) { db in Button(db.name) { app.assign(db, to: siteID) } }
                    }.fixedSize()
                }
                Button("Create Database…") { showingCreate = true }.glassButton(prominent: true)
            }
            if let error { ErrorBanner(text: error) { self.error = nil } }
            if mine.isEmpty {
                Card {
                    Text("No databases are assigned to this website yet. Create one and Server will add a dedicated MySQL user with access to it.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(mine) { db in
                DatabaseCard(record: db, port: app.config.mysql.port) {
                    app.assign(db, to: nil)
                } onDrop: { pendingDrop = db }
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateDatabaseSheet(siteID: siteID, suggested: (app.site(siteID)?.slug ?? "site").replacingOccurrences(of: "-", with: "_"))
        }
        .confirmationDialog("Delete database \(pendingDrop?.name ?? "")?", isPresented: Binding(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } })) {
            Button("Delete Database and User", role: .destructive) {
                if let db = pendingDrop { Task { error = await app.dropDatabase(db) } }
            }
        } message: { Text("All tables and data in this database are permanently deleted.") }
    }
}

struct DatabaseCard: View {
    let record: DatabaseRecord
    let port: Int
    var onUnassign: () -> Void
    var onDrop: () -> Void
    @State private var reveal = false

    var body: some View {
        Card {
            HStack {
                Image(systemName: "cylinder.split.1x2.fill").foregroundStyle(.orange)
                Text(record.name).font(.headline)
                Spacer()
                Menu {
                    Button("Unassign from Website", action: onUnassign)
                    Divider()
                    Button("Delete Database…", role: .destructive, action: onDrop)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            FormRow(label: "Host", labelWidth: 100) { copyable("127.0.0.1") }
            FormRow(label: "Port", labelWidth: 100) { copyable("\(port)") }
            FormRow(label: "Database", labelWidth: 100) { copyable(record.name) }
            FormRow(label: "User", labelWidth: 100) { copyable(record.user) }
            FormRow(label: "Password", labelWidth: 100) {
                HStack {
                    Text(reveal ? record.password : String(repeating: "•", count: 12)).font(.system(.body, design: .monospaced))
                    Button(reveal ? "Hide" : "Show") { reveal.toggle() }.buttonStyle(.link)
                    copyButton(record.password)
                }
            }
        }
    }

    private func copyable(_ text: String) -> some View {
        HStack { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled); copyButton(text) }
    }
    private func copyButton(_ text: String) -> some View {
        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: {
            Image(systemName: "doc.on.doc")
        }.buttonStyle(.borderless).help("Copy")
    }
}

struct CreateDatabaseSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let siteID: UUID?
    let suggested: String
    @State private var name = ""
    @State private var user = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(symbol: "cylinder.split.1x2", title: "New Database", subtitle: siteID == nil ? "Not assigned to a website" : "\(app.site(siteID)?.name ?? "")", tint: .orange)
            FormRow(label: "Database Name", labelWidth: 120) { TextField("", text: $name).textFieldStyle(.roundedBorder) }
            FormRow(label: "User Name", labelWidth: 120) { TextField(name, text: $user).textFieldStyle(.roundedBorder) }
            Text("A random password is generated. Letters, numbers and underscores only.").font(.caption).foregroundStyle(.secondary)
            if let error { ErrorBanner(text: error) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Creating…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    working = true
                    Task {
                        error = await app.createDatabase(name: name, user: user.isEmpty ? nil : user, for: siteID)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).glassButton(prominent: true)
                .disabled(name.isEmpty || working)
            }
        }
        .padding(26)
        .frame(width: 500)
        .onAppear { name = String(suggested.prefix(48)) }
    }
}
