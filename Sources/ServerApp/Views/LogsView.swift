// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

/// One log: a file in the logs folder, or Homebrew's in-app activity (path nil).
struct LogSource: Identifiable, Hashable {
    let id: String
    let group: String
    let title: String
    let path: String?
}

/// Every log Server writes, grouped for the Logs page. Files are discovered by scanning the
/// logs folder, so per-site, HTTPS and PHP logs show up as soon as they exist.
enum LogCatalog {
    static let groupOrder = ["Server", "Apache", "Nginx", "PHP", "MySQL", "Redis", "FTP", "DNS", "AI Models", "Cloudflare"]

    @MainActor
    static func sources(config: AppConfig) -> [LogSource] {
        var out = [LogSource(id: "brew", group: "Server", title: "Homebrew Activity", path: nil)]
        let fm = FileManager.default

        for file in ((try? fm.contentsOfDirectory(atPath: Paths.logs)) ?? []).sorted() where file.hasSuffix(".log") {
            let base = String(file.dropLast(4)), path = Paths.logs + "/" + file
            let name = base.hasPrefix("cloudflared-") ? tunnelTitle(String(base.dropFirst("cloudflared-".count)), config: config) : title(for: base)
            out.append(LogSource(id: path, group: group(for: base), title: name, path: path))
        }

        let sites = Dictionary(config.websites.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a })
        for file in ((try? fm.contentsOfDirectory(atPath: Paths.siteLogs)) ?? []).sorted() where file.hasSuffix(".log") {
            var base = String(file.dropLast(4)), parts: [String] = []
            let kind = base.hasSuffix("-access") ? "Access Log" : base.hasSuffix("-error") ? "Error Log"
                : base.hasSuffix("-node") ? "Node.js Output" : "Log"
            if kind != "Log" { base = String(base[..<base.lastIndex(of: "-")!]) }
            if kind == "Node.js Output" {
                let path = Paths.siteLogs + "/" + file
                out.append(LogSource(id: path, group: sites[base] ?? base, title: kind, path: path))
                continue
            }
            if base.hasSuffix("-ssl") { base.removeLast(4); parts.append("HTTPS") }
            if base.hasSuffix("-nginx") { base.removeLast(6); parts.insert("Nginx", at: 0) } else { parts.insert("Apache", at: 0) }
            let path = Paths.siteLogs + "/" + file
            out.append(LogSource(id: path, group: sites[base] ?? base,
                                 title: "\(kind) (\(parts.joined(separator: ", ")))", path: path))
        }

        return out.sorted { a, b in
            let ga = groupOrder.firstIndex(of: a.group) ?? groupOrder.count
            let gb = groupOrder.firstIndex(of: b.group) ?? groupOrder.count
            if ga != gb { return ga < gb }
            if a.group != b.group { return a.group.localizedStandardCompare(b.group) == .orderedAscending }
            return rank(a.title) < rank(b.title) || (rank(a.title) == rank(b.title) && a.title < b.title)
        }
    }

    /// "site-<id>", "custom-<id>" or "ai" → a readable name.
    @MainActor private static func tunnelTitle(_ suffix: String, config: AppConfig) -> String {
        if suffix == "ai" { return "Tunnel: AI chat" }
        if suffix.hasPrefix("site-"), let id = UUID(uuidString: String(suffix.dropFirst(5))),
           let site = config.websites.first(where: { $0.id == id }) { return "Tunnel: \(site.name)" }
        if suffix.hasPrefix("custom-"), let id = UUID(uuidString: String(suffix.dropFirst(7))),
           let entry = config.cloudflare.custom.first(where: { $0.id == id }) { return "Tunnel: \(entry.name.isEmpty ? entry.url : entry.name)" }
        return "Tunnel"
    }

    private static func group(for base: String) -> String {
        if base.hasPrefix("apache") { return "Apache" }
        if base.hasPrefix("nginx") { return "Nginx" }
        if base.hasPrefix("mysql") { return "MySQL" }
        if base.hasPrefix("php") { return "PHP" }
        if base.hasPrefix("ftp") { return "FTP" }
        if base.hasPrefix("dns") { return "DNS" }
        if base.hasPrefix("redis") { return "Redis" }
        if base.hasPrefix("cloudflared") { return "Cloudflare" }
        if base.hasPrefix("ai_") { return "AI Models" }
        return "Server"
    }

    private static func title(for base: String) -> String {
        if base.hasPrefix("php") {
            // php-8.3-fpm / php-error / php-8.3-start
            let suffix = base.split(separator: "-").last.map(String.init) ?? ""
            let tag = String(base.dropLast(suffix.count + 1))
            let label = tag == "php" ? "PHP (latest)" : "PHP " + tag.replacingOccurrences(of: "php-", with: "")
            switch suffix {
            case "fpm": return "\(label) FPM Log"
            case "error": return "\(label) Errors"
            case "start": return "\(label) Startup Output"
            default: return base
            }
        }
        if base.hasSuffix("_error") { return "Error Log" }
        if base.hasSuffix("_access") { return "Access Log" }
        if base.hasSuffix("_start") { return "Startup Output" }
        if base.hasSuffix("_transfer") { return "Transfer Log" }
        if base == "dns" || base == "redis" { return "Server Log" }
        if base == "ai_requests" { return "Requests" }
        return base
    }

    private static func rank(_ title: String) -> Int {
        title.hasPrefix("Homebrew") ? 0 : title.hasPrefix("Error") ? 1 : title.hasPrefix("Access") ? 2 : 3
    }
}

