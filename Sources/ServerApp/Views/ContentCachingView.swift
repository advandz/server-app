// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

/// macOS Content Caching (AssetCache): keeps a local copy of software updates, apps and iCloud
/// data for devices on the network. Status and settings are read without privileges through
/// AssetCacheManagerUtil; activating, clearing and changing settings need an administrator.
enum ContentCaching {
    static let tool = "/usr/bin/AssetCacheManagerUtil"
    static let prefs = "/Library/Preferences/com.apple.AssetCache"

    struct Status: Sendable {
        var activated = false
        var active = false
        var cacheUsed: Int64 = 0
        var cacheFree: Int64 = 0
        var cacheLimit: Int64 = 0              // 0 = unlimited
        var cacheStatus = ""
        var port = 0
        var peers = 0
        var parents = 0
        var registrationError: String?
        var startupStatus = ""
        var returnedToClients: Int64 = 0
        var storedFromOrigin: Int64 = 0
        var since: String?
        var details: [(String, Int64)] = []    // per-category usage
    }

    struct Settings: Sendable {
        var allowPersonal = true
        var allowShared = true
        var cacheLimit: Int64 = 0
        var dataPath = ""
        var localSubnetsOnly = true
    }

    enum Content: String, CaseIterable, Identifiable {
        case all = "All Content", shared = "Shared Content", personal = "iCloud Content"
        var id: Self { self }
        var detail: String {
            switch self {
            case .all: "Software updates, apps and iCloud data"
            case .shared: "Software updates and apps"
            case .personal: "iCloud data such as photos and documents"
            }
        }
    }

