// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

/// The object cache page: Memcached, for PHP and Node.js sites that cache data in memory.
struct MemcachedView: View {
    @Environment(AppState.self) private var app
    enum Tab: String, CaseIterable { case overview = "Overview", settings = "Settings" }
    @State private var tab: Tab = .overview

    var body: some View {
        DetailPage {
            PageHeader(symbol: "bolt.circle", title: "Object Caching", subtitle: "Memcached in-memory cache", tint: .teal) {
                ServiceControl(kind: .memcached)
            }
            TabStrip(selection: $tab)
        } content: {
            switch tab {
            case .overview: MemcachedOverviewTab()
            case .settings: MemcachedSettingsTab()
            }
        }
    }
}

private struct MemcachedRestartBar: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if app.memcachedNeedsRestart && app.isRunning(.memcached) {
            HStack {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                Text("Restart the object cache to apply your changes.")
                Spacer()
                Button("Restart") { Task { await app.restart(.memcached) } }.glassButton(prominent: true)
            }
            .padding(14)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct MemcachedOverviewTab: View {
    @Environment(AppState.self) private var app
    @State private var stats: MemcachedServer.Stats?
    @State private var confirmFlush = false
    @State private var message: String?

    var body: some View {
        let s = app.config.memcached
        VStack(alignment: .leading, spacing: 20) {
            MemcachedRestartBar()
            ServiceOverviewCard(kind: .memcached, formula: MemcachedServer.formula)
            Card(title: "Connection") {
                FormRow(label: "Address") { CopyText(text: "\(s.allowNetwork ? SystemStatus.shared.hostName : "127.0.0.1"):\(s.port)") }
                FormRow(label: "Access") {
                    Text(s.allowNetwork ? "This Mac and devices on the network" : "This Mac only").foregroundStyle(.secondary)
                }
            }
            if app.isRunning(.memcached) {
                Card(title: "Activity") {
                    if let stats {
                        FormRow(label: "Version") { Text("Memcached \(stats.version)").foregroundStyle(.secondary) }
                        FormRow(label: "Uptime") { Text(SystemStatus.format(uptime: TimeInterval(stats.uptime))).foregroundStyle(.secondary) }
                        FormRow(label: "Memory") {
                            Text("\(MemcachedServer.size(stats.bytes)) used of \(MemcachedServer.size(stats.limit))").foregroundStyle(.secondary)
                        }
                        FormRow(label: "Items") { Text("\(stats.items.formatted()) stored · \(stats.evictions.formatted()) evicted").foregroundStyle(.secondary) }
                        FormRow(label: "Clients") { Text("\(stats.connections) connected · \(stats.totalConnections.formatted()) since start").foregroundStyle(.secondary) }
                        FormRow(label: "Requests") { Text("\(stats.gets.formatted()) reads · \(stats.sets.formatted()) writes").foregroundStyle(.secondary) }
                        if stats.hits + stats.misses > 0 {
                            FormRow(label: "Hit Rate") { Text("\(Int(Double(stats.hits) / Double(stats.hits + stats.misses) * 100))%").foregroundStyle(.secondary) }
                        }
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Reading statistics…").foregroundStyle(.secondary) }
                    }
                }
                Card(title: "Cache", footer: message.map { LocalizedStringKey($0) }) {
                    HStack {
                        Text("Everything in the cache is lost when it stops.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Flush Cache…") { confirmFlush = true }.glassButton()
                    }
                }
            }
        }
        .task(id: app.state(.memcached)) {
            while !Task.isCancelled, app.isRunning(.memcached) {
                stats = await MemcachedServer.stats(port: app.config.memcached.port)
                try? await Task.sleep(for: .seconds(3))
            }
            if !app.isRunning(.memcached) { stats = nil }
        }
        .confirmationDialog("Empty the object cache?", isPresented: $confirmFlush) {
            Button("Flush Cache", role: .destructive) {
                Task {
                    let ok = await MemcachedServer.flush(port: app.config.memcached.port)
                    message = ok ? String(localized: "The cache was emptied.") : String(localized: "Couldn't empty the cache.")
                    stats = await MemcachedServer.stats(port: app.config.memcached.port)
                }
            }
        } message: {
            Text("Every cached item is removed. Websites fill the cache again as they run.")
        }
    }
}

struct MemcachedSettingsTab: View {
    @Environment(AppState.self) private var app
    @State private var draft = MemcachedSettings()
    @State private var loaded = false

    private static let memoryChoices = [16, 32, 64, 128, 256, 512, 1024, 2048]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MemcachedRestartBar()
            if let err = app.errors[.memcached] { ErrorBanner(text: err) { app.errors[.memcached] = nil } }
            Card(title: "Server",
                 footer: draft.allowNetwork ? "Memcached has no password and its connections aren't encrypted. Use network access only on a network you trust." : nil) {
                FormRow(label: "Port") { NumberField(value: $draft.port) }
                FormRow(label: "Network") { Toggle("Accept connections from other devices", isOn: $draft.allowNetwork) }
            }
            Card(title: "Memory") {
                FormRow(label: "Maximum") {
                    Picker("", selection: $draft.memoryMB) {
                        ForEach(Self.memoryChoices, id: \.self) { Text($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB").tag($0) }
                        if !Self.memoryChoices.contains(draft.memoryMB) { Text("\(draft.memoryMB) MB").tag(draft.memoryMB) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Card(title: "Performance") {
                FormRow(label: "Connections") { NumberField(value: $draft.maxConnections) }
                FormRow(label: "Threads") { NumberField(value: $draft.threads) }
            }
            Card(title: "Logging", footer: "The log is in Logs › Object Caching.") {
                FormRow(label: "Log Level") {
                    Picker("", selection: $draft.logLevel) {
                        Text("None").tag(0)
                        Text("Errors and warnings").tag(1)
                        Text("Every command").tag(2)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            HStack {
                Spacer()
                Button("Revert") { draft = app.config.memcached }.glassButton().disabled(draft == app.config.memcached)
                Button("Save") {
                    let d = draft
                    app.update { $0.memcached = d }
                    if app.isRunning(.memcached) { app.memcachedNeedsRestart = true }
                }
                .glassButton(prominent: true)
                .disabled(draft == app.config.memcached || draft.port < 1 || draft.port > 65535 || draft.maxConnections < 16 || draft.threads < 1)
            }
        }
        .onAppear { if !loaded { draft = app.config.memcached; loaded = true } }
    }
}
