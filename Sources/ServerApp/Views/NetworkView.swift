// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import SystemConfiguration

/// One network service (Wi-Fi, Ethernet…) or a bare interface (VPN tunnel, bridge, loopback).
struct NetworkEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let bsdName: String?
    let type: String                 // "Wi-Fi", "Ethernet", "Bridge", "VPN"…
    let isService: Bool
    let serviceEnabled: Bool
    let isActive: Bool
    let isPrimary: Bool
    let configMethod: String?        // "Using DHCP", "Manually"…
    let ipv4: [(address: String, mask: String?)]
    let router: String?
    let ipv6: [String]
    let ipv6Method: String?
    let dns: [String]
    let searchDomains: [String]
    let mac: String?
    let mtu: Int?
    let speed: UInt64?
    let ssid: String?                // Wi-Fi network name (needs Location Services access)

    var symbol: String {
        switch type {
        case "Wi-Fi": "wifi"
        case "Ethernet": "cable.connector.horizontal"
        case "Bridge", "Thunderbolt Bridge": "point.3.connected.trianglepath.dotted"
        case "VPN": "lock.shield"
        case "Loopback": "arrow.triangle.2.circlepath"
        case "Bluetooth": "dot.radiowaves.left.and.right"
        case "iPhone USB", "USB": "cable.connector"
        default: "network"
        }
    }
    var status: String {
        if isService && !serviceEnabled { return "Inactive" }
        return isActive ? "Connected" : "Not Connected"
    }
}

