// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

/// OpenAI-compatible API for Apple's on-device Foundation Model (Apple Intelligence), via afm-cli.
struct AIModelsView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", tryIt = "Try It", settings = "Settings" }
    @State private var tab: Tab = .overview

    var body: some View {
        DetailPage {
            PageHeader(symbol: "apple.intelligence", title: "AI Models",
                       subtitle: "OpenAI-compatible API for the on-device Apple Foundation Model", tint: .pink) {
                ServiceControl(kind: .ai)
            }
            TabStrip(selection: $tab)
        } content: {
            switch tab {
            case .overview: AIOverviewTab()
            case .tryIt: AIPlaygroundTab()
            case .settings: AISettingsTab()
            }
        }
    }
}

extension AIServerSettings {
    func baseURL(host: String) -> String { "http://\(allowNetwork ? host : "127.0.0.1"):\(port)/v1" }
}

struct AIOverviewTab: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let s = app.config.ai
        let base = s.baseURL(host: SystemStatus.shared.hostName)
        VStack(alignment: .leading, spacing: 20) {
            ServiceOverviewCard(kind: .ai, formula: AIServer.formula, configFile: AIServer.logFile)
            if s.webChat { webAppCard(s) }
            if s.webChat { shareCard(s) }
            Card(title: "Use From Your Apps",
                 footer: "Point any app or library that talks to OpenAI at this base URL. Any model name works; requests are answered by Apple Intelligence on this Mac, so nothing leaves it. Requires a Mac with Apple Intelligence turned on.") {
                FormRow(label: "Base URL") { CopyText(text: base) }
                FormRow(label: "Model") { CopyText(text: s.modelName) }
                FormRow(label: "API Key") {
                    Text(s.apiKey.isEmpty ? "Not required (any value works)" : "Required — see Settings").foregroundStyle(.secondary)
                }
                FormRow(label: "Endpoints") {
                    Text("/v1/chat/completions (streaming, JSON schema) · /v1/completions · /v1/models")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Card(title: "Example") {
                let curl = """
                curl \(base)/chat/completions \\
                  -H "Content-Type: application/json" \(s.apiKey.isEmpty ? "" : "\\\n  -H \"Authorization: Bearer \(s.apiKey)\" ")\\
                  -d '{"model": "\(s.modelName)", "messages": [{"role": "user", "content": "Hello!"}]}'
                """
                Text(curl).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                HStack { Spacer(); Button("Copy") { copy(curl) }.glassButton() }
            }
        }
    }
}

extension AIOverviewTab {
    /// Sharing the chat on the internet through a Cloudflare quick tunnel.
    func shareCard(_ s: AIServerSettings) -> some View {
        Card(title: "Share Online",
             footer: "\(String(localized: "Opens a temporary public address (trycloudflare.com) for the chat, with HTTPS, so you can use it away from home without changing your router.")) \(s.apiKey.isEmpty ? String(localized: "The OpenAI-style API stays closed on the internet until you set an API key in Settings.") : String(localized: "The OpenAI-style API is reachable through the link with your API key.")) \(String(localized: "Sharing stops when you quit Server."))") {
            TunnelControl(spec: app.aiTunnelSpec, warning: TunnelText.aiWarning)
        }
    }

    /// The chat web app: where it is and who can reach it.
    func webAppCard(_ s: AIServerSettings) -> some View {
        let host = SystemStatus.shared.hostName
        let address = s.allowNetwork ? "http://\(host):\(s.port)/" : "http://127.0.0.1:\(s.port)/"
        return Card(title: "Chat Web App",
                    footer: s.allowNetwork
                    ? "Anyone on your network can open this and sign in with a Mac account. Sign-in is not encrypted (plain HTTP): use it only on networks you trust."
                    : "Only this Mac can open it. Turn on network access in Settings to use it from other devices.") {
            FormRow(label: "Address") {
                HStack(spacing: 10) {
                    CopyText(text: address)
                    Button("Open") { if let url = URL(string: address.replacingOccurrences(of: host, with: "127.0.0.1")) { NSWorkspace.shared.open(url) } }
                        .glassButton().disabled(!app.isRunning(.ai))
                }
            }
            FormRow(label: "Sign In") { Text("With a Mac user name and password. Each person has their own chats.").foregroundStyle(.secondary) }
            FormRow(label: "Chats") { PathText(path: AIServer.chatsDir) }
        }
    }
}

