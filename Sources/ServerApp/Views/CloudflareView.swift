// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

/// Start/stop for one quick tunnel, with its public address once it's up.
struct TunnelControl: View {
    @Environment(AppState.self) private var app
    let spec: TunnelSpec
    /// Shown in a confirmation before sharing (for things where sharing is riskier).
    var warning: String? = nil
    @State private var confirming = false
    @State private var copied = false

    var body: some View {
        let state = app.tunnels.state(spec.key)
        let installing = app.tunnelInstalling.contains(spec.key)
        let blocked = spec.needs.map { !app.isRunning($0) } ?? false
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatusDot(color: installing ? .orange : color(state))
                Text(installing ? String(localized: "Installing cloudflared…") : label(state)).foregroundStyle(.secondary)
                if installing || state == .starting { ProgressView().controlSize(.small) }
                Spacer()
                if state.isActive {
                    Button("Stop Sharing") { app.tunnels.stop(spec.key) }.glassButton()
                } else {
                    Button("Share Online") { if warning == nil { start() } else { confirming = true } }
                        .glassButton(prominent: true)
                        .disabled(blocked || installing)
                }
            }
            if installing {
                Text(app.brew.activity.last ?? "Downloading with Homebrew. This only happens once.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let url = state.url {
                HStack(spacing: 8) {
                    Text(url).font(.body.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button { copy(url) } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy address").accessibilityLabel("Copy Address")
                    Button("Open") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }.buttonStyle(.link)
                }
                Text("It can take a few seconds before the address works.").font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let message) = state {
                ErrorBanner(text: message) { app.tunnels.clear(spec.key) }
            }
            if blocked && !state.isActive, let needs = spec.needs {
                Text("Start \(needs.title) first, then share it.").font(.caption).foregroundStyle(.orange)
            }
        }
        .confirmationDialog("Share \(spec.title) on the internet?", isPresented: $confirming) {
            Button("Share Online") { start() }
        } message: {
            Text(warning ?? "")
        }
    }

    private func start() { Task { await app.shareOnline(spec) } }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private func color(_ state: CloudflareTunnels.State) -> Color {
        switch state {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private func label(_ state: CloudflareTunnels.State) -> String {
        switch state {
        case .stopped: String(localized: "Not shared")
        case .starting: String(localized: "Connecting to Cloudflare…")
        case .running: String(localized: "Shared on the internet")
        case .failed: String(localized: "Couldn't share")
        }
    }
}

enum TunnelText {
    static var publicNote: String { String(localized: "Anyone who has the address can open it, so share only what you're happy to make public. The address changes every time, and sharing stops when you quit Server.") }
    static var aiWarning: String { String(localized: "Anyone with the link will see your chat's sign-in page and can try to sign in with a Mac user name and password. Use strong passwords, share only for as long as you need, and stop sharing when you're done. The OpenAI-style API is only reachable through the link when an API key is set.") }
}

// MARK: - Page

struct CloudflareView: View {
    @Environment(AppState.self) private var app
    @State private var editing: CloudflareSettings.Custom?
    @State private var installingNow = false

    var body: some View {
        let running = app.tunnels.runningCount
        DetailPage {
            PageHeader(symbol: "cloud", title: "Cloudflare",
                       subtitle: running == 0 ? "Share things on this Mac online with quick tunnels"
                                              : "\(running) shared on the internet right now",
                       tint: .orange) {
                if !app.tunnels.activeKeys.isEmpty { Button("Stop All") { app.tunnels.stopAll() }.glassButton() }
            }
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                aboutCard
                websitesCard
                aiCard
                customCard
            }
        }
        .sheet(item: $editing) { entry in CustomAddressSheet(entry: entry) }
    }

    private var aboutCard: some View {
        Card(footer: "\(TunnelText.publicNote)") {
            FormRow(label: "cloudflared") {
                HStack(spacing: 10) {
                    if app.brew.isInstalled("cloudflared") {
                        Text(app.brew.version("cloudflared").map { "Installed (\($0))" } ?? "Installed").foregroundStyle(.secondary)
                    } else if installingNow {
                        ProgressView().controlSize(.small)
                        Text("Installing…").foregroundStyle(.secondary)
                    } else {
                        Text("Not installed. It's installed automatically the first time you share.").foregroundStyle(.secondary)
                        Button("Install Now") { installingNow = true; Task { await app.brew.ensureInstalled("cloudflared"); installingNow = false } }
                            .glassButton()
                    }
                }
            }
            FormRow(label: "How It Works") {
                Text("Quick tunnels use Cloudflare's free trycloudflare.com service: no account, and no router settings to change.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var websitesCard: some View {
        Card(title: "Websites") {
            if app.config.websites.isEmpty { Text("No websites yet.").foregroundStyle(.secondary) }
            ForEach(app.config.websites) { site in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(site.name).fontWeight(.medium)
                        Text(site.hostname).font(.callout).foregroundStyle(.secondary)
                    }
                    if site.enabled {
                        TunnelControl(spec: app.tunnelSpec(for: site))
                    } else {
                        Text("Turn this website on to share it.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if site.id != app.config.websites.last?.id { Divider() }
            }
        }
    }

    private var aiCard: some View {
        Card(title: "AI Models Chat",
             footer: app.config.ai.apiKey.isEmpty
                ? "The OpenAI-style API stays closed on the internet until you set an API key in AI Models › Settings."
                : "The OpenAI-style API is reachable through the link with your API key.") {
            if app.config.ai.webChat {
                TunnelControl(spec: app.aiTunnelSpec, warning: TunnelText.aiWarning)
            } else {
                Text("Turn on the chat web app in AI Models › Settings to share it.").foregroundStyle(.secondary)
            }
        }
    }

    private var customCard: some View {
        Card(title: "Other Addresses",
             footer: "Share anything else running on this Mac, such as a development server. Only addresses on this Mac are allowed.") {
            let saved = app.config.cloudflare.custom
            if saved.isEmpty { Text("No saved addresses.").foregroundStyle(.secondary) }
            ForEach(saved) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(entry.name.isEmpty ? entry.url : entry.name).fontWeight(.medium)
                        if !entry.name.isEmpty { Text(entry.url).font(.callout.monospaced()).foregroundStyle(.secondary) }
                        Spacer()
                        Button { editing = entry } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Edit").accessibilityLabel("Edit Address")
                        Button {
                            app.tunnels.stop("custom:\(entry.id)")
                            app.update { $0.cloudflare.custom.removeAll { $0.id == entry.id } }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove Address")
                    }
                    switch app.tunnelSpec(forCustom: entry) {
                    case .success(let spec): TunnelControl(spec: spec)
                    case .failure(let error): Text(error.message).font(.callout).foregroundStyle(.orange)
                    }
                }
                if entry.id != saved.last?.id { Divider() }
            }
            HStack {
                Button("Add Address…") { editing = CloudflareSettings.Custom() }.glassButton()
                Spacer()
            }
        }
    }
}

struct CustomAddressSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var entry: CloudflareSettings.Custom

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "cloud", title: "Address to Share", subtitle: "Something running on this Mac", tint: .orange)
            FormRow(label: "Name", labelWidth: 100) { TextField("My dev server", text: $entry.name).textFieldStyle(.roundedBorder) }
            FormRow(label: "Address", labelWidth: 100) {
                TextField("http://localhost:3000", text: $entry.url).textFieldStyle(.roundedBorder).font(.body.monospaced())
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).padding(.leading, 112) }
            Text("Use an http or https address on this Mac, such as http://localhost:3000 or https://myapp.localhost:8443. Self-signed HTTPS certificates are accepted.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let value = entry
                    app.update { c in
                        if let i = c.cloudflare.custom.firstIndex(where: { $0.id == value.id }) { c.cloudflare.custom[i] = value }
                        else { c.cloudflare.custom.append(value) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).glassButton(prominent: true).disabled(problem != nil)
            }
        }
        .padding(26).frame(width: 520)
    }

    private var problem: String? {
        if case .failure(let e) = LocalAddress.parse(entry.url) { return e.message }
        return nil
    }
}

// MARK: - Website tab

struct SiteShareTab: View {
    @Environment(AppState.self) private var app
    let siteID: UUID

    var body: some View {
        let site = app.site(siteID) ?? .placeholder
        Card(title: "Share Online",
             footer: "\(String(localized: "Creates a temporary public address (trycloudflare.com) that reaches this website through Cloudflare.")) \(TunnelText.publicNote) \(String(localized: "Sites that hard-code their own address, like WordPress, may send visitors to it."))") {
            if site.enabled {
                TunnelControl(spec: app.tunnelSpec(for: site))
            } else {
                Text("Turn this website on to share it.").foregroundStyle(.secondary)
            }
        }
    }
}
