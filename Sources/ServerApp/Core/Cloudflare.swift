// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// Saved custom addresses on the Cloudflare page.
struct CloudflareSettings: Codable, Hashable {
    struct Custom: Codable, Hashable, Identifiable {
        var id = UUID()
        var name = ""
        var url = "http://localhost:3000"
    }
    var custom: [Custom] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        custom = (try? c.decode([Custom].self, forKey: .custom)) ?? []
    }
}

/// What to share and how cloudflared reaches it.
struct TunnelSpec: Hashable {
    let key: String                 // "site:<id>", "custom:<id>" or "ai"
    let title: String
    let origin: String              // address cloudflared connects to, on this Mac
    var hostHeader: String? = nil   // Host header to send (name-based virtual hosts)
    var insecureTLS = false         // origin has a self-signed certificate
    var needs: ServiceKind? = nil   // server that must be running
}

/// Cloudflare quick tunnels (`cloudflared tunnel --url …`): no account, a random
/// trycloudflare.com address each time. Tunnels are children of this app: they stop when it
/// quits, and any left over from a crash are stopped at the next launch.
@MainActor @Observable
final class CloudflareTunnels {
    enum State: Equatable {
        case stopped, starting, running(String), failed(String)
        var url: String? { if case .running(let u) = self { return u }; return nil }
        var isActive: Bool { switch self { case .starting, .running: true; default: false } }
        var description: String {
            switch self { case .stopped: "stopped"; case .starting: "starting"; case .running(let u): u; case .failed(let m): m }
        }
    }

    private(set) var states: [String: State] = [:]
    private(set) var started: [String: Date] = [:]
    @ObservationIgnored private var processes: [String: Process] = [:]
    @ObservationIgnored private var stopping: Set<String> = []
    @ObservationIgnored private var lastError: [String: String] = [:]
    @ObservationIgnored private var buffers: [String: String] = [:]
    @ObservationIgnored private var registered: Set<String> = []        // cloudflared connected to Cloudflare
    @ObservationIgnored private var pending: [String: String] = [:]     // address issued, not resolvable yet

    static let startTimeout: TimeInterval = 45
    static func binary(prefix: String) -> String { prefix + "/opt/cloudflared/bin/cloudflared" }

    func state(_ key: String) -> State { states[key] ?? .stopped }
    var runningCount: Int { states.values.filter { $0.url != nil }.count }
    var activeKeys: [String] { states.filter { $0.value.isActive }.map(\.key).sorted() }

    private static func slug(_ key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
    static func pidFile(_ key: String) -> String { Paths.run + "/cloudflared-\(slug(key)).pid" }
    static func logFile(_ key: String) -> String { Paths.logs + "/cloudflared-\(slug(key)).log" }

    // MARK: Start / stop

    /// Starts a quick tunnel. Returns an error message, or nil once it's starting.
    func start(_ spec: TunnelSpec, prefix: String) -> String? {
        guard !state(spec.key).isActive else { return nil }
        let exe = Self.binary(prefix: prefix)
        guard FileManager.default.isExecutableFile(atPath: exe) else { return "cloudflared isn't installed." }
        Paths.ensureDirectories()

        // An empty config file: a ~/.cloudflared/config.yml would otherwise stop quick tunnels working.
        let emptyConfig = Paths.work + "/cloudflared-empty.yml"
        if !FileManager.default.fileExists(atPath: emptyConfig) { FileManager.default.createFile(atPath: emptyConfig, contents: Data()) }

        var args = ["tunnel", "--no-autoupdate", "--config", emptyConfig, "--metrics", "127.0.0.1:0", "--url", spec.origin]
        if let host = spec.hostHeader { args += ["--http-host-header", host] }
        if spec.insecureTLS { args.append("--no-tls-verify") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let key = spec.key
        FileManager.default.createFile(atPath: Self.logFile(key), contents: nil)
        buffers[key] = ""
        registered.remove(key)
        pending[key] = nil
        lastError[key] = nil
        stopping.remove(key)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.consume(key, data) }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finished(key, status: proc.terminationStatus) }
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            states[key] = .failed("Couldn't start cloudflared: \(error.localizedDescription)")
            return "Couldn't start cloudflared: \(error.localizedDescription)"
        }
        processes[key] = process
        states[key] = .starting
        started[key] = Date()
        try? String(process.processIdentifier).write(toFile: Self.pidFile(key), atomically: true, encoding: .utf8)

