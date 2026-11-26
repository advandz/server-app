// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

/// Shared "Overview" card for a service: status, version, config file.
struct ServiceOverviewCard: View {
    @Environment(AppState.self) private var app
    let kind: ServiceKind
    let formula: String
    var configFile: String? = nil

    var body: some View {
        Card {
            FormRow(label: "Status") { ServiceControl(kind: kind) }
            FormRow(label: "Version") {
                Text(app.brew.version(formula).map { "\(formula) \($0)" } ?? "Not installed — installed automatically on first start")
                    .foregroundStyle(.secondary)
            }
            if let configFile {
            FormRow(label: "Configuration") {
                HStack {
                    Text(configFile).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configFile)]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                        .disabled(!FileManager.default.fileExists(atPath: configFile))
                }
            }
            }
        }
        if let err = app.errors[kind] { ErrorBanner(text: err) { app.errors[kind] = nil } }
    }
}

// MARK: - Apache

struct ApacheView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", settings = "Settings", modules = "Modules" }
    @State private var tab: Tab = .overview

    var body: some View {
        DetailPage {
            PageHeader(symbol: "server.rack", title: "Apache", subtitle: "Apache HTTP Server with PHP-FPM", tint: .red, glyph: SystemIcon.apacheMono) {
                ServiceControl(kind: .apache)
            }
            TabStrip(selection: $tab)
        } content: {
            switch tab {
            case .overview:
                VStack(alignment: .leading, spacing: 20) {
                    ServiceOverviewCard(kind: .apache, formula: "httpd", configFile: ConfigGenerator.apacheConfFile)
                    DefaultPortsCard(server: .apache, http: app.bind(\.apache.httpPort), https: app.bind(\.apache.httpsPort))
                }
            case .settings: ApacheSettingsTab()
            case .modules: ApacheModulesTab()
            }
        }
    }
}

struct DefaultPortsCard: View {
    @Environment(AppState.self) private var app
    let server: WebServer
    @Binding var http: Int
    @Binding var https: Int

    var body: some View {
        let sites = app.config.websites.filter { $0.server == server }
        let conflicts = app.config.portConflicts
        Card(title: "Default Ports", footer: "Used by every \(server.title) website that doesn't set its own ports.") {
            FormRow(label: "HTTP") { NumberField(value: $http) }
            FormRow(label: "HTTPS") { NumberField(value: $https) }
            FormRow(label: "Listening on") {
                Text(app.config.ports(for: server).sorted().map(String.init).joined(separator: ", ")).monospacedDigit().foregroundStyle(.secondary)
            }
            FormRow(label: "Websites") { Text("\(sites.filter(\.enabled).count) enabled").foregroundStyle(.secondary) }
            if !conflicts.isEmpty {
                ErrorBanner(text: "Port \(conflicts.sorted().map(String.init).joined(separator: ", ")) is used by both Apache and Nginx websites.")
            }
        }
    }
}

struct ApacheSettingsTab: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "General") {
                FormRow(label: "Server Admin") {
                    TextField("e-mail address or empty", text: app.bind(\.apache.serverAdmin)).textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Network") { Toggle("Accept connections from other devices", isOn: webNetwork(app)) }
                FormRow(label: "Log Level") { LogLevelPicker(selection: app.bind(\.apache.logLevel), levels: ["debug", "info", "notice", "warn", "error", "crit"]) }
                FormRow(label: "Server Tokens") { Toggle("Hide version details (ServerTokens Prod)", isOn: app.bind(\.apache.serverTokensProd)) }
            }
            Card(title: "Performance") {
                FormRow(label: "Timeout") { HStack { NumberField(value: app.bind(\.apache.timeout)); Text("seconds").foregroundStyle(.secondary) } }
                FormRow(label: "Keep-Alive") { Toggle("Allow persistent connections", isOn: app.bind(\.apache.keepAlive)) }
                FormRow(label: "Keep-Alive Timeout") { HStack { NumberField(value: app.bind(\.apache.keepAliveTimeout)); Text("seconds").foregroundStyle(.secondary) } }
                FormRow(label: "Max Request Workers") { NumberField(value: app.bind(\.apache.maxRequestWorkers)) }
            }
            Card(title: "Custom Configuration", footer: "Added to httpd.conf before the virtual hosts. Validated with httpd -t before it is applied.") {
                CodeEditor(text: app.bind(\.apache.customConfig), height: 120)
            }
        }
    }
}

