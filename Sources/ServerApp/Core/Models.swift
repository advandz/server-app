// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

enum WebServer: String, Codable, CaseIterable, Identifiable {
    case apache, nginx
    var id: String { rawValue }
    var title: String { self == .apache ? "Apache" : "Nginx" }
}

// MARK: - Website

enum SiteRuntime: String, Codable, CaseIterable, Identifiable {
    case php, node
    var id: String { rawValue }
    var title: String { self == .php ? "PHP" : "Node.js" }
}

/// A Node.js app Server runs and puts behind the web server as a reverse proxy.
struct NodeSiteSettings: Codable, Hashable {
    var version = ""                 // nvm version (v22.21.1); "" = nvm's default
    var command = "npm start"        // run in the site folder
    var port = 3000                  // where the app listens (passed as PORT)
    var environment = ""             // KEY=value lines

    var environmentPairs: [(String, String)] {
        environment.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
            return (String(t[..<eq]).trimmingCharacters(in: .whitespaces), String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
    }
}

struct Website: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var hostname: String
    var aliases: String = ""                 // space separated
    var documentRoot: String
    var enabled = true
    var server: WebServer = .apache
    var phpFormula: String = "php"           // "" = no PHP, otherwise a Homebrew formula (php, php@8.4…)
    var runtime: SiteRuntime = .php
    var node = NodeSiteSettings()
    var customHTTPPort: Int? = nil
    var customHTTPSPort: Int? = nil
    var ssl = SSLSettings()
    var apache = ApacheSiteOverrides()
    var nginx = NginxSiteOverrides()

    var aliasList: [String] { aliases.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) }
    var allHostnames: [String] { [hostname] + aliasList }
    /// The PHP formula that serves this site; "" for static and Node.js sites.
    var servedPHP: String { runtime == .php ? phpFormula : "" }
    var isNode: Bool { runtime == .node }
    var slug: String {
        let s = hostname.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct SSLSettings: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable { case selfSigned, custom }
    var enabled = false
    var mode: Mode = .selfSigned
    var certificatePath = ""
    var keyPath = ""
    var redirectHTTP = false
}

struct ApacheSiteOverrides: Codable, Hashable {
    var indexes = false
    var followSymLinks = true
    var symLinksIfOwnerMatch = false
    var includes = false
    var includesNoExec = false
    var execCGI = false
    var multiViews = false
    var allowOverride = "All"                // "All", "None" or a custom list
    var require = "all granted"
    var directoryParams = ""
    var directoryIndex = ""
    var virtualHostParams = ""
    var serverAdmin = ""
}

struct NginxSiteOverrides: Codable, Hashable {
    var directoryIndex = ""
    var autoindex = false
    var tryFiles = ""
    var locationParams = ""
    var serverParams = ""
    var allow = ""                           // one value per line, empty = all
    var deny = ""
}

// MARK: - Databases

struct DatabaseRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var user: String
    var password: String
    var websiteID: UUID?
}

// MARK: - Server settings

struct ApacheSettings: Codable, Hashable {
    var httpPort = 80
    var httpsPort = 443
    var serverAdmin = ""
    var timeout = 60
    var keepAlive = true
    var keepAliveTimeout = 5
    var maxRequestWorkers = 150
    var logLevel = "warn"
    var serverTokensProd = true
    var enabledModules: [String]? = nil      // nil = defaults
    var customConfig = ""
}

struct NginxSettings: Codable, Hashable {
    var httpPort = 8080
    var httpsPort = 8443
    var workerProcesses = "auto"
    var workerConnections = 1024
    var keepaliveTimeout = 65
    var clientMaxBodySize = "64m"
    var logLevel = "warn"
    // Config-level extensions (Homebrew's nginx modules are compiled in, so these are toggled in config)
    var gzip = true
    var gzipStatic = false
    var http2 = true
    var serverTokens = false
    var stubStatus = false
    var sendfile = true
    var customConfig = ""
}

struct MySQLSettings: Codable, Hashable {
    var formula = "mysql@8.4"
    var port = 3306
    var maxConnections = 151
    var innodbBufferPoolSize = "128M"
    var maxAllowedPacket = "64M"
    var characterSet = "utf8mb4"
    var collation = "utf8mb4_unicode_ci"
    var sqlMode = ""
    var customConfig = ""
}