enum NetworkScanner {
    /// The IPv4 address of the primary (default route) interface.
    static func primaryIPv4() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Server" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else { return nil }
        return interfaceAddresses()[primary]?.v4.first?.address
    }

    static func scan() -> [NetworkEntry] {
        guard let store = SCDynamicStoreCreate(nil, "Server" as CFString, nil, nil) else { return [] }
        func value(_ key: String) -> [String: Any]? { SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] }

        let global = value("State:/Network/Global/IPv4")
        let primary = global?["PrimaryInterface"] as? String
        let addresses = interfaceAddresses()
        var entries: [NetworkEntry] = []
        var covered = Set<String>()

        // Network services in System Settings order.
        if let prefs = SCPreferencesCreate(nil, "Server" as CFString, nil),
           let set = SCNetworkSetCopyCurrent(prefs),
           let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] {
            let order = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
            let sorted = services.sorted {
                let a = order.firstIndex(of: (SCNetworkServiceGetServiceID($0) as String?) ?? "") ?? .max
                let b = order.firstIndex(of: (SCNetworkServiceGetServiceID($1) as String?) ?? "") ?? .max
                return a < b
            }
            for service in sorted {
                guard let id = SCNetworkServiceGetServiceID(service) as String? else { continue }
                let iface = SCNetworkServiceGetInterface(service)
                let bsd = iface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
                if let bsd { covered.insert(bsd) }
                let v4State = value("State:/Network/Service/\(id)/IPv4")
                let v6State = value("State:/Network/Service/\(id)/IPv6")
                let dnsState = value("State:/Network/Service/\(id)/DNS")
                let link = bsd.flatMap { value("State:/Network/Interface/\($0)/Link") }
                let addrs = bsd.flatMap { addresses[$0] }
                let v4Addresses = (v4State?["Addresses"] as? [String]) ?? addrs?.v4.map(\.address) ?? []
                let v4Masks = (v4State?["SubnetMasks"] as? [String]) ?? addrs?.v4.compactMap(\.mask) ?? []
                entries.append(NetworkEntry(
                    id: id,
                    name: SCNetworkServiceGetName(service) as String? ?? bsd ?? "Service",
                    bsdName: bsd,
                    type: iface.map(typeName) ?? "Other",
                    isService: true,
                    serviceEnabled: SCNetworkServiceGetEnabled(service),
                    isActive: (link?["Active"] as? Bool) ?? (v4State != nil || !(addrs?.v4.isEmpty ?? true)),
                    isPrimary: bsd != nil && bsd == primary,
                    configMethod: configMethod(service, kSCNetworkProtocolTypeIPv4, key: kSCPropNetIPv4ConfigMethod as String),
                    ipv4: v4Addresses.enumerated().map { ($1, $0 < v4Masks.count ? v4Masks[$0] : nil) },
                    router: v4State?["Router"] as? String,
                    ipv6: (v6State?["Addresses"] as? [String]) ?? addrs?.v6 ?? [],
                    ipv6Method: configMethod(service, kSCNetworkProtocolTypeIPv6, key: kSCPropNetIPv6ConfigMethod as String),
                    dns: (dnsState?["ServerAddresses"] as? [String]) ?? [],
                    searchDomains: (dnsState?["SearchDomains"] as? [String]) ?? [],
                    mac: iface.flatMap { SCNetworkInterfaceGetHardwareAddressString($0) as String? },
                    mtu: bsd.flatMap { addresses[$0]?.mtu },
                    speed: bsd.flatMap { addresses[$0]?.speed },
                    ssid: iface.map(typeName) == "Wi-Fi" ? WiFiAccess.ssid(interface: bsd) : nil
                ))
            }
        }

        // Other interfaces that are up and have an address (VPN tunnels, bridges, loopback).
        for (bsd, info) in addresses.sorted(by: { $0.key < $1.key })
        where !covered.contains(bsd) && info.up && (!info.v4.isEmpty || !info.v6.filter { !$0.hasPrefix("fe80") }.isEmpty) {
            let type = bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") || bsd.hasPrefix("ppp") ? "VPN"
                : bsd.hasPrefix("bridge") ? "Bridge" : bsd == "lo0" ? "Loopback" : "Other"
            entries.append(NetworkEntry(
                id: "if-" + bsd, name: type == "Loopback" ? "Loopback" : "\(type) (\(bsd))", bsdName: bsd, type: type,
                isService: false, serviceEnabled: true, isActive: info.running, isPrimary: bsd == primary,
                configMethod: nil, ipv4: info.v4, router: nil, ipv6: info.v6, ipv6Method: nil,
                dns: [], searchDomains: [], mac: info.mac, mtu: info.mtu, speed: info.speed, ssid: nil
            ))
        }
        return entries
    }

    private static func typeName(_ iface: SCNetworkInterface) -> String {
        let raw = SCNetworkInterfaceGetInterfaceType(iface) as String? ?? ""
        // Values of the kSCNetworkInterfaceType… constants.
        switch raw {
        case "IEEE80211": return "Wi-Fi"
        case "Ethernet":
            let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? ?? ""
            return name.localizedCaseInsensitiveContains("iPhone") ? "iPhone USB" : "Ethernet"
        case "Bridge": return "Thunderbolt Bridge"
        case "Bluetooth": return "Bluetooth"
        case "IPSec", "PPP", "L2TP", "VPN": return "VPN"
        default: return raw.isEmpty ? "Other" : raw
        }
    }

    private static func configMethod(_ service: SCNetworkService, _ proto: CFString, key: String) -> String? {
        guard let p = SCNetworkServiceCopyProtocol(service, proto),
              let config = SCNetworkProtocolGetConfiguration(p) as? [String: Any],
              let method = config[key] as? String else { return nil }
        switch method {
        case "DHCP": return "Using DHCP"
        case "Manual": return "Manually"
        case "BOOTP": return "Using BOOTP"
        case "INFORM": return "DHCP with manual address"
        case "Automatic": return "Automatically"
        case "LinkLocal": return "Link-local only"
        case "Off": return "Off"
        default: return method
        }
    }

    struct InterfaceInfo {
        var v4: [(address: String, mask: String?)] = []
        var v6: [String] = []
        var mac: String?
        var mtu: Int?
        var speed: UInt64?
        var up = false
        var running = false
    }

    /// Addresses, MTU and link speed for every interface, from getifaddrs.
    static func interfaceAddresses() -> [String: InterfaceInfo] {
        var result: [String: InterfaceInfo] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = node {
            defer { node = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            var info = result[name] ?? InterfaceInfo()
            let flags = Int32(ifa.pointee.ifa_flags)
            info.up = info.up || (flags & IFF_UP) != 0
            info.running = info.running || (flags & IFF_RUNNING) != 0
            guard let addr = ifa.pointee.ifa_addr else { result[name] = info; continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                if let a = numeric(addr) {
                    info.v4.append((a, ifa.pointee.ifa_netmask.flatMap(numeric)))
                }
            case AF_INET6:
                if let a = numeric(addr) { info.v6.append(a.components(separatedBy: "%").first ?? a) }
            case AF_LINK:
                if let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    info.mtu = Int(data.pointee.ifi_mtu)
                    if data.pointee.ifi_baudrate > 0 { info.speed = UInt64(data.pointee.ifi_baudrate) }
                }
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let len = Int(dl.pointee.sdl_alen)
                    guard len == 6 else { return }
                    let offset = Int(dl.pointee.sdl_nlen)
                    withUnsafeBytes(of: dl.pointee.sdl_data) { raw in
                        guard offset + len <= raw.count else { return }
                        info.mac = (0..<len).map { String(format: "%02x", raw[offset + $0]) }.joined(separator: ":")
                    }
                }
            default: break
            }
            result[name] = info
        }
        return result
    }

    private static func numeric(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(addr.pointee.sa_len)
        guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }
}

// MARK: - Network page

struct NetworkView: View {
    @State private var entries: [NetworkEntry] = []
    @State private var loaded = false