struct LogLevelPicker: View {
    @Binding var selection: String
    let levels: [String]
    var body: some View {
        Picker("", selection: $selection) { ForEach(levels, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
    }
}

struct ApacheModulesTab: View {
    @Environment(AppState.self) private var app
    @State private var filter = ""

    var body: some View {
        let g = app.generator
        let modules = g.availableApacheModules().filter { filter.isEmpty || $0.shortName.localizedCaseInsensitiveContains(filter) }
        let enabled = g.enabledApacheModules()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Filter modules", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button("Restore Defaults") { app.update { $0.apache.enabledModules = nil } }.glassButton()
            }
            if modules.isEmpty {
                Card { Text(app.brew.isInstalled("httpd") ? "No modules match." : "Apache is not installed yet. Start it once to install it.").foregroundStyle(.secondary) }
            } else {
                VStack(spacing: 0) {
                    ForEach(modules) { m in
                        let required = ConfigGenerator.requiredApacheModules.contains(m.shortName)
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { enabled.contains(m.shortName) },
                                set: { on in app.update { c in
                                    var set = c.apache.enabledModules.map(Set.init) ?? ConfigGenerator.defaultApacheModules
                                    if on { set.insert(m.shortName) } else { set.remove(m.shortName) }
                                    c.apache.enabledModules = set.sorted()
                                } }))
                                .labelsHidden().disabled(required)
                            Text(m.name).font(.system(.body, design: .monospaced)).frame(width: 220, alignment: .leading)
                            Text(ApacheModuleInfo.describe(m.shortName) + (required ? " (required by Server)" : ""))
                                .foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 6).padding(.horizontal, 14)
                        Divider().opacity(0.5)
                    }
                }
                .padding(.vertical, 6)
                .glassPanel()
            }
        }
    }
}

enum ApacheModuleInfo {
    static let descriptions: [String: String] = [
        "access_compat": "Group authorizations based on host (name or IP address)",
        "actions": "Execute CGI scripts based on media type or request method",
        "alias": "Mapping parts of the filesystem and URL redirection",
        "allowmethods": "Restrict which HTTP methods can be used",
        "auth_basic": "Basic authentication", "auth_digest": "User authentication using MD5 Digest",
        "auth_form": "Form authentication", "authn_anon": "Anonymous user access to authenticated areas",
        "authn_core": "Core authentication", "authn_dbd": "User authentication using an SQL database",
        "authn_dbm": "User authentication using DBM files", "authn_file": "User authentication using text files",
        "authn_socache": "Cache authentication credentials", "authz_core": "Core authorization",
        "authz_dbd": "Group authorization and login using SQL", "authz_dbm": "Group authorization using DBM files",
        "authz_groupfile": "Group authorization using plaintext files", "authz_host": "Authorization based on host or IP",
        "authz_owner": "Authorization based on file ownership", "authz_user": "User authorization",
        "autoindex": "Generates directory listings", "brotli": "Brotli compression", "cache": "RFC 2616 HTTP caching",
        "cgi": "Execution of CGI scripts", "cgid": "CGI scripts using an external daemon", "dav": "WebDAV functionality",
        "deflate": "Compress content before delivery (gzip)", "dir": "Directory index files and trailing slash redirects",
        "env": "Modify the environment passed to CGI scripts and SSI", "expires": "Expires and Cache-Control headers",
        "filter": "Context-sensitive smart filter configuration", "headers": "Customize request and response headers",
        "http2": "HTTP/2 protocol support", "include": "Server-parsed HTML (SSI)", "info": "Server configuration overview page",
        "log_config": "Logging of requests", "mime": "Associate file extensions with content types",
        "negotiation": "Content negotiation (MultiViews)", "proxy": "HTTP/1.1 proxy and gateway",
        "proxy_fcgi": "FastCGI support for mod_proxy (PHP-FPM)", "proxy_http": "HTTP support for mod_proxy",
        "proxy_wstunnel": "WebSocket support for mod_proxy", "remoteip": "Replace client IP with proxy-provided IP",
        "reqtimeout": "Timeouts for receiving requests", "rewrite": "Rule-based URL rewriting",
        "setenvif": "Set environment variables based on the request", "socache_shmcb": "Shared memory cache provider (SSL sessions)",
        "speling": "Correct misspelled URLs", "ssl": "Strong cryptography with SSL/TLS", "status": "Server activity and performance",
        "substitute": "Search-and-replace on response bodies", "unique_id": "Unique identifier for each request",
        "unixd": "Basic Unix security", "userdir": "User-specific directories (~user)", "version": "Version-dependent configuration",
        "vhost_alias": "Dynamically configured mass virtual hosting", "mpm_event": "Event-based multi-processing module",
    ]
    static func describe(_ name: String) -> String { descriptions[name] ?? "" }
}

