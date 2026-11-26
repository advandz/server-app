// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

/// The macOS Application Firewall, read and changed through socketfilterfw.
/// Reading needs no privileges; every change asks for an administrator password.
enum Firewall {
    static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    struct Rule: Identifiable, Hashable, Sendable {
        var id: String { path }
        let path: String
        let allowed: Bool
        var name: String {
            let url = URL(fileURLWithPath: path)
            return url.pathExtension == "app" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        }
    }

    struct State: Equatable, Sendable {
        var enabled = false
        var blockAll = false
        var stealth = false
        var allowBuiltIn = false
        var allowDownloaded = false
        var rules: [Rule] = []
    }

    static func read() async -> State {
        async let global = Shell.run(tool, ["--getglobalstate"])
        async let block = Shell.run(tool, ["--getblockall"])
        async let stealth = Shell.run(tool, ["--getstealthmode"])
        async let signed = Shell.run(tool, ["--getallowsigned"])
        async let list = Shell.run(tool, ["--listapps"])
        let (g, b, s, sg, l) = await (global, block, stealth, signed, list)
        var state = State()
        state.enabled = g.output.contains("State = 1") || g.output.contains("State = 2")
        state.blockAll = b.output.localizedCaseInsensitiveContains("enabled") || g.output.contains("State = 2")
        state.stealth = s.output.localizedCaseInsensitiveContains("stealth mode enabled")
            || s.output.localizedCaseInsensitiveContains("mode is on")
        let lines = sg.output.split(separator: "\n").map(String.init)
        state.allowBuiltIn = lines.first { $0.localizedCaseInsensitiveContains("built-in") }?.contains("ENABLED") ?? false
        state.allowDownloaded = lines.first { $0.localizedCaseInsensitiveContains("downloaded") }?.contains("ENABLED") ?? false
        state.rules = parseRules(l.output)
        return state
    }

    /// `N : /path \n (Allow incoming connections)` pairs from --listapps.
    static func parseRules(_ text: String) -> [Rule] {
        var rules: [Rule] = []
        var pending: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let colon = line.range(of: " : "), Int(line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)) != nil {
                pending = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let path = pending, line.hasPrefix("(") {
                rules.append(Rule(path: path, allowed: line.localizedCaseInsensitiveContains("allow")))
                pending = nil
            }
        }
        return rules.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Runs socketfilterfw invocations with administrator privileges, in a single prompt.
    /// Returns an error message, "" if cancelled, or nil on success.
    static func run(_ commands: [[String]]) async -> String? {
        await Privileged.run(commands.map { [tool] + $0 })
    }
}

// MARK: - Firewall page

struct FirewallView: View {
    @Environment(AppState.self) private var app
    @State private var state = Firewall.State()
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var removing: Firewall.Rule?

    var body: some View {
        DetailPage {
            PageHeader(symbol: "firewall", title: "Firewall",
                       subtitle: loaded ? (state.enabled ? (state.blockAll ? "On · Blocking all incoming connections" : "On") : "Off")
                                        : "macOS Application Firewall",
                       tint: .orange) {
                if working { ProgressView().controlSize(.small) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
                if !loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
                } else {
                    settings
                    serverApps
                    rules
                }
            }
        }
        .task { await reload() }
        .confirmationDialog("Remove “\(removing?.name ?? "")” from the firewall?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { rule in
            Button("Remove", role: .destructive) { apply([["--remove", rule.path]]) }
        } message: { _ in
            Text("macOS asks again the next time it tries to accept incoming connections.")
        }
    }