    static func readStatus() async -> Status {
        let r = await Shell.run(tool, ["-j", "status"])
        guard let result = json(r.output) else { return Status() }
        var s = Status()
        s.activated = result["Activated"] as? Bool ?? false
        s.active = result["Active"] as? Bool ?? false
        s.cacheUsed = int(result["CacheUsed"])
        s.cacheFree = int(result["CacheFree"])
        s.cacheLimit = int(result["CacheLimit"])
        s.cacheStatus = result["CacheStatus"] as? String ?? ""
        s.port = Int(int(result["Port"]))
        s.peers = (result["Peers"] as? [Any])?.count ?? 0
        s.parents = (result["Parents"] as? [Any])?.count ?? 0
        s.registrationError = result["RegistrationError"] as? String
        s.startupStatus = result["StartupStatus"] as? String ?? ""
        s.returnedToClients = int(result["TotalBytesReturnedToClients"])
        s.storedFromOrigin = int(result["TotalBytesStoredFromOrigin"])
        s.since = (result["TotalBytesAreSince"] as? String).map { raw in
            // "2026-11-22 12:55:39 AM +0000" → local, readable date
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd h:mm:ss a Z"
            return f.date(from: raw)?.formatted(date: .abbreviated, time: .shortened) ?? raw
        }
        if let details = result["CacheDetails"] as? [String: Any] {
            s.details = details.map { ($0.key, int($0.value)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        }
        return s
    }

    static func readSettings() async -> Settings {
        let r = await Shell.run(tool, ["-j", "settings"])
        guard let result = json(r.output) else { return Settings() }
        var s = Settings()
        s.allowPersonal = result["AllowPersonalCaching"] as? Bool ?? true
        s.allowShared = result["AllowSharedCaching"] as? Bool ?? true
        s.cacheLimit = int(result["CacheLimit"])
        s.dataPath = result["DataPath"] as? String ?? ""
        s.localSubnetsOnly = result["LocalSubnetsOnly"] as? Bool ?? true
        return s
    }

    /// `{"name": …, "result": {…}}` from `-j`; log lines before the JSON are skipped.
    private static func json(_ output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["result"] as? [String: Any]
    }

    private static func int(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        return 0
    }

    /// Writes settings to the AssetCache preferences and asks the cache to reload them.
    static func apply(content: Content, limit: Int64) -> [[String]] {
        [
            ["/usr/bin/defaults", "write", prefs, "AllowPersonalCaching", "-bool", content != .shared ? "true" : "false"],
            ["/usr/bin/defaults", "write", prefs, "AllowSharedCaching", "-bool", content != .personal ? "true" : "false"],
            ["/usr/bin/defaults", "write", prefs, "CacheLimit", "-int", String(limit)],
            [tool, "reloadSettings"],
        ]
    }
}

// MARK: - Page

struct ContentCachingView: View {
    @State private var status: ContentCaching.Status?
    @State private var settings: ContentCaching.Settings?
    @State private var working = false
    @State private var error: String?
    @State private var confirmClear = false

    private static let limits: [(String, Int64)] = [
        ("Unlimited", 0), ("25 GB", 25), ("50 GB", 50), ("100 GB", 100), ("250 GB", 250), ("500 GB", 500), ("1 TB", 1000),
    ].map { ($0.0, $0.1 * 1_000_000_000) }

    var body: some View {
        DetailPage {
            PageHeader(symbol: "arrow.down.circle.dotted", title: "Content Caching",
                       subtitle: "\(subtitle)", tint: .purple) {
                if working { ProgressView().controlSize(.small) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
                if let status, let settings {
                    statusCard(status)
                    usageCard(status)
                    settingsCard(settings)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                async let s = ContentCaching.readStatus()
                async let c = ContentCaching.readSettings()
                (status, settings) = await (s, c)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog("Clear the content cache?", isPresented: $confirmClear) {
            Button("Clear Cache", role: .destructive) { run([[ContentCaching.tool, "flushCache"]]) }
        } message: {
            Text("Devices download content from the internet again until the cache refills.")
        }
    }

    private var subtitle: String {
        guard let status else { return "macOS Content Caching" }
        return status.active ? "On · serving devices on your network" : status.activated ? "Starting…" : "Off"
    }

    private func statusCard(_ s: ContentCaching.Status) -> some View {
        Card(footer: "Content Caching keeps software updates, apps and iCloud data that devices on your network download, so they get them faster. Changes ask for an administrator password.") {
            FormRow(label: "Content Caching") {
                Toggle("Cache content for devices on this network", isOn: Binding(get: { s.activated }, set: { on in
                    run([[ContentCaching.tool, on ? "activate" : "deactivate"]])
                }))
                .disabled(working)
            }
            FormRow(label: "Status") {
                HStack(spacing: 8) {
                    StatusDot(color: s.active ? .green : s.activated ? .orange : .secondary)
                    Text(statusText(s)).foregroundStyle(.secondary)
                }
            }
            if s.active {
                FormRow(label: "Port") { Text(String(s.port)) }
                FormRow(label: "Peers") { Text("\(s.peers) peer\(s.peers == 1 ? "" : "s"), \(s.parents) parent\(s.parents == 1 ? "" : "s")") }
            }
        }
    }

    private func statusText(_ s: ContentCaching.Status) -> String {
        if s.active { return "Active" }
        if !s.activated { return "Off" }
        if let reason = s.registrationError, reason != "NOT_ACTIVATED" {
            return "Not active (\(reason.replacingOccurrences(of: "_", with: " ").lowercased()))"
        }
        return s.startupStatus == "FAILED" ? "Couldn't start" : "Starting…"
    }

    private func usageCard(_ s: ContentCaching.Status) -> some View {
        Card(title: "Cache") {
            let limit = s.cacheLimit > 0 ? s.cacheLimit : s.cacheUsed + s.cacheFree
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Color.purple.frame(width: max(0, geo.size.width * CGFloat(Double(s.cacheUsed) / Double(max(limit, 1)))))
                    Color.primary.opacity(0.08)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 12)
            FormRow(label: "Used") { Text(bytes(s.cacheUsed)) }
            FormRow(label: "Limit") { Text(s.cacheLimit > 0 ? bytes(s.cacheLimit) : "Unlimited") }
            FormRow(label: "Free on Disk") { Text(bytes(s.cacheFree)) }
            ForEach(s.details, id: \.0) { name, size in
                FormRow(label: "\(name)") { Text(bytes(size)).foregroundStyle(.secondary) }
            }
            FormRow(label: "Served to Devices") { Text(bytes(s.returnedToClients)) }
            FormRow(label: "Downloaded") {
                Text(bytes(s.storedFromOrigin) + (s.since.map { " since \($0)" } ?? "")).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Clear Cache…") { confirmClear = true }.glassButton().disabled(working || s.cacheUsed == 0)
            }
        }
    }

    private func settingsCard(_ c: ContentCaching.Settings) -> some View {
        let content: ContentCaching.Content = c.allowShared && c.allowPersonal ? .all : c.allowShared ? .shared : .personal
        return Card(title: "Settings") {
            FormRow(label: "Cache") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: Binding(get: { content }, set: { run(ContentCaching.apply(content: $0, limit: c.cacheLimit)) })) {
                        ForEach(ContentCaching.Content.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Text(content.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(label: "Cache Size") {
                Picker("", selection: Binding(get: { Self.limits.min { abs($0.1 - c.cacheLimit) < abs($1.1 - c.cacheLimit) }?.1 ?? 0 },
                                              set: { run(ContentCaching.apply(content: content, limit: $0)) })) {
                    ForEach(Self.limits, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().fixedSize()
            }
            FormRow(label: "Location") { Text(c.dataPath).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .disabled(working)
    }

    private func run(_ commands: [[String]]) {
        working = true
        Task {
            let result = await Privileged.run(commands)
            if let result, !result.isEmpty { error = result }
            async let s = ContentCaching.readStatus()
            async let c = ContentCaching.readSettings()
            (status, settings) = await (s, c)
            await SystemServices.shared.refresh()
            working = false
        }
    }
}

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
