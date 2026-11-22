// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Observation
import SystemConfiguration

/// Live facts about this Mac for the Server page and title bar: names, uptime, reachability
/// and public IP address.
@MainActor @Observable
final class SystemStatus {
    static let shared = SystemStatus()

    enum Reachability: Equatable {
        case checking, offline, localOnly, internet
        var label: String {
            switch self {
            case .checking: String(localized: "Checking…")
            case .offline: String(localized: "No network connection")
            case .localOnly: String(localized: "Local network only")
            case .internet: String(localized: "Connected to the internet")
            }
        }
    }

    private(set) var computerName = ""
    private(set) var localHostName = ""
    private(set) var bootTime = Date()
    private(set) var reachability: Reachability = .checking
    private(set) var connection = ""            // "Wi-Fi", "Ethernet"…
    private(set) var publicIP: String?
    private(set) var checkingPublicIP = false

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var lastPathOK: Bool?

    var hostName: String { localHostName.isEmpty ? ProcessInfo.processInfo.hostName : localHostName + ".local" }
    var uptime: TimeInterval { Date().timeIntervalSince(bootTime) }

    private init() {
        refreshNames()
        bootTime = Self.readBootTime() ?? Date()
        startMonitoring()
    }

    /// Screenshot mode: made-up names and addresses, so nothing personal is shown. Only honored
    /// together with SERVER_APP_SUPPORT (a scratch folder), like the other test switches.
    /// SERVER_APP_DEMO is "1", "light" or "dark" (the last two also force that appearance).
    static let demoValue: String? = ProcessInfo.processInfo.environment["SERVER_APP_SUPPORT"] == nil
        ? nil : ProcessInfo.processInfo.environment["SERVER_APP_DEMO"]
    static let demo = ["1", "light", "dark"].contains(demoValue ?? "")

    func refreshNames() {
        if Self.demo { computerName = "Mac mini"; localHostName = "mac-mini"; return }
        computerName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "This Mac"
        localHostName = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ""
    }

    // MARK: Reachability

    private func startMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let kind: String =
                path.usesInterfaceType(.wifi) ? "Wi-Fi" :
                path.usesInterfaceType(.wiredEthernet) ? "Ethernet" :
                path.usesInterfaceType(.cellular) ? "Cellular" :
                path.usesInterfaceType(.other) ? "Other" : ""
            Task { @MainActor [weak self] in self?.pathChanged(ok: ok, kind: kind) }
        }
        monitor.start(queue: DispatchQueue(label: "server.reachability"))
        self.monitor = monitor
    }

    private func pathChanged(ok: Bool, kind: String) {
        connection = kind
        guard ok != lastPathOK else { return }
        lastPathOK = ok
        if ok { Task { await refreshPublicIP() } } else { reachability = .offline; publicIP = nil }
    }

    /// Asks a public "what is my IP" service. Reaching it is also the internet check.
    func refreshPublicIP() async {
        guard !checkingPublicIP else { return }
        checkingPublicIP = true
        defer { checkingPublicIP = false }
        if Self.demo { publicIP = "203.0.113.24"; reachability = .internet; return }
        if reachability == .offline || reachability == .checking { reachability = .checking }
        let ip = await Self.fetchPublicIP()
        publicIP = ip
        reachability = ip != nil ? .internet : (lastPathOK == true ? .localOnly : .offline)
    }

    nonisolated private static func fetchPublicIP() async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config)
        for endpoint in ["https://api.ipify.org", "https://api64.ipify.org"] {
            guard let url = URL(string: endpoint),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count < 64,
                  text.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else { continue }
            return text
        }
        return nil
    }

    // MARK: Uptime

    nonisolated private static func readBootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    static func format(uptime: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = uptime >= 86_400 ? [.day, .hour, .minute] : [.hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: max(uptime, 60)) ?? "—"
    }

    // MARK: Renaming

    /// The local host name macOS derives from a computer name ("Abdy's Mac mini" → "Abdys-Mac-mini").
    static func localHostName(for name: String) -> String {
        let ascii = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        var out = ""
        for ch in ascii {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" || ch == "." { if !out.hasSuffix("-") { out.append("-") } }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((trimmed.isEmpty ? "Mac" : trimmed).prefix(63))
    }

    /// Why a local host name is invalid, or nil when it's fine (letters, digits and hyphens, up to 63).
    static func hostNameProblem(_ host: String) -> String? {
        if host.isEmpty { return "Enter a host name." }
        if host.count > 63 { return "Host names can be at most 63 characters." }
        if !host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
            return "Use only letters, numbers and hyphens."
        }
        if host.hasPrefix("-") || host.hasSuffix("-") { return "A host name can't start or end with a hyphen." }
        return nil
    }

    /// Sets the computer name (shown in Finder, AirDrop and Sharing). macOS asks for an
    /// administrator password. Returns an error message, "" if cancelled, or nil on success.
    func setComputerName(_ newName: String) async -> String? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a name." }
        return await scutilSet("ComputerName", name)
    }

    /// Sets the local host name (the "name.local" address other devices use).
    func setLocalHostName(_ newHost: String) async -> String? {
        let host = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.hostNameProblem(host) { return problem }
        return await scutilSet("LocalHostName", host)
    }

    private func scutilSet(_ key: String, _ value: String) async -> String? {
        // The value is passed as an argument, never spliced into the script.
        let script = [
            "on run argv",
            "do shell script \"/usr/sbin/scutil --set \(key) \" & quoted form of (item 1 of argv) with administrator privileges",
            "end run",
        ]
        var args: [String] = []
        for line in script { args += ["-e", line] }
        let r = await Shell.run("/usr/bin/osascript", args + [value])
        refreshNames()
        if r.ok { return nil }
        if r.output.contains("-128") || r.output.localizedCaseInsensitiveContains("cancel") { return "" }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