// MARK: - Nginx

struct NginxView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", settings = "Settings", extensions = "Extensions" }
    @State private var tab: Tab = .overview

    var body: some View {
        DetailPage {
            PageHeader(symbol: "bolt.horizontal", title: "Nginx", subtitle: "High-performance web server with PHP-FPM", tint: .green, glyph: SystemIcon.nginxMono) {
                ServiceControl(kind: .nginx)
            }
            TabStrip(selection: $tab)
        } content: {
            switch tab {
            case .overview:
                VStack(alignment: .leading, spacing: 20) {
                    ServiceOverviewCard(kind: .nginx, formula: "nginx", configFile: ConfigGenerator.nginxConfFile)
                    DefaultPortsCard(server: .nginx, http: app.bind(\.nginx.httpPort), https: app.bind(\.nginx.httpsPort))
                }
            case .settings: NginxSettingsTab()
            case .extensions: NginxExtensionsTab()
            }
        }
    }
}

struct NginxSettingsTab: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Workers") {
                FormRow(label: "Worker Processes") {
                    TextField("auto", text: app.bind(\.nginx.workerProcesses)).textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FormRow(label: "Worker Connections") { NumberField(value: app.bind(\.nginx.workerConnections)) }
            }
            Card(title: "HTTP") {
                FormRow(label: "Keep-Alive Timeout") { HStack { NumberField(value: app.bind(\.nginx.keepaliveTimeout)); Text("seconds").foregroundStyle(.secondary) } }
                FormRow(label: "Max Upload Size") {
                    TextField("64m", text: app.bind(\.nginx.clientMaxBodySize)).textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FormRow(label: "Network") { Toggle("Accept connections from other devices", isOn: webNetwork(app)) }
                FormRow(label: "Log Level") { LogLevelPicker(selection: app.bind(\.nginx.logLevel), levels: ["debug", "info", "notice", "warn", "error", "crit"]) }
            }
            Card(title: "Custom Configuration", footer: "Added inside the http { } block of nginx.conf. Validated with nginx -t before it is applied.") {
                CodeEditor(text: app.bind(\.nginx.customConfig), height: 120)
            }
        }
    }
}

struct NginxExtensionsTab: View {
    @Environment(AppState.self) private var app
    @State private var compiled: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Features", footer: "Homebrew's Nginx has its modules built in, so these are switched on or off in the configuration.") {
                ext("Gzip compression", "ngx_http_gzip_module — compress text responses", \.gzip)
                Divider()
                ext("Gzip static", "ngx_http_gzip_static_module — serve pre-compressed .gz files", \.gzipStatic)
                Divider()
                ext("HTTP/2", "ngx_http_v2_module — HTTP/2 on HTTPS websites", \.http2)
                Divider()
                ext("Status page", "ngx_http_stub_status_module — /nginx_status on the default server (localhost only)", \.stubStatus)
                Divider()
                ext("Sendfile", "Kernel sendfile() for static files", \.sendfile)
                Divider()
                ext("Server tokens", "Show the Nginx version in headers and error pages", \.serverTokens)
            }
            Card(title: "Compiled-in Modules") {
                if compiled.isEmpty {
                    Text(app.brew.isInstalled("nginx") ? "Loading…" : "Nginx is not installed yet.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(compiled, id: \.self) { m in
                            Label(m, systemImage: "checkmark.circle.fill").font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            let r = await Shell.run(app.generator.nginxBinary, ["-V"])
            compiled = r.output.split(separator: " ")
                .filter { $0.hasPrefix("--with-") && $0.hasSuffix("_module") }
                .map { String($0.dropFirst(7)) }
                .sorted()
        }
    }

    private func ext(_ title: String, _ detail: String, _ kp: WritableKeyPath<NginxSettings, Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: app.bind((\AppConfig.nginx).appending(path: kp))).labelsHidden().toggleStyle(.switch)
        }
    }
}

// MARK: - MySQL

