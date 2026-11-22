// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

/// Websites page: a full-width list of sites (nothing but an empty state when there are none).
/// A site's settings open in a sheet with icon tabs.
struct WebsitesView: View {
    @Environment(AppState.self) private var app
    @State private var showingNew = false
    @State private var editing: SiteRef?
    @State private var deleting: Website?

    var body: some View {
        Group {
            if app.config.websites.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .sheet(isPresented: $showingNew) { NewSiteSheet { _ in } }
        .sheet(item: $editing) { ref in SiteSettingsSheet(siteID: ref.id) }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { site in
            Button("Delete Website", role: .destructive) { app.deleteSite(site.id) }
        } message: { _ in
            Text("The configuration is removed. Files in the document root and assigned databases are kept.")
        }
    }

    private var list: some View {
        let sites = app.config.websites
        // Same container as every other page, so the header sits in the same place.
        return DetailPage {
            PageHeader(symbol: "globe", title: "Websites",
                       subtitle: "\(sites.count) \(sites.count == 1 ? "website" : "websites") · \(sites.filter(\.enabled).count) enabled",
                       tint: .blue) {
                Button { showingNew = true } label: { Label("Add Website", systemImage: "plus") }
                    .glassButton(prominent: true)
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                    SiteRow(site: site,
                            onSettings: { editing = SiteRef(id: site.id) },
                            onDelete: { deleting = site })
                    if index < sites.count - 1 { Divider().padding(.leading, 66) }
                }
            }
            .padding(.vertical, 6)
            .glassPanel()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe").font(.system(size: 52, weight: .light)).foregroundStyle(.secondary)
            Text("No Websites").font(.title2)
            Text("Add a website to serve a folder with Apache or Nginx, using PHP or Node.js.").foregroundStyle(.secondary)
            Button("Add Website…") { showingNew = true }.glassButton(prominent: true)
        }
    }
}

struct SiteRef: Identifiable { let id: UUID }

/// One row in the websites list. Click it to open the site's settings.
struct SiteRow: View {
    @Environment(AppState.self) private var app
    let site: Website
    var onSettings: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let running = site.enabled && app.isRunning(site.server == .apache ? .apache : .nginx)
            && (!site.isNode || app.nodeRunning.contains(site.id))
        HStack(spacing: 14) {
            SiteIconView(site: site, serving: running ? app.siteURL(site) : nil)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(color: running ? .green : site.enabled ? .gray : .clear, size: 9)
                        .overlay(Circle().stroke(.background, lineWidth: running || site.enabled ? 1.5 : 0))
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).font(.body.weight(.medium)).lineLimit(1)
                Text(site.enabled ? site.hostname : "\(site.hostname) · Off")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Badge(text: site.server.title)
                Badge(text: site.isNode ? "Node.js" + (site.node.version.isEmpty ? "" : " \(site.node.version.dropFirst())")
                      : Homebrew.phpLabel(site.phpFormula, version: app.brew.version(site.phpFormula)),
                      symbol: !site.isNode && PHPCatalog.isEndOfLife(site.phpFormula, version: app.brew.version(site.phpFormula)) ? "exclamationmark.triangle.fill" : nil,
                      warning: !site.isNode && PHPCatalog.isEndOfLife(site.phpFormula, version: app.brew.version(site.phpFormula)))
                if site.ssl.enabled { Badge(text: "SSL", symbol: "lock.fill") }
            }
            Text(ports).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
            Toggle("", isOn: Binding(get: { site.enabled },
                                     set: { v in app.update { c in if let i = c.websites.firstIndex(where: { $0.id == site.id }) { c.websites[i].enabled = v } } }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(site.enabled ? "Turn off this website" : "Turn on this website")
            Button { app.openSite(site) } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless).disabled(!running).help("Open in browser")
                .accessibilityLabel("Open in Browser")
            Button(action: onSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Website settings")
                .accessibilityLabel("Website Settings")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 6)
        .opacity(site.enabled ? 1 : 0.6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSettings)
        .contextMenu {
            Button("Settings…", action: onSettings)
            Button("Open in Browser") { app.openSite(site) }.disabled(!running)
            Divider()
            Button("Delete Website…", role: .destructive, action: onDelete)
        }
    }

    private var ports: String {
        let http = app.config.httpPort(site)
        return site.ssl.enabled ? "\(http) · \(app.config.httpsPort(site))" : "\(http)"
    }
}

struct Badge: View {
    let text: String
    var symbol: String? = nil
    var warning = false
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(text).font(.caption)
        }
        .foregroundStyle(warning ? Color.orange : Color.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(warning ? Color.orange.opacity(0.14) : Color.primary.opacity(0.07), in: Capsule())
    }
}

extension AppState {
    func deleteSite(_ id: UUID) {
        update { c in
            c.websites.removeAll { $0.id == id }
            for i in c.databases.indices where c.databases[i].websiteID == id { c.databases[i].websiteID = nil }
        }
    }

