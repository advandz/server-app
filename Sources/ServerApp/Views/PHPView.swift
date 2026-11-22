// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

struct PHPView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", extensions = "Extensions", settings = "Settings", composer = "Composer" }
    @State private var tab: Tab = .overview
    @State private var formula = ""
    @State private var info: PHPManager.Info?
    @State private var linked: String?
    @State private var confirmInstall: String?

    private var installedFormulae: [String] { Homebrew.phpFormulae.filter { app.brew.isInstalled($0) } }
    private var prefix: String { app.brew.prefix }

    var body: some View {
        DetailPage {
            PageHeader(symbol: "chevron.left.forwardslash.chevron.right", title: "PHP",
                       subtitle: linked.map { "Default CLI: \(label($0)) · \(installedFormulae.count) version\(installedFormulae.count == 1 ? "" : "s") installed" } ?? "PHP versions from Homebrew",
                       tint: .indigo) {
                versionMenu
            }
            TabStrip(selection: $tab)
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                PHPInstallStatus()
                if tab == .composer {
                    ComposerTab()
                } else if installedFormulae.isEmpty {
                    Card { Text("No PHP versions are installed yet. Choose one from Install Version.").foregroundStyle(.secondary) }
                } else if let info {
                    switch tab {
                    case .overview: PHPOverviewTab(formula: formula, info: info, linked: $linked)
                    case .extensions: PHPExtensionsTab(formula: formula, info: info) { await reload() }
                    case .settings: PHPSettingsTab(formula: formula, info: info) { await reload() }
                    case .composer: EmptyView()
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
                }
            }
        }
        .phpInstallConfirmation($confirmInstall) { formula = $0 }
        .onChange(of: installedFormulae) {
            if !installedFormulae.contains(formula) { formula = linked.flatMap { installedFormulae.contains($0) ? $0 : nil } ?? installedFormulae.first ?? "" }
        }
        .task(id: formula) { await reload() }
        .onAppear {
            linked = PHPManager.linkedFormula(prefix: prefix)
            if formula.isEmpty { formula = linked.flatMap { installedFormulae.contains($0) ? $0 : nil } ?? installedFormulae.first ?? "" }
        }
    }

    private var versionMenu: some View {
        let groups = PHPCatalog.grouped { app.brew.version($0) }
        let missingSupported = groups.supported.filter { !app.brew.isInstalled($0) }
        let missingEOL = groups.endOfLife.filter { !app.brew.isInstalled($0) }
        return HStack(spacing: 8) {
            if !app.phpInstalling.isEmpty { ProgressView().controlSize(.small) }
            Picker("Version", selection: $formula) {
                ForEach(installedFormulae, id: \.self) { f in
                    Text(phpTitle(f, brew: app.brew) + (f == linked ? " (CLI default)" : "")).tag(f)
                }
            }
            .labelsHidden().fixedSize()
            .disabled(installedFormulae.isEmpty)
            Menu("Install Version") {
                ForEach(missingSupported, id: \.self) { f in
                    Button(label(f)) { install(f) }
                }
                if !missingEOL.isEmpty {
                    if !missingSupported.isEmpty { Divider() }
                    Text("End of life — no security fixes")
                    ForEach(missingEOL, id: \.self) { f in
                        Button(label(f)) { install(f) }
                    }
                }
            }
            .fixedSize()
            .disabled(!app.phpInstalling.isEmpty)
        }
    }

    /// Current versions install straight away; old (end-of-life) ones ask first.
    private func install(_ f: String) {
        if PHPCatalog.needsTap(f) || PHPCatalog.isEndOfLife(f, version: app.brew.version(f)) {
            confirmInstall = f
        } else {
            Task { await app.installPHP(f); if app.brew.isInstalled(f) { formula = f } }
        }
    }

    private func label(_ f: String) -> String { Homebrew.phpLabel(f, version: app.brew.version(f)) }

    private func reload() async {
        guard !formula.isEmpty else { info = nil; return }
        info = await PHPManager.info(formula, prefix: prefix)
        linked = PHPManager.linkedFormula(prefix: prefix)
    }
}

// MARK: - Overview

