// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable {
    case overview, network, firewall, hosts, logs, websites, cloudflare, fileSharing, ftp, ssh, screenSharing, dns, ai, caching, apache, nginx, mysql, redis, php, node

    @MainActor var title: String {
        switch self {
        case .overview: SystemStatus.shared.computerName
        case .network: String(localized: "Network")
        case .firewall: String(localized: "Firewall")
        case .hosts: String(localized: "Hosts")
        case .logs: String(localized: "Logs")
        case .fileSharing: String(localized: "File Sharing")
        case .ftp: "FTP"
        case .ssh: "SSH"
        case .screenSharing: String(localized: "Screen Sharing")
        case .dns: "DNS"
        case .ai: String(localized: "AI Models")
        case .caching: String(localized: "Content Caching")
        case .php: "PHP"
        case .node: "Node.js"
        case .websites: String(localized: "Websites")
        case .cloudflare: "Cloudflare"
        case .apache: "Apache"
        case .nginx: "Nginx"
        case .mysql: "MySQL"
        case .redis: "Redis"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "macmini"
        case .network: "network"
        case .firewall: "firewall"
        case .hosts: "list.bullet.rectangle"
        case .fileSharing: "folder.badge.person.crop"
        case .ftp: "arrow.up.arrow.down.square"
        case .ssh: "terminal"
        case .screenSharing: "rectangle.on.rectangle"
        case .dns: "point.3.filled.connected.trianglepath.dotted"
        case .ai: "apple.intelligence"
        case .caching: "arrow.down.circle.dotted"
        case .php: "chevron.left.forwardslash.chevron.right"
        case .node: "hexagon"
        case .logs: "doc.text.magnifyingglass"
        case .websites: "globe"
        case .cloudflare: "cloud"
        case .apache: "server.rack"
        case .nginx: "bolt.horizontal"
        case .mysql: "cylinder.split.1x2"
        case .redis: "memorychip"
        }
    }
    /// Realistic artwork, used instead of the symbol when available.
    var image: NSImage? {
        switch self {
        case .overview: SystemIcon.thisMac
        case .apache: SystemIcon.apacheMono
        case .nginx: SystemIcon.nginxMono
        case .mysql: SystemIcon.mysqlMono
        case .redis: SystemIcon.redisMono
        default: nil
        }
    }
    var service: ServiceKind? {
        switch self { case .apache: .apache; case .nginx: .nginx; case .mysql: .mysql; case .ftp: .ftp; case .dns: .dns; case .ai: .ai; case .redis: .redis; default: nil }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var selection: SidebarItem? = .overview
    /// The sidebar is always shown: no toggle button, and it snaps back if dragged closed.
    @State private var visibility: NavigationSplitViewVisibility = .all

    /// Full-height glass sidebar with the traffic lights inside it, like Finder.
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: $selection) {
                Section("Server") {
                    row(.overview)
                    row(.network)
                    row(.firewall)
                    row(.hosts)
                    row(.logs)
                }
                Section("Services") {
                    row(.websites)
                    row(.cloudflare)
                    row(.fileSharing)
                    row(.ftp)
                    row(.ssh)
                    row(.screenSharing)
                    row(.dns)
                    row(.ai)
                    row(.caching)
                }
                Section("Advanced") {
                    row(.apache)
                    row(.nginx)
                    row(.mysql)
                    row(.redis)
                    row(.php)
                    row(.node)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 230)
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
            .safeAreaInset(edge: .bottom) { BrewStatusBar().padding(10) }
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack(alignment: .top) {
                switch selection ?? .overview {
                case .overview: OverviewView()
                case .network: NetworkView()
                case .firewall: FirewallView()
                case .hosts: HostsView()
                case .fileSharing: FileSharingView()
                case .ftp: FTPView()
                case .ssh: SSHView()
                case .screenSharing: ScreenSharingView()
                case .dns: DNSView()
                case .ai: AIModelsView()
                case .caching: ContentCachingView()
                case .php: PHPView()
                case .node: NodeView()
                case .logs: LogsView()
                case .websites: WebsitesView()
                case .cloudflare: CloudflareView()
                case .apache: ApacheView()
                case .nginx: NginxView()
                case .mysql: MySQLView()
                case .redis: RedisView()
                }
                if let notice = app.notice {
                    Text(notice)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassPanel(20)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { app.notice = nil }
                }
            }
            .animation(.snappy, value: app.notice)
            .navigationTitle(SystemStatus.shared.hostName)
            .navigationSubtitle(SystemInfo.osVersion)
        }
        // macOS only runs the sidebar up under the traffic lights (as in Finder) when the
        // window has a toolbar, so keep one with a single invisible item.
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            }
        }
        .sheet(isPresented: Binding(get: { app.showSettings }, set: { app.showSettings = $0 })) { SettingsView() }
        .onChange(of: visibility) { if visibility != .all { visibility = .all } }
        .task { SystemServices.shared.start() }
    }

    private func row(_ item: SidebarItem) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: item.service.map { app.isRunning($0) ? .green : .clear }
                      ?? ((item == .cloudflare ? app.tunnels.runningCount > 0 : SystemServices.shared.isOn(item)) ? .green : .clear), size: 6)
            if let image = item.image {
                Label {
                    Text(item.title)
                } icon: {
                    if image.isTemplate {
                        // One-color project logo, tinted like the sidebar's SF Symbols.
                        Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                    } else {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                    }
                }
            } else {
                Label(item.title, systemImage: item.symbol)
            }
        }
        .tag(item)
    }
}

/// Bottom of the sidebar: what Homebrew is doing right now.
struct BrewStatusBar: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let brew = app.brew
        HStack(spacing: 8) {
            switch brew.phase {
            case .checking, .installingBrew, .updating:
                ProgressView().controlSize(.small)
                Text(brew.busyTask ?? "Checking Homebrew…").font(.caption).lineLimit(1)
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).font(.caption).lineLimit(2)
            case .ready:
                if let task = brew.busyTask {
                    ProgressView().controlSize(.small)
                    Text(task).font(.caption).lineLimit(1)
                } else {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Homebrew up to date").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassPanel(14)
    }
}