    var body: some View {
        DetailPage {
            PageHeader(symbol: "network", title: "Network",
                       subtitle: "\(subtitle)", tint: .blue)
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if !loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
                } else {
                    let services = entries.filter(\.isService), others = entries.filter { !$0.isService }
                    if !services.isEmpty {
                        Text("Network Services").font(.headline).foregroundStyle(.secondary).padding(.leading, 6)
                        ForEach(services) { NetworkCard(entry: $0) }
                    }
                    if !others.isEmpty {
                        Text("Other Interfaces").font(.headline).foregroundStyle(.secondary).padding(.leading, 6).padding(.top, 6)
                        ForEach(others) { NetworkCard(entry: $0) }
                    }
                }
            }
        }
        .task(id: WiFiAccess.shared.status.rawValue) {
            // Refresh while the page is open; addresses change as networks come and go.
            while !Task.isCancelled {
                entries = await Task.detached(priority: .userInitiated) { NetworkScanner.scan() }.value
                loaded = true
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var subtitle: String {
        let active = entries.filter { $0.isService && $0.isActive }.count
        return loaded ? "\(active) of \(entries.filter(\.isService).count) services connected" : "Network interfaces and settings"
    }
}

struct NetworkCard: View {
    let entry: NetworkEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let icon = SystemIcon.networkInterface(entry.type) {
                        // Same artwork as System Settings › Network.
                        Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .saturation(entry.isActive && entry.serviceEnabled ? 1 : 0)
                    } else {
                        Image(systemName: entry.symbol)
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.title3.weight(.semibold))
                        if entry.isPrimary { Badge(text: "Primary") }
                    }
                    HStack(spacing: 6) {
                        StatusDot(color: entry.isActive && entry.serviceEnabled ? .green : .secondary, size: 7)
                        Text(entry.status).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let first = entry.ipv4.first {
                    Text(first.address).font(.title3.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if entry.type == "Wi-Fi" { WiFiNameRow(entry: entry) }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    detail("Interface", entry.bsdName ?? "—")
                    detail("Hardware", entry.type)
                }
                GridRow {
                    detail("Configure IPv4", entry.configMethod ?? "—")
                    detail("Configure IPv6", entry.ipv6Method ?? "—")
                }
                GridRow {
                    detail("IP Address", entry.ipv4.map(\.address).joined(separator: ", ").nonEmpty ?? "—")
                    detail("Subnet Mask", entry.ipv4.compactMap(\.mask).joined(separator: ", ").nonEmpty ?? "—")
                }
                GridRow {
                    detail("Router", entry.router ?? "—")
                    detail("DNS Servers", entry.dns.joined(separator: ", ").nonEmpty ?? "—")
                }
                GridRow {
                    detail("IPv6 Address", entry.ipv6.first(where: { !$0.hasPrefix("fe80") }) ?? entry.ipv6.first ?? "—")
                    detail("Search Domains", entry.searchDomains.joined(separator: ", ").nonEmpty ?? "—")
                }
                GridRow {
                    detail("MAC Address", entry.mac ?? "—")
                    detail("MTU · Speed", [entry.mtu.map(String.init), entry.isActive ? entry.speed.map(speedText) : nil].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "—")
                }
            }
            .font(.callout)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
        .opacity(entry.isActive && entry.serviceEnabled ? 1 : 0.7)
    }

    private var tint: Color {
        guard entry.isActive && entry.serviceEnabled else { return .gray }
        return entry.type == "VPN" ? .indigo : .blue
    }

    private func speedText(_ bps: UInt64) -> String {
        bps >= 1_000_000_000 ? "\((Double(bps) / 1e9).formatted(.number.precision(.fractionLength(0...1)))) Gb/s"
            : "\((Double(bps) / 1e6).formatted(.number.precision(.fractionLength(0)))) Mb/s"
    }

    @ViewBuilder private func detail(_ label: String, _ value: String) -> some View {
        Text(label + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
        Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Wi-Fi network name, or a way to allow access to it.
struct WiFiNameRow: View {
    let entry: NetworkEntry
    private let access = WiFiAccess.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi").foregroundStyle(.secondary)
            Text("Network Name:").foregroundStyle(.secondary)
            if let ssid = entry.ssid {
                Text(ssid).fontWeight(.medium).textSelection(.enabled)
            } else if !entry.isActive {
                Text("Not connected to a network").foregroundStyle(.secondary)
            } else if access.allowed {
                Text("Hidden network").foregroundStyle(.secondary)
            } else {
                Text(access.denied ? "Location access is off for Server" : "macOS needs Location access to show it")
                    .foregroundStyle(.secondary)
                Button(access.denied ? "Open Privacy Settings…" : "Allow Location Access…") { access.request() }
                    .glassButton()
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