struct MySQLView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", settings = "Settings", databases = "Databases" }
    @State private var tab: Tab = .overview
    @State private var passwordSheet: MySQLRootPasswordSheet.Mode?

    var body: some View {
        DetailPage {
            PageHeader(symbol: "cylinder.split.1x2", title: "MySQL", subtitle: "Database server", tint: .teal, glyph: SystemIcon.mysqlMono) {
                ServiceControl(kind: .mysql)
            }
            TabStrip(selection: $tab)
        } content: {
            switch tab {
            case .overview: overview
            case .settings: MySQLSettingsTab()
            case .databases: MySQLDatabasesTab()
            }
        }
        .sheet(item: $passwordSheet) { mode in MySQLRootPasswordSheet(mode: mode) }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            if app.mysqlNeedsRestart {
                HStack {
                    ErrorBanner(text: "Settings changed. Restart MySQL to apply them.")
                    Button("Restart Now") { Task { await app.restart(.mysql) } }.glassButton(prominent: true)
                }
            }
            ServiceOverviewCard(kind: .mysql, formula: app.config.mysql.formula, configFile: ConfigGenerator.mysqlConfFile)
            Card(title: "Connection", footer: app.mysqlRootPassword.isEmpty
                 ? "MySQL only listens on this Mac (127.0.0.1). The root user has no password; each website gets its own user."
                 : "MySQL only listens on this Mac (127.0.0.1). Each website gets its own user.") {
                FormRow(label: "Host") { Text("127.0.0.1").textSelection(.enabled) }
                FormRow(label: "Port") { Text("\(app.config.mysql.port)").monospacedDigit() }
                FormRow(label: "Socket") { Text(Paths.mysqlSocket).font(.caption).textSelection(.enabled) }
                FormRow(label: "Data Directory") {
                    Text(Paths.mysqlDataDir(app.config.mysql.formula)).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                FormRow(label: "Databases") { Text("\(app.config.databases.count) managed by Server").foregroundStyle(.secondary) }
            }
            Card(title: "Root Password",
                 footer: "Server keeps the root password so it can create databases for your websites. Reset Password works even if you've forgotten it: MySQL restarts briefly while it's set.") {
                FormRow(label: "Password") {
                    HStack(spacing: 10) {
                        if app.mysqlRootPassword.isEmpty {
                            Text("None (this Mac only)").foregroundStyle(.secondary)
                        } else {
                            Text("••••••••••••").foregroundStyle(.secondary)
                            CopyButton(text: app.mysqlRootPassword)
                        }
                        Spacer()
                        Button("Change Password…") { passwordSheet = .change }.glassButton()
                        Button("Reset Password…") { passwordSheet = .reset }.glassButton()
                    }
                }
            }
        }
    }
}

struct MySQLSettingsTab: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Server", footer: "Each MySQL version keeps its own data directory, so switching versions never upgrades your data in place.") {
                FormRow(label: "Version") {
                    Picker("", selection: app.bind(\.mysql.formula)) {
                        Text("MySQL 8.4 LTS (mysql@8.4)").tag("mysql@8.4")
                        Text("MySQL latest (mysql)").tag("mysql")
                    }.labelsHidden().fixedSize().disabled(app.isRunning(.mysql))
                }
                FormRow(label: "Port") { NumberField(value: app.bind(\.mysql.port)) }
                FormRow(label: "Max Connections") { NumberField(value: app.bind(\.mysql.maxConnections)) }
            }
            Card(title: "Memory & Limits") {
                FormRow(label: "InnoDB Buffer Pool") {
                    TextField("128M", text: app.bind(\.mysql.innodbBufferPoolSize)).textFieldStyle(.roundedBorder).frame(width: 90)
                }
                FormRow(label: "Max Allowed Packet") {
                    TextField("64M", text: app.bind(\.mysql.maxAllowedPacket)).textFieldStyle(.roundedBorder).frame(width: 90)
                }
            }
            Card(title: "Defaults") {
                FormRow(label: "Character Set") { TextField("utf8mb4", text: app.bind(\.mysql.characterSet)).textFieldStyle(.roundedBorder).frame(width: 160) }
                FormRow(label: "Collation") { TextField("utf8mb4_unicode_ci", text: app.bind(\.mysql.collation)).textFieldStyle(.roundedBorder).frame(width: 220) }
                FormRow(label: "SQL Mode") { TextField("server default", text: app.bind(\.mysql.sqlMode)).textFieldStyle(.roundedBorder) }
            }
            Card(title: "Custom Configuration", footer: "Added to the [mysqld] section of my.cnf. Takes effect after a restart.") {
                CodeEditor(text: app.bind(\.mysql.customConfig), height: 100)
            }
        }
    }
}