    /// The site's home page address (HTTPS when SSL is on).
    func siteURL(_ site: Website) -> URL? {
        let https = site.ssl.enabled
        let port = https ? config.httpsPort(site) : config.httpPort(site)
        let defaultPort = https ? 443 : 80
        return URL(string: "\(https ? "https" : "http")://\(site.hostname)\(port == defaultPort ? "" : ":\(port)")/")
    }

    func openSite(_ site: Website) {
        if let url = siteURL(site) { NSWorkspace.shared.open(url) }
    }
}

/// The site's own icon (apple-touch-icon or favicon) when one is found, else a blue globe tile.
struct SiteIconView: View {
    let site: Website
    let serving: URL?
    var size: CGFloat = 34

    var body: some View {
        if let image = SiteIcons.shared.icon(for: site, serving: serving) {
            Image(nsImage: image)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .padding(image.size.width < 64 ? size * 0.16 : 0)   // small favicons sit on a tile
                .frame(width: size, height: size)
                .background(Color.primary.opacity(image.size.width < 64 ? 0.07 : 0),
                            in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(LinearGradient(colors: [.blue.opacity(0.95), .blue.opacity(0.65)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        }
    }
}

// MARK: - New website

struct NewSiteSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var onCreate: (UUID) -> Void

    @State private var name = ""
    @State private var hostname = ""
    @State private var docRoot = ""
    @State private var server: WebServer = .apache
    @State private var php = "php"
    @State private var runtime: SiteRuntime = .php
    @State private var nodeVersion = ""
    @State private var nodeCommand = "npm start"
    @State private var hostEdited = false
    @State private var rootEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(symbol: "globe", title: "New Website", subtitle: "Serve a folder on this Mac")
            VStack(alignment: .leading, spacing: 12) {
                FormRow(label: "Name", labelWidth: 120) {
                    TextField("My Site", text: $name).textFieldStyle(.roundedBorder)
                        .onChange(of: name) { autofill() }
                }
                FormRow(label: "Host Name", labelWidth: 120) {
                    TextField("mysite.localhost", text: $hostname).textFieldStyle(.roundedBorder)
                        .onChange(of: hostname) { if hostname != suggestedHost { hostEdited = true } }
                }
                FormRow(label: "Document Root", labelWidth: 120) {
                    HStack {
                        TextField("~/Sites/mysite", text: $docRoot).textFieldStyle(.roundedBorder)
                            .onChange(of: docRoot) { if docRoot != suggestedRoot { rootEdited = true } }
                        Button("Choose…") { if let p = FolderPicker.choose(startingAt: NSHomeDirectory() + "/Sites") { docRoot = p; rootEdited = true } }
                    }
                }
                FormRow(label: "Web Server", labelWidth: 120) {
                    Picker("", selection: $server) { ForEach(WebServer.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                FormRow(label: "Runtime", labelWidth: 120) {
                    Picker("", selection: $runtime) { ForEach(SiteRuntime.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if runtime == .php {
                    FormRow(label: "PHP", labelWidth: 120) { PHPPicker(selection: $php) }
                    PHPNotice(formula: php)
                } else {
                    FormRow(label: "Node.js", labelWidth: 120) { NodeVersionPicker(selection: $nodeVersion) }
                    FormRow(label: "Start Command", labelWidth: 120) {
                        TextField("npm start", text: $nodeCommand).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    }
                }
            }
            Text("Host names ending in .localhost work in browsers without any extra setup.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
                    .disabled(name.isEmpty || hostname.isEmpty || docRoot.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 560)
    }

    /// The first app port from 3000 up that no other Node.js site uses.
    private func nextNodePort() -> Int {
        let used = Set(app.config.websites.filter(\.isNode).map(\.node.port))
        return (3000...3999).first { !used.contains($0) } ?? 3000
    }

    private var slug: String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    private var suggestedHost: String { slug.isEmpty ? "" : slug + ".localhost" }
    private var suggestedRoot: String { slug.isEmpty ? "" : NSHomeDirectory() + "/Sites/" + slug }
    private func autofill() {
        if !hostEdited { hostname = suggestedHost }
        if !rootEdited { docRoot = suggestedRoot }
    }

    private func create() {
        let root = (docRoot as NSString).expandingTildeInPath
        let fm = FileManager.default
        let port = nextNodePort()
        if !fm.fileExists(atPath: root) && runtime == .node {
            // A minimal app that runs as-is, so the site works straight away.
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            let pkg = """
            {
              "name": "\(String(slug))",
              "private": true,
              "scripts": { "start": "node server.js" }
            }

            """
            let server = """
            const http = require('http');
            const port = process.env.PORT || \(port);
            http.createServer((req, res) => {
              res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
              res.end('<h1>\(name.replacingOccurrences(of: "'", with: ""))</h1><p>Node.js ' + process.version + '</p>');
            }).listen(port, '127.0.0.1');

            """
            try? pkg.write(toFile: root + "/package.json", atomically: true, encoding: .utf8)
            try? server.write(toFile: root + "/server.js", atomically: true, encoding: .utf8)
        } else if !fm.fileExists(atPath: root) {
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            let starter = php.isEmpty
                ? "<!doctype html><title>\(name)</title><h1>\(name)</h1><p>Served by Server.</p>\n"
                : "<?php\necho '<h1>\(name.replacingOccurrences(of: "'", with: ""))</h1>';\nphpinfo();\n"
            try? starter.write(toFile: root + (php.isEmpty ? "/index.html" : "/index.php"), atomically: true, encoding: .utf8)
        }
        var site = Website(name: name, hostname: hostname.lowercased(), documentRoot: root, server: server, phpFormula: php)
        site.runtime = runtime
        if runtime == .node {
            site.node = NodeSiteSettings(version: nodeVersion, command: nodeCommand.isEmpty ? "npm start" : nodeCommand, port: port)
        }
        app.update { $0.websites.append(site) }
        onCreate(site.id)
        dismiss()
    }
}

/// PHP version picker: current versions first, then end-of-life ones (installed from a community tap).
struct PHPPicker: View {
    @Environment(AppState.self) private var app
    @Binding var selection: String

    var body: some View {
        let groups = PHPCatalog.grouped { app.brew.version($0) }
        Picker("", selection: $selection) {
            Text("None (static files only)").tag("")
            Divider()
            ForEach(groups.supported, id: \.self) { f in Text(title(f)).tag(f) }
            Divider()
            ForEach(groups.endOfLife, id: \.self) { f in Text(title(f)).tag(f) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func title(_ f: String) -> String {
        var title = phpTitle(f, brew: app.brew)
        if !app.brew.isInstalled(f) { title += PHPCatalog.needsTap(f) ? " — not installed" : " — installs on start" }
        return title
    }
}

// MARK: - Website settings sheet

/// A website's settings, with a row of icon tabs across the top like System Settings panes.
struct SiteSettingsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let siteID: UUID

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", apache = "Apache", nginx = "Nginx", ssl = "SSL", databases = "Databases", share = "Share"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .apache: "server.rack"
            case .nginx: "bolt.horizontal"
            case .ssl: "lock.shield"
            case .databases: "cylinder.split.1x2"
            case .share: "cloud"
            }
        }
        /// One-color project logos, matching the sidebar; the symbol is the fallback.
        @MainActor var image: NSImage? {
            switch self {
            case .apache: SystemIcon.apacheMono
            case .nginx: SystemIcon.nginxMono
            case .databases: SystemIcon.mysqlMono
            case .general, .ssl, .share: nil
            }
        }
    }
    @State private var tab: Tab = .general
    @State private var confirmDelete = false

    var body: some View {
        let site = app.site(siteID) ?? .placeholder
        let kind: ServiceKind = site.server == .apache ? .apache : .nginx
        let running = site.enabled && app.isRunning(kind)
        VStack(spacing: 0) {
            IconTabBar(selection: $tab, symbol: \.symbol, image: { $0.image })
                .padding(.top, 14).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(symbol: "globe", title: "\(site.name)",
                               subtitle: site.enabled ? "\(site.server.title) · \(site.isNode ? "Node.js" : Homebrew.phpLabel(site.phpFormula, version: app.brew.version(site.phpFormula)))" : "Off",
                               tint: .blue) {
                        Button { app.openSite(site) } label: { Label("Open", systemImage: "safari") }
                            .glassButton()
                            .disabled(!running)
                            .help(running ? "Open in browser" : "Available when \(site.server.title) is running")
                    }
                    if let err = app.errors[kind] {
                        ErrorBanner(text: err) { app.errors[kind] = nil }
                    }
                    switch tab {
                    case .general: SiteGeneralTab(siteID: siteID)
                    case .apache: SiteApacheTab(siteID: siteID)
                    case .nginx: SiteNginxTab(siteID: siteID)
                    case .ssl: SiteSSLTab(siteID: siteID)
                    case .databases: SiteDatabasesTab(siteID: siteID)
                    case .share: SiteShareTab(siteID: siteID)
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Delete Website…", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
            }
            .padding(16)
        }
        .frame(width: 780, height: 660)
        .confirmationDialog("Delete “\(site.name)”?", isPresented: $confirmDelete) {
            Button("Delete Website", role: .destructive) {
                dismiss()
                app.deleteSite(siteID)
            }
        } message: {
            Text("The configuration is removed. Files in the document root and assigned databases are kept.")
        }
    }
}

/// Icon-over-label tabs, as in a classic macOS preferences window.
struct IconTabBar<Tab: Hashable & CaseIterable & RawRepresentable & Identifiable>: View
where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    let symbol: (Tab) -> String
    var image: (Tab) -> NSImage? = { _ in nil }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { item in
                let selected = item == selection
                Button { selection = item } label: {
                    VStack(spacing: 4) {
                        Group {
                            if let image = image(item) {
                                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                                    .aspectRatio(contentMode: .fit).frame(width: 22, height: 22)
                            } else {
                                Image(systemName: symbol(item)).font(.system(size: 20))
                            }
                        }
                        .frame(height: 24)
                        Text(LocalizedStringKey(item.rawValue)).font(.caption)
                    }
                    .frame(width: 78, height: 54)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .background(selected ? Color.primary.opacity(0.09) : .clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
    }
}

