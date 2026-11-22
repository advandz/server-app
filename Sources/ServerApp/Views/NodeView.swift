// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

/// Node.js versions through nvm: install, remove and choose the default.
struct NodeView: View {
    @Environment(AppState.self) private var app
    @State private var installed: [String] = []
    @State private var defaultVersion: String?
    @State private var lts: [NVM.Release]?
    @State private var current: String?
    @State private var working: String?          // version being installed / removed
    @State private var progress = ""
    @State private var error: String?
    @State private var removing: String?
    @State private var customVersion = ""
    @State private var shellReady = NVM.shellConfigured()

    private var prefix: String { app.brew.prefix }
    private var nvmInstalled: Bool { NVM.isInstalled(prefix: prefix) }

    var body: some View {
        DetailPage {
            PageHeader(symbol: "hexagon", title: "Node.js",
                       subtitle: defaultVersion.map { "Default \($0) · \(installed.count) installed with nvm" } ?? "Node.js versions with nvm",
                       tint: .green) {
                if working != nil { ProgressView().controlSize(.small) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
                if !nvmInstalled {
                    Card(footer: "nvm installs and switches between Node.js versions. Server installs it with Homebrew.") {
                        HStack {
                            Text("nvm isn't installed.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Install nvm") {
                                Task {
                                    working = "nvm"
                                    if !(await app.brew.ensureInstalled(NVM.formula)) { error = "Couldn't install nvm. See Logs › Homebrew Activity." }
                                    try? FileManager.default.createDirectory(atPath: NVM.dir, withIntermediateDirectories: true)
                                    working = nil
                                    await reload()
                                }
                            }
                            .glassButton(prominent: true).disabled(working != nil)
                        }
                    }
                } else {
                    statusCard
                    installedCard
                    installCard
                }
            }
        }
        .task { await reload() }
        .confirmationDialog("Uninstall Node.js \(removing ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { v in
            Button("Uninstall", role: .destructive) { run(v, ["uninstall", v]) }
        } message: { _ in
            Text("Its global npm packages are removed too.")
        }
    }

    private var statusCard: some View {
        Card {
            FormRow(label: "nvm") {
                Text(app.brew.version(NVM.formula).map { "nvm \($0)" } ?? "Installed").foregroundStyle(.secondary)
            }
            FormRow(label: "Default Version") {
                Text(defaultVersion ?? "None — install a version below").foregroundStyle(defaultVersion == nil ? .secondary : .primary)
            }
            FormRow(label: "Terminal") {
                if shellReady {
                    Label("nvm loads in new Terminal windows (~/.zshrc)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("node isn't available in Terminal yet.").foregroundStyle(.secondary)
                        Button("Add nvm to ~/.zshrc") {
                            do { try NVM.addToShell(prefix: prefix); shellReady = NVM.shellConfigured() } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        .glassButton()
                    }
                }
            }
        }
    }

    private var installedCard: some View {
        Card(title: "Installed Versions") {
            if installed.isEmpty { Text("No Node.js versions installed yet.").foregroundStyle(.secondary) }
            ForEach(installed, id: \.self) { v in
                let sites = app.config.websites.filter { $0.isNode && ($0.node.version == v || ($0.node.version.isEmpty && v == defaultVersion)) }
                HStack(spacing: 10) {
                    Text("Node.js \(v.dropFirst())").fontWeight(.medium)
                    if v == defaultVersion { Badge(text: "Default") }
                    if let name = codename(v) { Badge(text: "LTS \(name)") }
                    if !sites.isEmpty {
                        Text("\(sites.count) website\(sites.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if working == v { ProgressView().controlSize(.small) }
                    if v != defaultVersion {
                        Button("Make Default") { run(v, ["alias", "default", v]) }.glassButton()
                    }
                    Button { removing = v } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(v == defaultVersion || !sites.isEmpty)
                        .help(v == defaultVersion ? "Can't remove the default version" : !sites.isEmpty ? "Used by websites" : "Uninstall")
                        .accessibilityLabel("Uninstall")
                }
                .disabled(working != nil)
                if v != installed.last { Divider() }
            }
        }
    }

    private var installCard: some View {
        Card(title: "Install", footer: progress.isEmpty ? "Versions come from nodejs.org through nvm." : "\(progress)") {
            if let lts {
                ForEach(lts.prefix(5)) { rel in row(rel.version, label: "LTS \(rel.lts ?? "")") }
                if let current, !lts.contains(where: { $0.version == current }) {
                    row(current, label: "Latest")
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Loading available versions…").foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                TextField("Other version, e.g. 20.11.1", text: $customVersion).textFieldStyle(.roundedBorder).frame(width: 240)
                Button("Install") {
                    let v = customVersion.trimmingCharacters(in: .whitespaces)
                    run(v, ["install", v])
                }
                .glassButton()
                .disabled(customVersion.trimmingCharacters(in: .whitespaces).isEmpty || working != nil)
            }
        }
    }

    private func row(_ version: String, label: String) -> some View {
        HStack(spacing: 10) {
            Text("Node.js \(version.dropFirst())").fontWeight(.medium)
            Badge(text: label)
            Spacer()
            if working == version { ProgressView().controlSize(.small) }
            if installed.contains(version) {
                Text("Installed").foregroundStyle(.secondary)
            } else {
                Button("Install") { run(version, ["install", version]) }.glassButton().disabled(working != nil)
            }
        }
    }

    private func codename(_ v: String) -> String? { lts?.first { $0.version == v }?.lts }

    private func run(_ version: String, _ args: [String]) {
        working = version
        progress = ""
        Task {
            let r = await NVM.run(args, prefix: prefix) { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { Task { @MainActor in progress = String(text.suffix(160)) } }
            }
            if !r.ok { error = r.output.split(separator: "\n").suffix(6).joined(separator: "\n") }
            working = nil
            progress = ""
            await reload()
            await app.syncNode()
        }
    }

    private func reload() async {
        installed = NVM.installed()
        guard nvmInstalled else { return }
        defaultVersion = await NVM.defaultVersion(prefix: prefix)
        if lts == nil {
            async let l = NVM.remoteLTS(prefix: prefix)
            async let c = NVM.latestCurrent(prefix: prefix)
            (lts, current) = await (l, c)
        }
    }
}