struct AppConfig: Codable {
    var websites: [Website] = []
    var databases: [DatabaseRecord] = []
    var apache = ApacheSettings()
    var nginx = NginxSettings()
    var mysql = MySQLSettings()
    var ftp = FTPSettings()
    var dns = DNSSettings()
    var ai = AIServerSettings()
    var redis = RedisSettings()
    var cloudflare = CloudflareSettings()
    var stopServicesOnQuit = false
    var startupMode = StartupMode.none

    init() {}
    // Tolerant decoding so new fields never wipe an existing config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        websites = (try? c.decode([Website].self, forKey: .websites)) ?? []
        databases = (try? c.decode([DatabaseRecord].self, forKey: .databases)) ?? []
        apache = (try? c.decode(ApacheSettings.self, forKey: .apache)) ?? ApacheSettings()
        nginx = (try? c.decode(NginxSettings.self, forKey: .nginx)) ?? NginxSettings()
        mysql = (try? c.decode(MySQLSettings.self, forKey: .mysql)) ?? MySQLSettings()
        ftp = (try? c.decode(FTPSettings.self, forKey: .ftp)) ?? FTPSettings()
        dns = (try? c.decode(DNSSettings.self, forKey: .dns)) ?? DNSSettings()
        ai = (try? c.decode(AIServerSettings.self, forKey: .ai)) ?? AIServerSettings()
        redis = (try? c.decode(RedisSettings.self, forKey: .redis)) ?? RedisSettings()
        cloudflare = (try? c.decode(CloudflareSettings.self, forKey: .cloudflare)) ?? CloudflareSettings()
        stopServicesOnQuit = (try? c.decode(Bool.self, forKey: .stopServicesOnQuit)) ?? false
        startupMode = (try? c.decode(StartupMode.self, forKey: .startupMode)) ?? .none
    }

    func httpPort(_ site: Website) -> Int { site.customHTTPPort ?? (site.server == .apache ? apache.httpPort : nginx.httpPort) }
    func httpsPort(_ site: Website) -> Int { site.customHTTPSPort ?? (site.server == .apache ? apache.httpsPort : nginx.httpsPort) }
    func sites(for server: WebServer) -> [Website] { websites.filter { $0.enabled && $0.server == server } }

    /// Ports each server will bind, used to detect collisions between Apache and Nginx.
    func ports(for server: WebServer) -> Set<Int> {
        var ports = Set<Int>()
        let sites = sites(for: server)
        if sites.isEmpty { ports.insert(server == .apache ? apache.httpPort : nginx.httpPort) }
        for s in sites { ports.insert(httpPort(s)); if s.ssl.enabled { ports.insert(httpsPort(s)) } }
        return ports
    }
}

// Codable defaults for structs with added fields: decode missing keys with defaults.
extension Website {
    enum CodingKeys: String, CodingKey { case id, name, hostname, aliases, documentRoot, enabled, server, phpFormula, runtime, node, customHTTPPort, customHTTPSPort, ssl, apache, nginx }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hostname = try c.decode(String.self, forKey: .hostname)
        documentRoot = try c.decode(String.self, forKey: .documentRoot)
        aliases = (try? c.decode(String.self, forKey: .aliases)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        server = (try? c.decode(WebServer.self, forKey: .server)) ?? .apache
        phpFormula = (try? c.decode(String.self, forKey: .phpFormula)) ?? "php"
        runtime = (try? c.decode(SiteRuntime.self, forKey: .runtime)) ?? .php
        node = (try? c.decode(NodeSiteSettings.self, forKey: .node)) ?? NodeSiteSettings()
        customHTTPPort = try? c.decodeIfPresent(Int.self, forKey: .customHTTPPort)
        customHTTPSPort = try? c.decodeIfPresent(Int.self, forKey: .customHTTPSPort)
        ssl = (try? c.decode(SSLSettings.self, forKey: .ssl)) ?? SSLSettings()
        apache = (try? c.decode(ApacheSiteOverrides.self, forKey: .apache)) ?? ApacheSiteOverrides()
        nginx = (try? c.decode(NginxSiteOverrides.self, forKey: .nginx)) ?? NginxSiteOverrides()
    }
}