        // Give up if Cloudflare never answers (no internet, blocked UDP/QUIC…).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.startTimeout))
            guard let self, self.state(key) == .starting, self.pending[key] == nil else { return }
            self.lastError[key] = "Cloudflare didn't answer in time. Check your internet connection and that outgoing connections to Cloudflare aren't blocked."
            self.processes[key]?.terminate()
        }
        return nil
    }

    func stop(_ key: String) {
        stopping.insert(key)
        processes[key]?.terminate()
        if processes[key] == nil { states[key] = .stopped }
    }

    func stopAll() { for key in activeKeys { stop(key) } }

    /// Synchronous version for app quit: nothing may stay public after Server closes.
    func stopAllNow() {
        for (key, process) in processes { stopping.insert(key); process.terminate() }
        for key in processes.keys { try? FileManager.default.removeItem(atPath: Self.pidFile(key)) }
    }

    /// Records a failure that happened before the tunnel could start (like a failed install).
    func fail(_ key: String, _ message: String) { states[key] = .failed(message) }

    /// Forget a failed tunnel's message.
    func clear(_ key: String) { if case .failed = state(key) { states[key] = .stopped } }

    /// Stops cloudflared processes left behind by a previous run that didn't exit cleanly.
    func cleanupOrphans() {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: Paths.run)) ?? []).filter { $0.hasPrefix("cloudflared-") && $0.hasSuffix(".pid") }
        for file in files {
            let path = Paths.run + "/" + file
            if let text = try? String(contentsOfFile: path, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 1, kill(pid, 0) == 0 {
                // Only if it really is cloudflared (pids get reused).
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/ps")
                task.arguments = ["-p", String(pid), "-o", "comm="]
                let out = Pipe(); task.standardOutput = out
                if (try? task.run()) != nil {
                    task.waitUntilExit()
                    let name = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    if name.contains("cloudflared") { kill(pid, SIGTERM) }
                }
            }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: Output

    private static let urlPattern = try? NSRegularExpression(pattern: #"https://[A-Za-z0-9-]+\.trycloudflare\.com"#)

    private func consume(_ key: String, _ data: Data) {
        if let handle = FileHandle(forWritingAtPath: Self.logFile(key)) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        }
        var text = (buffers[key] ?? "") + String(decoding: data, as: UTF8.self)
        if text.count > 6000 { text = String(text.suffix(6000)) }
        buffers[key] = text
        for line in text.split(whereSeparator: \.isNewline) where line.contains(" ERR ") || line.contains("failed") {
            lastError[key] = Self.summary(String(line))
        }
        if text.contains("Registered tunnel connection") { registered.insert(key) }
        if case .starting = state(key), pending[key] == nil, let rx = Self.urlPattern,
           let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            // Show it as shared only once the address works, so nobody opens it too early: a Mac
            // that looks up a name before it exists remembers that it doesn't for a while.
            let url = (text as NSString).substring(with: m.range)
            pending[key] = url
            Task { [weak self] in await self?.becomeReachable(key, url) }
        }
    }

    private func becomeReachable(_ key: String, _ url: String) async {
        let host = URL(string: url)?.host ?? ""
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, state(key) == .starting {
            if registered.contains(key), await Self.resolves(host) { break }
            try? await Task.sleep(for: .seconds(1))
        }
        if state(key) == .starting { states[key] = .running(url) }
        pending[key] = nil
    }

    /// Asks Cloudflare's public resolver whether the name exists yet (without touching this Mac's DNS cache).
    nonisolated private static func resolves(_ host: String) async -> Bool {
        guard var parts = URLComponents(string: "https://1.1.1.1/dns-query") else { return false }
        parts.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        guard let url = parts.url else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["Status"] as? Int) == 0, let answers = json["Answer"] as? [[String: Any]] else { return false }
        return !answers.isEmpty
    }

    /// The readable part of a cloudflared log line.
    private static func summary(_ line: String) -> String {
        var s = line
        if let r = s.range(of: " ERR ") { s = String(s[r.upperBound...]) }
        return s.trimmingCharacters(in: .whitespaces).prefix(240).description
    }

    private func finished(_ key: String, status: Int32) {
        processes[key] = nil
        registered.remove(key)
        pending[key] = nil
        try? FileManager.default.removeItem(atPath: Self.pidFile(key))
        started[key] = nil
        if stopping.remove(key) != nil {
            states[key] = .stopped
        } else {
            let detail = lastError[key].map { " \($0)" } ?? ""
            states[key] = .failed("The tunnel closed unexpectedly (status \(status)).\(detail)")
        }
    }
}