    private var settings: some View {
        Card(footer: "Changes ask for an administrator password.") {
            toggle("Firewall", "Turn on the firewall", state.enabled) { ["--setglobalstate", $0 ? "on" : "off"] }
            Divider()
            toggle("Incoming", "Block all incoming connections", state.blockAll, disabled: !state.enabled) {
                ["--setblockall", $0 ? "on" : "off"]
            }
            toggle("", "Automatically allow built-in software to receive incoming connections", state.allowBuiltIn,
                   disabled: !state.enabled || state.blockAll) { ["--setallowsigned", $0 ? "on" : "off"] }
            toggle("", "Automatically allow downloaded signed software to receive incoming connections", state.allowDownloaded,
                   disabled: !state.enabled || state.blockAll) { ["--setallowsignedapp", $0 ? "on" : "off"] }
            toggle("", "Enable stealth mode (don't respond to pings or connection attempts from closed ports)", state.stealth,
                   disabled: !state.enabled) { ["--setstealthmode", $0 ? "on" : "off"] }
        }
    }

    /// The Homebrew binaries Server runs. They're not signed by a known developer, so macOS
    /// prompts (or blocks them) unless they have a rule.
    private var serverApps: some View {
        let g = app.generator
        let apps: [(String, String)] = [("Apache", g.httpdBinary), ("Nginx", g.nginxBinary), ("MySQL", g.mysqld),
                                        ("FTP", FTPServer.binary(prefix: app.brew.prefix)),
                                        ("DNS", DNSServer.binary(prefix: app.brew.prefix)),
                                        ("Redis", RedisServer.binary(prefix: app.brew.prefix)),
                                        ("Object Caching", MemcachedServer.binary(prefix: app.brew.prefix)),
                                        ("AI Models (Server)", Bundle.main.executablePath ?? "")]
            + app.phpRunning.sorted().map { (Homebrew.phpLabel($0, version: app.brew.version($0)) + " FPM", g.phpFPMBinary($0)) }
        return Card(title: "Server Software",
                    footer: "Allowing a server lets other devices on your network reach websites and databases on this Mac.") {
            ForEach(apps, id: \.1) { name, link in
                let path = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
                let installed = FileManager.default.isExecutableFile(atPath: path)
                let rule = state.rules.first { $0.path == path }
                HStack(spacing: 10) {
                    Text(name).frame(width: 150, alignment: .leading)
                    StatusDot(color: rule == nil ? .secondary : rule!.allowed ? .green : .red)
                    Text(!installed ? "Not installed" : rule == nil ? "No rule" : rule!.allowed ? "Allowed" : "Blocked")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if installed {
                        if rule?.allowed != true {
                            Button("Allow Incoming") { apply([["--add", path], ["--unblockapp", path]]) }.glassButton()
                        }
                        if rule?.allowed != false {
                            Button("Block") { apply([["--add", path], ["--blockapp", path]]) }.glassButton()
                        }
                    }
                }
                .disabled(working || !state.enabled)
            }
        }
    }

    private var rules: some View {
        Card(title: "App Rules", footer: state.rules.isEmpty ? "No apps have firewall rules yet." : nil) {
            ForEach(Array(state.rules.enumerated()), id: \.element.id) { index, rule in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: rule.path))
                        .resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.name).lineLimit(1)
                        Text(rule.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { rule.allowed }, set: { allow in
                        apply([[allow ? "--unblockapp" : "--blockapp", rule.path]])
                    })) {
                        Text("Allow").tag(true)
                        Text("Block").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Button { removing = rule } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove rule").accessibilityLabel("Remove Rule")
                }
                .disabled(working)
                if index < state.rules.count - 1 { Divider() }
            }
        }
    }

    private func toggle(_ label: String, _ title: String, _ value: Bool, disabled: Bool = false,
                        _ args: @escaping (Bool) -> [String]) -> some View {
        FormRow(label: LocalizedStringKey(label), labelWidth: 90) {
            Toggle(title, isOn: Binding(get: { value }, set: { apply([args($0)]) }))
                .disabled(disabled || working)
        }
    }

    private func apply(_ commands: [[String]]) {
        working = true
        Task {
            let result = await Firewall.run(commands)
            if let result, !result.isEmpty { error = result }
            await reload()
            working = false
        }
    }

    private func reload() async {
        state = await Firewall.read()
        loaded = true
    }
}
