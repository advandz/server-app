// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

struct RedisView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", settings = "Settings", console = "Console" }
    @State private var tab: Tab = .overview

    var body: some View {
        DetailPage {
            PageHeader(symbol: "memorychip", title: "Redis", subtitle: "In-memory key-value store", tint: .red, glyph: SystemIcon.redisMono) {
                ServiceControl(kind: .redis)
            }
            TabStrip(selection: $tab)
        } content: {
            switch tab {
            case .overview: RedisOverviewTab()
            case .settings: RedisSettingsTab()
            case .console: RedisConsoleTab()
            }
        }
    }
}

private struct RedisRestartBar: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if app.redisNeedsRestart && app.isRunning(.redis) {
            HStack {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                Text("Restart Redis to apply your changes.")
                Spacer()
                Button("Restart") { Task { await app.restart(.redis) } }.glassButton(prominent: true)
            }
            .padding(14)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

// MARK: - Overview

struct RedisOverviewTab: View {
    @Environment(AppState.self) private var app
    @State private var info: RedisServer.Info?
    @State private var confirmFlush = false
    @State private var message: String?

    var body: some View {
        let s = app.config.redis
        VStack(alignment: .leading, spacing: 20) {
            RedisRestartBar()
            ServiceOverviewCard(kind: .redis, formula: RedisServer.formula, configFile: RedisServer.confFile)
            Card(title: "Connection") {
                FormRow(label: "Address") {
                    CopyText(text: "redis://\(s.allowNetwork ? SystemStatus.shared.hostName : "127.0.0.1"):\(s.port)")
                }
                FormRow(label: "Password") {
                    Text(s.password.isEmpty ? "None (this Mac only)" : "Required — see Settings").foregroundStyle(.secondary)
                }
                FormRow(label: "Access") {
                    Text(s.allowNetwork ? "This Mac and devices on the network" : "This Mac only").foregroundStyle(.secondary)
                }
            }
            if app.isRunning(.redis) {
                Card(title: "Activity") {
                    if let info {
                        FormRow(label: "Version") { Text("Redis \(info.version) · \(info.role)").foregroundStyle(.secondary) }
                        FormRow(label: "Uptime") { Text(SystemStatus.format(uptime: TimeInterval(info.uptime))).foregroundStyle(.secondary) }
                        FormRow(label: "Memory") {
                            Text("\(info.usedMemory) used · peak \(info.peakMemory)"
                                 + (info.maxMemory == "0B" ? "" : " · limit \(info.maxMemory)"))
                                .foregroundStyle(.secondary)
                        }
                        FormRow(label: "Clients") { Text("\(info.clients) connected · \(info.opsPerSecond) operations/s").foregroundStyle(.secondary) }
                        FormRow(label: "Keys") {
                            Text(info.databases.isEmpty ? "No keys" : info.databases.map { "\($0.name): \($0.keys)" }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        FormRow(label: "Commands") {
                            let total = info.hits + info.misses
                            Text("\(info.commands.formatted()) processed"
                                 + (total > 0 ? " · \(Int(Double(info.hits) / Double(total) * 100))% key hits" : ""))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Reading statistics…").foregroundStyle(.secondary) }
                    }
                }
                Card(title: "Data", footer: message.map { "\($0)" } ?? "Data is kept in \(RedisServer.dataDir).") {
                    HStack {
                        Text(s.snapshots || s.appendOnly ? "Saved to disk" : "Not saved to disk (lost when Redis stops)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Now") { run(["BGSAVE"], done: "Saving in the background.") }.glassButton().disabled(!s.snapshots && !s.appendOnly)
                        Button("Flush All Data…") { confirmFlush = true }.glassButton()
                    }
                }
            }
        }
        .task(id: app.state(.redis)) {
            while !Task.isCancelled, app.isRunning(.redis) {
                info = await RedisServer.info(settings: app.config.redis, prefix: app.brew.prefix)
                try? await Task.sleep(for: .seconds(3))
            }
            if !app.isRunning(.redis) { info = nil }
        }
        .confirmationDialog("Delete all data in Redis?", isPresented: $confirmFlush) {
            Button("Flush All Data", role: .destructive) { run(["FLUSHALL"], done: "All keys deleted.") }
        } message: {
            Text("Every key in every database is removed. This can't be undone.")
        }
    }

    private func run(_ args: [String], done: String) {
        Task {
            let r = await RedisServer.run(args, settings: app.config.redis, prefix: app.brew.prefix)
            message = r.ok ? done : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            info = await RedisServer.info(settings: app.config.redis, prefix: app.brew.prefix)
        }
    }
}

// MARK: - Settings

struct RedisSettingsTab: View {
    @Environment(AppState.self) private var app
    @State private var draft = RedisSettings()
    @State private var loaded = false

    private static let memoryChoices: [(String, Int)] = [("Unlimited", 0), ("64 MB", 64), ("128 MB", 128), ("256 MB", 256),
                                                         ("512 MB", 512), ("1 GB", 1024), ("2 GB", 2048)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RedisRestartBar()
            if let err = app.errors[.redis] { ErrorBanner(text: err) { app.errors[.redis] = nil } }
            Card(title: "Server") {
                FormRow(label: "Port") { NumberField(value: $draft.port) }
                FormRow(label: "Network") {
                    Toggle("Accept connections from other devices", isOn: $draft.allowNetwork)
                        .disabled(draft.password.isEmpty && !draft.allowNetwork)
                }
                FormRow(label: "Databases") { NumberField(value: $draft.databases) }
            }
            Card(title: "Password",
                 footer: draft.allowNetwork
                    ? "Redis connections aren't encrypted. Use network access only on a network you trust."
                    : "A password is required before other devices can connect.") {
                FormRow(label: "Password") {
                    HStack {
                        TextField("None", text: $draft.password).textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Button("Generate") { draft.password = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)) }
                            .glassButton()
                    }
                }
            }
            Card(title: "Memory") {
                FormRow(label: "Limit") {
                    Picker("", selection: $draft.maxMemoryMB) {
                        ForEach(Self.memoryChoices, id: \.1) { Text($0.0).tag($0.1) }
                        if !Self.memoryChoices.contains(where: { $0.1 == draft.maxMemoryMB }) { Text("\(draft.maxMemoryMB) MB").tag(draft.maxMemoryMB) }
                    }
                    .labelsHidden().fixedSize()
                }
                FormRow(label: "When Full") {
                    Picker("", selection: $draft.evictionPolicy) {
                        ForEach(RedisServer.policies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize().disabled(draft.maxMemoryMB == 0)
                }
            }
            Card(title: "Saving", footer: "Snapshots save the data now and then and when Redis stops. The append-only file logs every write (slower, safer).") {
                FormRow(label: "Snapshots") { Toggle("Save snapshots to disk", isOn: $draft.snapshots) }
                FormRow(label: "Append-Only") { Toggle("Log every write to disk", isOn: $draft.appendOnly) }
            }
            HStack {
                Spacer()
                Button("Revert") { draft = app.config.redis }.glassButton().disabled(draft == app.config.redis)
                Button("Save") {
                    let d = draft
                    app.update { $0.redis = d }
                    if app.isRunning(.redis) { app.redisNeedsRestart = true }
                }
                .glassButton(prominent: true)
                .disabled(draft == app.config.redis || draft.port < 1 || draft.port > 65535 || (draft.allowNetwork && draft.password.isEmpty))
            }
        }
        .onAppear { if !loaded { draft = app.config.redis; loaded = true } }
    }
}

// MARK: - Console

struct RedisConsoleTab: View {
    @Environment(AppState.self) private var app
    @State private var line = ""
    @State private var history: [(command: String, output: String, failed: Bool)] = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !app.isRunning(.redis) {
                Card { Text("Start Redis to run commands.").foregroundStyle(.secondary) }
            }
            Card(footer: "Runs commands like redis-cli, for example SET greeting hello, GET greeting or KEYS *.") {
                HStack {
                    TextField("PING", text: $line).textFieldStyle(.roundedBorder).font(.body.monospaced()).onSubmit(run)
                    Button("Run", action: run).glassButton(prominent: true)
                        .disabled(line.trimmingCharacters(in: .whitespaces).isEmpty || working || !app.isRunning(.redis))
                }
            }
            ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text("> " + entry.command).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Text(entry.output.isEmpty ? "(empty)" : entry.output)
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .foregroundStyle(entry.failed ? Color.orange : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func run() {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !working, app.isRunning(.redis) else { return }
        guard let args = RedisServer.tokenize(text), let first = args.first?.lowercased() else {
            history.insert((text, "Unbalanced quotes.", true), at: 0); return
        }
        if ["shutdown", "debug", "monitor", "subscribe", "psubscribe"].contains(first) {
            history.insert((text, first == "shutdown" ? "Use the Stop button to stop Redis." : "This command can't be used in the console.", true), at: 0)
            line = ""; return
        }
        working = true
        line = ""
        Task {
            let r = await RedisServer.run(args, settings: app.config.redis, prefix: app.brew.prefix)
            history.insert((text, r.output.trimmingCharacters(in: .whitespacesAndNewlines), !r.ok), at: 0)
            if history.count > 50 { history.removeLast() }
            working = false
        }
    }
}