// MARK: - Logs page

struct LogsView: View {
    @Environment(AppState.self) private var app
    @State private var selection: String? = "brew"
    @State private var sources: [LogSource] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(symbol: "doc.text.magnifyingglass", title: "Logs",
                       subtitle: "Every server, PHP and website log in one place", tint: .gray)
            HStack(alignment: .top, spacing: 14) {
                List(selection: $selection) {
                    ForEach(groups, id: \.self) { group in
                        Section(group) {
                            ForEach(sources.filter { $0.group == group }) { source in
                                Label(source.title, systemImage: source.path == nil ? "shippingbox" : "doc.plaintext")
                                    .lineLimit(1)
                                    .tag(source.id)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(width: 270)
                .glassPanel(18)

                Group {
                    if let source = sources.first(where: { $0.id == selection }) {
                        LogDetail(source: source).id(source.id)
                    } else {
                        Text("Select a log").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel(18)
            }
        }
        // Same width and padding as DetailPage, so the header lines up with other pages.
        .padding(28)
        .frame(maxWidth: DetailPage<EmptyView, EmptyView>.maxWidth)
        .frame(maxWidth: .infinity)
        .task {
            while !Task.isCancelled {
                let found = LogCatalog.sources(config: app.config)
                if found != sources { sources = found }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for s in sources where !seen.contains(s.group) { seen.append(s.group) }
        return seen
    }
}

/// Live tail of one log, with a filter.
struct LogDetail: View {
    @Environment(AppState.self) private var app
    let source: LogSource
    @State private var text = ""
    @State private var filter = ""
    @State private var info = ""
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(source.group) · \(source.title)").font(.headline)
                    Text(source.path ?? "Output of Homebrew commands run by Server")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if !info.isEmpty { Text(info).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                if let path = source.path {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }.glassButton()
                    Button("Clear…") { confirmClear = true }.glassButton()
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(shown.isEmpty ? (filter.isEmpty ? "No log entries." : "No matching lines.") : shown)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(shown.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: text) { proxy.scrollTo("end") }
                .onAppear { proxy.scrollTo("end") }
            }
        }
        .padding(16)
        .confirmationDialog("Clear this log?", isPresented: $confirmClear) {
            Button("Clear Log", role: .destructive) {
                if let path = source.path { try? "".write(toFile: path, atomically: true, encoding: .utf8); text = "" }
            }
        } message: {
            Text("Its contents are deleted. The server keeps writing new entries to it.")
        }
        .task {
            while !Task.isCancelled {
                if let path = source.path {
                    let (t, i) = await Task.detached { (ProcessInfoHelper.tail(path, lines: 1000), Self.describe(path)) }.value
                    if t != text { text = t }
                    info = i
                } else {
                    let t = app.brew.activity.joined(separator: "\n")
                    if t != text { text = t }
                    info = app.brew.busyTask ?? ""
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var shown: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }

    nonisolated private static func describe(_ path: String) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: (a[.size] as? Int64) ?? 0, countStyle: .file)
        let date = (a[.modificationDate] as? Date).map { "updated " + $0.formatted(.relative(presentation: .named)) } ?? ""
        return [size, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