struct CopyText: View {
    let text: String
    var body: some View {
        HStack {
            Text(text).font(.body.monospaced()).textSelection(.enabled)
            Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy").accessibilityLabel("Copy")
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Try It

/// Sends a prompt through the running server, exactly like an app would.
struct AIPlaygroundTab: View {
    @Environment(AppState.self) private var app
    @State private var system = ""
    @State private var prompt = "Write a haiku about servers."
    @State private var answer = ""
    @State private var seconds: Double?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !app.isRunning(.ai) {
                Card { Text("Start the server to try it.").foregroundStyle(.secondary) }
            }
            Card {
                FormRow(label: "Instructions") {
                    TextField("Optional system prompt, e.g. Answer briefly.", text: $system).textFieldStyle(.roundedBorder)
                }
                FormRow(label: "Prompt") {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Send") { send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .glassButton(prominent: true)
                        .disabled(working || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !app.isRunning(.ai))
                }
            }
            if let error { ErrorBanner(text: error) { self.error = nil } }
            if !answer.isEmpty {
                Card(title: "Response", footer: seconds.map { "Answered in \($0.formatted(.number.precision(.fractionLength(1)))) s by the on-device model." }) {
                    Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func send() {
        let s = app.config.ai
        guard let url = URL(string: "http://127.0.0.1:\(s.port)/v1/chat/completions") else { return }
        var messages: [[String: String]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !s.apiKey.isEmpty { req.setValue("Bearer \(s.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": s.modelName, "messages": messages])
        working = true
        error = nil
        let started = Date()
        Task {
            defer { working = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let e = json?["error"] as? [String: Any] { error = e["message"] as? String ?? "Error"; return }
                let choices = json?["choices"] as? [[String: Any]]
                answer = (choices?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
                seconds = Date().timeIntervalSince(started)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Settings

struct AISettingsTab: View {
    @Environment(AppState.self) private var app
    @State private var draft = AIServerSettings()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Server") {
                FormRow(label: "Port") { NumberField(value: $draft.port) }
                FormRow(label: "Network") {
                    Toggle("Accept requests from other devices on the network (API and web app)", isOn: $draft.allowNetwork)
                }
                FormRow(label: "Model Name") {
                    TextField("apple-foundation-model", text: $draft.modelName).textFieldStyle(.roundedBorder).frame(width: 260)
                }
            }
            Card(title: "Chat Web App",
                 footer: "\(String(localized: "Chats are saved in")) \(AIServer.chatsDir). \(String(localized: "Each person only sees their own in the app, but the files are readable by the Mac account that runs Server.")) \(draft.allowNetwork ? String(localized: "With network access on, Mac passwords are sent unencrypted (plain HTTP) when people sign in.") : "")") {
                FormRow(label: "Web App") { Toggle("Serve the chat web app at the server address", isOn: $draft.webChat) }
                if draft.webChat && draft.allowNetwork {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Other devices will sign in with Mac passwords over plain HTTP. Anyone on the same network could read them. Use this only on a network you trust, or keep network access off.")
                            .font(.callout)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Card(title: "API Key", footer: "When set, requests must send it as “Authorization: Bearer <key>”, like OpenAI. Recommended when other devices can connect.") {
                FormRow(label: "Key") {
                    HStack {
                        TextField("Not required", text: $draft.apiKey).textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Button("Generate") {
                            draft.apiKey = "sk-local-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                        }
                        .glassButton()
                    }
                }
            }
            HStack {
                Spacer()
                Button("Revert") { draft = app.config.ai }.glassButton().disabled(draft == app.config.ai)
                Button("Save") {
                    let d = draft
                    app.update { $0.ai = d }
                    // Restarting signs everyone out of the web app.
                    if app.isRunning(.ai) { Task { await app.restart(.ai) } }
                }
                .glassButton(prominent: true)
                .disabled(draft == app.config.ai || draft.port < 1 || draft.port > 65535)
            }
        }
        .onAppear { if !loaded { draft = app.config.ai; loaded = true } }
    }
}