struct MySQLDatabasesTab: View {
    @Environment(AppState.self) private var app
    @State private var serverDBs: [String] = []
    @State private var showingCreate = false
    @State private var error: String?
    @State private var pendingDrop: DatabaseRecord?

    var body: some View {
        let managedNames = Set(app.config.databases.map(\.name))
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button("Create Database…") { showingCreate = true }.glassButton(prominent: true)
            }
            if let error { ErrorBanner(text: error) { self.error = nil } }
            Card(title: "Managed by Server") {
                if app.config.databases.isEmpty { Text("No databases yet.").foregroundStyle(.secondary) }
                ForEach(app.config.databases) { db in
                    HStack(spacing: 12) {
                        Image(systemName: "cylinder.split.1x2.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(db.name)
                            Text("user \(db.user)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Website", selection: Binding(get: { db.websiteID }, set: { app.assign(db, to: $0) })) {
                            Text("Unassigned").tag(UUID?.none)
                            ForEach(app.config.websites) { Text($0.name).tag(UUID?.some($0.id)) }
                        }.fixedSize()
                        Button(role: .destructive) { pendingDrop = db } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    if db.id != app.config.databases.last?.id { Divider() }
                }
            }
            let others = serverDBs.filter { !managedNames.contains($0) }
            if !others.isEmpty {
                Card(title: "Other databases on this server") {
                    ForEach(others, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                }
            }
        }
        .task(id: app.isRunning(.mysql)) { serverDBs = await app.serverDatabases() }
        .task(id: app.config.databases.count) { serverDBs = await app.serverDatabases() }
        .sheet(isPresented: $showingCreate) { CreateDatabaseSheet(siteID: nil, suggested: "") }
        .confirmationDialog("Delete database \(pendingDrop?.name ?? "")?", isPresented: Binding(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } })) {
            Button("Delete Database and User", role: .destructive) {
                if let db = pendingDrop { Task { error = await app.dropDatabase(db) } }
            }
        } message: { Text("All tables and data in this database are permanently deleted.") }
    }
}

/// Change or reset the MySQL root password.
struct MySQLRootPasswordSheet: View {
    enum Mode: String, Identifiable { case change, reset; var id: String { rawValue } }

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "key", title: mode == .change ? "Change Root Password" : "Reset Root Password",
                       subtitle: "MySQL", tint: .teal)
            Text(mode == .change
                 ? "Sets a new password for the MySQL root user. Server uses it from now on."
                 : "Use this if the root password is lost. MySQL restarts briefly in recovery mode, reachable only from this Mac, and any websites using it are unavailable for a few seconds.")
                .font(.callout).foregroundStyle(.secondary)
            FormRow(label: "New Password", labelWidth: 120) {
                HStack {
                    TextField("None", text: $password).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    Button("Generate") { password = AppState.randomPassword(24) }.glassButton()
                }
            }
            Text(password.isEmpty ? "With no password, anyone using this Mac can log in to MySQL as root."
                                  : "Letters, numbers and symbols are all fine.")
                .font(.caption).foregroundStyle(password.isEmpty ? Color.orange : Color.secondary)
                .padding(.leading, 132)
            if let error { ErrorBanner(text: error) { self.error = nil } }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(mode == .change ? "Change Password" : "Reset Password") { apply() }
                    .keyboardShortcut(.defaultAction).glassButton(prominent: true).disabled(working)
            }
        }
        .padding(26).frame(width: 540)
    }

    private func apply() {
        working = true; error = nil
        let new = password
        Task {
            let problem = mode == .change ? await app.changeMySQLRootPassword(to: new) : await app.resetMySQLRootPassword(to: new)
            working = false
            if let problem { error = problem } else { dismiss() }
        }
    }
}

/// A small button that copies text to the clipboard.
struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
            .buttonStyle(.borderless).help("Copy").accessibilityLabel("Copy")
    }
}

/// One switch for both web servers. Listening addresses only change on a full restart.
@MainActor
func webNetwork(_ app: AppState) -> Binding<Bool> {
    Binding(get: { app.config.webAllowNetwork }, set: { value in
        app.update { $0.webAllowNetwork = value }
        Task {
            for kind in [ServiceKind.apache, .nginx] where app.isRunning(kind) { await app.restart(kind) }
        }
    })
}