// MARK: - Local addresses

/// A user-entered address, checked to be on this Mac and turned into something cloudflared can use.
enum LocalAddress {
    struct Parsed { let origin: String; let hostHeader: String?; let insecureTLS: Bool }

    static func parse(_ text: String) -> Result<Parsed, LocalAddressError> {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .failure(.init("Enter an address, like http://localhost:3000.")) }
        if !raw.contains("://") { raw = "http://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return .failure(.init("That doesn't look like an http or https address."))
        }
        if !(url.path.isEmpty || url.path == "/") || url.query != nil {
            return .failure(.init("Enter just the address without a path. The whole site at that address is shared."))
        }
        guard isOnThisMac(host) else { return .failure(.init("Only addresses on this Mac can be shared.")) }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let isLiteral = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
        let originHost = isLiteral ? (host.contains(":") ? "[\(host)]" : host) : "127.0.0.1"
        return .success(Parsed(origin: "\(scheme)://\(originHost):\(port)", hostHeader: isLiteral ? nil : host, insecureTLS: scheme == "https"))
    }

    /// localhost, *.localhost, or any name or address that points at this Mac.
    static func isOnThisMac(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(h, nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        let mine = NetworkScanner.interfaceAddresses()
        let mine4 = Set(mine.values.flatMap { $0.v4.map(\.address) })
        let mine6 = Set(mine.values.flatMap(\.v6))
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let ai = node {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(ai.pointee.ai_addr, socklen_t(ai.pointee.ai_addrlen), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return false }
            let addr = String(cString: buf).components(separatedBy: "%")[0]
            let local = addr.hasPrefix("127.") || addr == "::1" || mine4.contains(addr) || mine6.contains(addr)
            if !local { return false }
            node = ai.pointee.ai_next
        }
        return true
    }
}

struct LocalAddressError: Error { let message: String; init(_ m: String) { message = m } }

// MARK: - App integration

extension AppState {
    func tunnelSpec(for site: Website) -> TunnelSpec {
        let kind: ServiceKind = site.server == .apache ? .apache : .nginx
        // HTTP sites go through their HTTP port; sites that redirect to HTTPS through the HTTPS one.
        if site.ssl.enabled && site.ssl.redirectHTTP {
            return TunnelSpec(key: "site:\(site.id)", title: site.name, origin: "https://127.0.0.1:\(config.httpsPort(site))",
                              hostHeader: site.hostname, insecureTLS: true, needs: kind)
        }
        return TunnelSpec(key: "site:\(site.id)", title: site.name, origin: "http://127.0.0.1:\(config.httpPort(site))",
                          hostHeader: site.hostname, needs: kind)
    }

    var aiTunnelSpec: TunnelSpec {
        // No Host override: the chat checks that a page's Origin matches the host it was served from.
        TunnelSpec(key: "ai", title: "AI Models chat", origin: "http://127.0.0.1:\(config.ai.port)", needs: .ai)
    }

    func tunnelSpec(forCustom custom: CloudflareSettings.Custom) -> Result<TunnelSpec, LocalAddressError> {
        LocalAddress.parse(custom.url).map {
            TunnelSpec(key: "custom:\(custom.id)", title: custom.name.isEmpty ? custom.url : custom.name,
                       origin: $0.origin, hostHeader: $0.hostHeader, insecureTLS: $0.insecureTLS)
        }
    }

    /// Installs cloudflared if needed and starts a quick tunnel. Returns an error message or nil.
    @discardableResult
    func shareOnline(_ spec: TunnelSpec) async -> String? {
        if let needs = spec.needs, !isRunning(needs) {
            let message = "Start \(needs.title) first, then share it."
            tunnelNotice(spec.key, message); return message
        }
        // cloudflared is installed automatically the first time it's needed.
        if !brew.isInstalled("cloudflared") {
            tunnelInstalling.insert(spec.key)
            defer { tunnelInstalling.remove(spec.key) }
            guard await brew.ensureInstalled("cloudflared") else {
                let message = "Couldn't install cloudflared with Homebrew. See Logs › Homebrew Activity."
                tunnelNotice(spec.key, message)
                tunnels.fail(spec.key, message)
                return message
            }
        }
        let error = tunnels.start(spec, prefix: brew.prefix)
        if let error { tunnelNotice(spec.key, error) }
        return error
    }

    private func tunnelNotice(_ key: String, _ message: String) { notice = message }
}