struct PHPOverviewTab: View {
    @Environment(AppState.self) private var app
    let formula: String
    let info: PHPManager.Info
    @Binding var linked: String?
    @State private var working = false
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        let sites = app.config.websites.filter { $0.servedPHP == formula }
        VStack(alignment: .leading, spacing: 20) {
            if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
            PHPNotice(formula: formula)
            Card {
                FormRow(label: "Version") { Text("PHP \(info.version)") }
                FormRow(label: "Binary") { PathText(path: PHPManager.php(formula, prefix: app.brew.prefix)) }
                FormRow(label: "php.ini") {
                    HStack {
                        PathText(path: info.iniFile)
                        Button("Edit…") { Shell.openInTextEditor(info.iniFile) }.buttonStyle(.link)
                    }
                }
                FormRow(label: "Extra .ini Files") { PathText(path: info.scanDir) }
                FormRow(label: "PHP-FPM") {
                    HStack(spacing: 8) {
                        StatusDot(color: app.phpRunning.contains(formula) ? .green : .secondary)
                        Text(app.phpRunning.contains(formula) ? "Running for websites" : "Starts when a website uses it")
                            .foregroundStyle(.secondary)
                    }
                }
                FormRow(label: "Websites") {
                    Text(sites.isEmpty ? "None" : sites.map(\.name).joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
            Card(title: "Command Line",
                 footer: "The default version is the `php` that Terminal, Composer and other tools use. Websites keep their own version.") {
                FormRow(label: "Default CLI") {
                    HStack(spacing: 10) {
                        if linked == formula {
                            Label("This is the default PHP in Terminal", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        } else {
                            Text(linked.map { "Currently \(Homebrew.phpLabel($0, version: app.brew.version($0)))" } ?? "No php on the PATH")
                                .foregroundStyle(.secondary)
                            Button("Make Default CLI Version") {
                                working = true
                                Task {
                                    error = await app.brew.linkPHP(formula, replacing: linked)
                                    linked = PHPManager.linkedFormula(prefix: app.brew.prefix)
                                    working = false
                                }
                            }
                            .glassButton(prominent: true)
                            .disabled(working)
                            if working { ProgressView().controlSize(.small) }
                        }
                    }
                }
                if linked != formula && PHPCatalog.isTooOldForComposer(formula) {
                    Text("Composer needs PHP 7.2.5 or newer and won't run if this version becomes the default.")
                        .font(.caption).foregroundStyle(.orange).padding(.leading, 182)
                }
            }
            Card(title: "Remove",
                 footer: "Uninstalls this version with Homebrew. Its settings are kept, and packages it brought in stay installed.") {
                HStack {
                    Text(!sites.isEmpty ? "Used by \(sites.count) website\(sites.count == 1 ? "" : "s"). Switch them to another version first."
                         : linked == formula ? "This is the default PHP in Terminal. Choose another default first."
                         : "Frees disk space.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove \(Homebrew.phpLabel(formula, version: nil))…") { confirmRemove = true }
                        .glassButton()
                        .disabled(!sites.isEmpty || linked == formula || !app.phpInstalling.isEmpty)
                }
            }
        }
        .confirmationDialog("Remove \(Homebrew.phpLabel(formula, version: nil))?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await app.removePHP(formula) } }
        } message: {
            Text("You can install it again later.")
        }
    }
}

struct PathText: View {
    let path: String
    var body: some View {
        Text(path.isEmpty ? "—" : path).font(.callout).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }
}

// MARK: - Extensions

struct PHPExtensionsTab: View {
    @Environment(AppState.self) private var app
    let formula: String
    let info: PHPManager.Info
    var reload: () async -> Void
    @State private var working: String?
    @State private var progress = ""
    @State private var error: String?
    @State private var showBuiltIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
            if PHPCatalog.isEndOfLife(formula, version: info.version) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                    Text("Newer releases of these extensions may not support PHP \(Homebrew.shortVersion(info.version)). If an install fails, that's usually why.")
                        .font(.callout)
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Card(title: "PECL Extensions",
                 footer: progress.isEmpty ? "Extensions are built for PHP \(info.version) with pecl. Changes restart PHP-FPM for websites." : "\(progress)") {
                ForEach(PHPManager.catalog) { ext in
                    let installed = info.sharedObjects.contains(ext.name)
                    let enabled = PHPManager.isEnabled(ext, info)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ext.name).fontWeight(.medium)
                            Text(ext.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if working == ext.name { ProgressView().controlSize(.small) }
                        if installed {
                            Toggle("Enabled", isOn: Binding(get: { enabled }, set: { on in toggle(ext, on: on) }))
                                .toggleStyle(.switch).controlSize(.small)
                            Button { uninstall(ext) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Uninstall").accessibilityLabel("Uninstall")
                        } else if enabled {
                            Text("Built in").foregroundStyle(.secondary)
                        } else {
                            Button("Install") { install(ext) }.glassButton()
                        }
                    }
                    .disabled(working != nil)
                    if ext != PHPManager.catalog.last { Divider() }
                }
            }
            Card(title: "Loaded Extensions") {
                DisclosureGroup("\(info.loaded.count) extensions loaded", isExpanded: $showBuiltIn) {
                    Text(info.loaded.sorted().joined(separator: ", "))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func toggle(_ ext: PHPManager.PECLExtension, on: Bool) {
        do {
            if on { try PHPManager.enable(ext, info) } else { try PHPManager.disable(ext, info) }
        } catch { self.error = error.localizedDescription }
        Task { await app.restartPHP(formula); await reload() }
    }

    private func install(_ ext: PHPManager.PECLExtension) {
        working = ext.name
        Task {
            for dep in ext.brewDeps + ["autoconf", "pkgconf"] { await app.brew.ensureInstalled(dep) }
            let result = await PHPManager.install(ext, formula: formula, prefix: app.brew.prefix) { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { Task { @MainActor in progress = String(t.suffix(160)) } }
            }
            if let result { error = "Couldn't install \(ext.name):\n" + result }
            working = nil
            progress = ""
            await app.restartPHP(formula)
            await reload()
        }
    }

    private func uninstall(_ ext: PHPManager.PECLExtension) {
        working = ext.name
        Task {
            if let result = await PHPManager.uninstall(ext, formula: formula, prefix: app.brew.prefix) { error = result }
            working = nil
            await app.restartPHP(formula)
            await reload()
        }
    }
}

// MARK: - Settings

struct PHPSettingsTab: View {
    @Environment(AppState.self) private var app
    let formula: String
    let info: PHPManager.Info
    var reload: () async -> Void
    @State private var values: [String: String] = [:]
    @State private var saved: [String: String] = [:]
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
            Card(footer: "\(String(localized: "Leave a field empty to use php.ini's value (shown in grey). Saved to")) \(info.scanDir.isEmpty ? "conf.d" : info.scanDir + "/zz-server.ini")") {
                ForEach(PHPManager.settings) { s in
                    FormRow(label: "\(s.title)") { field(s) }
                }
            }
            HStack {
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Edit php.ini…") { Shell.openInTextEditor(info.iniFile) }.glassButton()
                Button("Apply to All Versions") { save(all: true) }.glassButton().disabled(values.isEmpty && saved.isEmpty)
                Button("Save") { save(all: false) }.glassButton(prominent: true).disabled(values == saved)
            }
        }
        .onAppear { values = PHPManager.readOverrides(info); saved = values }
    }

    @ViewBuilder private func field(_ s: PHPManager.Setting) -> some View {
        let current = info.values[s.key] ?? ""
        switch s.kind {
        case .text:
            TextField(current.isEmpty ? "not set" : current, text: binding(s.key))
                .textFieldStyle(.roundedBorder).frame(width: 220)
        case .bool:
            Picker("", selection: binding(s.key)) {
                Text("Default (\(isOn(current) ? "On" : "Off"))").tag("")
                Text("On").tag("On")
                Text("Off").tag("Off")
            }
            .labelsHidden().fixedSize()
        case .choice(let options):
            Picker("", selection: binding(s.key)) {
                Text("Default (\(info.errorReportingName ?? current))").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    private func isOn(_ v: String) -> Bool { ["1", "on", "true", "yes"].contains(v.lowercased()) }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0.isEmpty ? nil : $0 })
    }

    private func save(all: Bool) {
        let targets = all ? Homebrew.phpFormulae.filter { app.brew.isInstalled($0) } : [formula]
        Task {
            for f in targets {
                let i = f == formula ? info : await PHPManager.info(f, prefix: app.brew.prefix)
                guard !i.scanDir.isEmpty else { continue }
                do { try PHPManager.writeOverrides(values, i) } catch { self.error = error.localizedDescription; return }
                await app.restartPHP(f)
            }
            saved = values
            notice = all ? "Saved for \(targets.count) PHP versions." : "Saved."
            await reload()
        }
    }
}

// MARK: - Composer

struct ComposerTab: View {
    @Environment(AppState.self) private var app
    @State private var status: Composer.Status?
    @State private var upgrade: String?
    @State private var checking = false
    @State private var working = false

    private var installed: Bool { app.brew.isInstalled(Composer.formula) }

    var body: some View {
        Card(title: "Composer", footer: "Installed and updated with Homebrew. Composer runs with the default CLI PHP.") {
            FormRow(label: "Status") {
                HStack(spacing: 8) {
                    StatusDot(color: installed ? .green : .secondary)
                    Text(installed ? (status?.version.map { "Composer \($0)" } ?? "Installed") : "Not installed")
                    if working { ProgressView().controlSize(.small) }
                }
            }
            if installed {
                FormRow(label: "Runs With") { Text(status?.php.map { "PHP \($0)" } ?? "—").foregroundStyle(.secondary) }
                FormRow(label: "Binary") { PathText(path: Composer.binary(prefix: app.brew.prefix)) }
                if let dir = status?.globalDir {
                    FormRow(label: "Global Packages") { PathText(path: dir) }
                }
                FormRow(label: "Updates") {
                    HStack(spacing: 10) {
                        if checking {
                            ProgressView().controlSize(.small)
                            Text("Checking…").foregroundStyle(.secondary)
                        } else if let upgrade {
                            Text("Composer \(upgrade) is available").foregroundStyle(.orange)
                            Button("Update") { run { await app.brew.upgrade(Composer.formula) } }.glassButton(prominent: true)
                        } else {
                            Text("Up to date").foregroundStyle(.secondary)
                        }
                        Button("Check Again") { Task { await check() } }.buttonStyle(.link).disabled(checking || working)
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Button("Install Composer") { run { await app.brew.ensureInstalled(Composer.formula) } }
                        .glassButton(prominent: true).disabled(working)
                }
            }
        }
        .task { await check() }
    }

    private func run(_ op: @escaping () async -> Bool) {
        working = true
        Task { _ = await op(); working = false; await check() }
    }

    private func check() async {
        checking = true
        async let s = Composer.status(prefix: app.brew.prefix)
        async let u = app.brew.availableUpgrade(Composer.formula)
        (status, upgrade) = await (s, u)
        checking = false
    }
}
