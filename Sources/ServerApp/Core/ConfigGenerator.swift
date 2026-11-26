// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// Pure text generation for every config file the app manages. No I/O besides reading
/// the module directory, so it can be tested in isolation.
struct ConfigGenerator {
    let config: AppConfig
    let prefix: String                       // Homebrew prefix (/opt/homebrew or /usr/local)

    // MARK: Homebrew layout

    var httpdBinary: String { prefix + "/opt/httpd/bin/httpd" }
    var httpdModulesDir: String { prefix + "/opt/httpd/lib/httpd/modules" }
    var httpdMimeTypes: String { prefix + "/etc/httpd/mime.types" }
    var nginxBinary: String { prefix + "/opt/nginx/bin/nginx" }
    var nginxEtc: String { prefix + "/etc/nginx" }
    func phpFPMBinary(_ formula: String) -> String { prefix + "/opt/\(formula)/sbin/php-fpm" }
    func mysqlBin(_ tool: String) -> String { prefix + "/opt/\(config.mysql.formula)/bin/\(tool)" }

    static var apacheConfFile: String { Paths.apacheConf + "/httpd.conf" }
    static var nginxConfFile: String { Paths.nginxConf + "/nginx.conf" }
    static var mysqlConfFile: String { Paths.mysqlConf + "/my.cnf" }
    static func phpConfFile(_ formula: String) -> String { Paths.phpConf + "/\(Paths.phpTag(formula))-fpm.conf" }
    static var defaultDocRoot: String { Paths.support + "/default-www" }

    // MARK: Certificates

    static func certificatePaths(_ site: Website) -> (cert: String, key: String) {
        if site.ssl.mode == .custom { return (site.ssl.certificatePath, site.ssl.keyPath) }
        if site.ssl.mode == .stored, let id = site.ssl.certificateID {
            let dir = Paths.ssl + "/store/" + id.uuidString
            return (dir + "/cert.pem", dir + "/key.pem")
        }
        let dir = Paths.ssl + "/" + site.id.uuidString
        return (dir + "/cert.pem", dir + "/key.pem")
    }

    private func q(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "\"" + flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    /// Free text shown in a config comment, kept on one line.
    private func oneLine(_ s: String) -> String { s.components(separatedBy: .newlines).joined(separator: " ") }
    private func indent(_ block: String, _ n: Int = 4) -> String {
        let pad = String(repeating: " ", count: n)
        return block.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : pad + $0 }.joined(separator: "\n")
    }
    /// Nginx `listen` lines: every address, or just this Mac when other devices aren't allowed.
    private func listen(_ port: Int, _ flags: String = "") -> String {
        let tail = flags.isEmpty ? "" : " " + flags
        if config.webAllowNetwork { return "listen \(port)\(tail);\n" }
        return "listen 127.0.0.1:\(port)\(tail);\nlisten [::1]:\(port)\(tail);\n"
    }
    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Apache

    struct ApacheModule: Identifiable, Hashable {
        let file: String           // mod_rewrite.so
        var id: String { name }
        var name: String {         // rewrite_module
            String(file.dropFirst(4).dropLast(3)) + "_module"
        }
        var shortName: String { String(file.dropFirst(4).dropLast(3)) }
    }

    /// Modules Server needs to function; always loaded and locked in the UI.
    static let requiredApacheModules: Set<String> = [
        "mpm_event", "authz_core", "authz_host", "unixd", "log_config", "mime", "dir", "alias",
        "proxy", "proxy_fcgi", "proxy_http", "ssl", "socache_shmcb", "setenvif", "rewrite", "headers", "env",
    ]
    static let defaultApacheModules: Set<String> = requiredApacheModules.union([
        "access_compat", "auth_basic", "authn_core", "authn_file", "authz_groupfile", "authz_user",
        "autoindex", "deflate", "expires", "filter", "include", "negotiation", "reqtimeout", "version",
        "status", "http2", "cgi", "actions", "allowmethods", "remoteip", "unique_id", "brotli",
    ])
    /// MPMs are mutually exclusive; Server always uses event (works best with PHP-FPM).
    static let hiddenApacheModules: Set<String> = ["mpm_prefork", "mpm_worker"]

    func availableApacheModules() -> [ApacheModule] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: httpdModulesDir)) ?? []
        return files.filter { $0.hasPrefix("mod_") && $0.hasSuffix(".so") }
            .map(ApacheModule.init)
            .filter { !Self.hiddenApacheModules.contains($0.shortName) }
            .sorted { $0.shortName < $1.shortName }
    }

    func enabledApacheModules() -> Set<String> {
        let chosen = config.apache.enabledModules.map(Set.init) ?? Self.defaultApacheModules
        return chosen.union(Self.requiredApacheModules)
    }

    func apacheConfig() -> String {
        let a = config.apache
        let sites = config.sites(for: .apache)
        let ports = config.ports(for: .apache).sorted()
        let enabled = enabledApacheModules()
        let modules = availableApacheModules().filter { enabled.contains($0.shortName) }
        let threads = 25
        let workers = max(threads, (a.maxRequestWorkers / threads) * threads)

        var out = """
        # Generated by Server. Do not edit: changes are overwritten.
        ServerRoot \(q(prefix + "/opt/httpd"))
        DefaultRuntimeDir \(q(Paths.run + "/apache"))
        PidFile \(q(Paths.run + "/httpd.pid"))
        ServerName localhost
        Timeout \(a.timeout)
        KeepAlive \(a.keepAlive ? "On" : "Off")
        KeepAliveTimeout \(a.keepAliveTimeout)
        ServerTokens \(a.serverTokensProd ? "Prod" : "Full")
        ServerSignature Off
        LogLevel \(a.logLevel)
        ErrorLog \(q(Paths.logs + "/apache_error.log"))

        """
        if !trimmed(a.serverAdmin).isEmpty { out += "ServerAdmin \(trimmed(a.serverAdmin))\n" }
        out += ports.map { port in
            config.webAllowNetwork ? "Listen \(port)" : "Listen 127.0.0.1:\(port)\nListen [::1]:\(port)"
        }.joined(separator: "\n") + "\n\n"
        out += modules.map { "LoadModule \($0.name) \(q(httpdModulesDir + "/" + $0.file))" }.joined(separator: "\n")
        out += """


        <IfModule mpm_event_module>
            ThreadsPerChild \(threads)
            ServerLimit \(max(1, workers / threads))
            MaxRequestWorkers \(workers)
        </IfModule>

        TypesConfig \(q(httpdMimeTypes))
        LogFormat "%h %l %u %t \\"%r\\" %>s %b \\"%{Referer}i\\" \\"%{User-Agent}i\\"" combined
        CustomLog \(q(Paths.logs + "/apache_access.log")) combined
        DirectoryIndex index.php index.html index.htm
        DocumentRoot \(q(Self.defaultDocRoot))

        <Directory />
            AllowOverride None
            Require all denied
        </Directory>
        <Directory \(q(Self.defaultDocRoot))>
            Require all granted
        </Directory>
        <Files ".ht*">
            Require all denied
        </Files>
        <IfModule setenvif_module>
            SetEnvIf Authorization "(.*)" HTTP_AUTHORIZATION=$1
        </IfModule>
        <IfModule ssl_module>
            SSLSessionCache \(q("shmcb:" + Paths.run + "/apache/ssl_scache(512000)"))
            SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
        </IfModule>
        <IfModule http2_module>
            Protocols h2 h2c http/1.1
        </IfModule>

        """
        if !trimmed(a.customConfig).isEmpty { out += "# Custom configuration\n\(a.customConfig)\n\n" }

        for site in sites {
            out += "# ── \(oneLine(site.name)) (\(site.hostname))\n"
            let httpPort = config.httpPort(site)
            if site.ssl.enabled && site.ssl.redirectHTTP {
                let sp = config.httpsPort(site)
                let target = "https://\(site.hostname)\(sp == 443 ? "" : ":\(sp)")/"
                var body = "ServerName \(site.hostname)\n"
                if !site.aliasList.isEmpty { body += "ServerAlias \(site.aliasList.joined(separator: " "))\n" }
                body += "Redirect permanent / \(target)\n"
                out += "<VirtualHost *:\(httpPort)>\n\(indent(body))</VirtualHost>\n\n"
            } else {
                out += apacheVhost(site, port: httpPort, ssl: false)
            }
            if site.ssl.enabled { out += apacheVhost(site, port: config.httpsPort(site), ssl: true) }
        }
        return out
    }

    private func apacheVhost(_ site: Website, port: Int, ssl: Bool) -> String {
        let o = site.apache
        var options: [String] = []
        if o.indexes { options.append("Indexes") }
        if o.followSymLinks { options.append("FollowSymLinks") }
        if o.symLinksIfOwnerMatch { options.append("SymLinksIfOwnerMatch") }
        if o.includes { options.append("Includes") }
        if o.includesNoExec { options.append("IncludesNOEXEC") }
        if o.execCGI { options.append("ExecCGI") }
        if o.multiViews { options.append("MultiViews") }
        let logBase = Paths.siteLogs + "/" + site.slug + (ssl ? "-ssl" : "")
        let admin = trimmed(o.serverAdmin).isEmpty ? trimmed(config.apache.serverAdmin) : trimmed(o.serverAdmin)

        var body = "ServerName \(site.hostname)\n"
        if !site.aliasList.isEmpty { body += "ServerAlias \(site.aliasList.joined(separator: " "))\n" }
        body += "DocumentRoot \(q(site.documentRoot))\n"
        if !admin.isEmpty { body += "ServerAdmin \(admin)\n" }
        body += "ErrorLog \(q(logBase + "-error.log"))\n"
        body += "CustomLog \(q(logBase + "-access.log")) combined\n"
        if ssl {
            let c = Self.certificatePaths(site)
            body += "SSLEngine on\nSSLCertificateFile \(q(c.cert))\nSSLCertificateKeyFile \(q(c.key))\n"
        }
        var dir = "Options \(options.isEmpty ? "None" : options.joined(separator: " "))\n"
        dir += "AllowOverride \(trimmed(o.allowOverride).isEmpty ? "None" : trimmed(o.allowOverride))\n"
        let requires = o.require.split(separator: "\n").map { trimmed(String($0)) }.filter { !$0.isEmpty }
        if requires.isEmpty || requires == ["all granted"] { dir += "Require all granted\n" }
        else { dir += "<RequireAny>\n" + requires.map { "    Require " + ($0.contains(" ") ? $0 : "ip \($0)") }.joined(separator: "\n") + "\n</RequireAny>\n" }
        if !trimmed(o.directoryIndex).isEmpty { dir += "DirectoryIndex \(trimmed(o.directoryIndex))\n" }
        if !trimmed(o.directoryParams).isEmpty { dir += o.directoryParams + "\n" }
        body += "<Directory \(q(site.documentRoot))>\n\(indent(dir))</Directory>\n"
        if site.isNode {
            // Reverse proxy to the Node.js app, including WebSocket upgrades.
            let upstream = "http://127.0.0.1:\(site.node.port)/"
            body += "ProxyPreserveHost On\n"
            body += "RequestHeader set X-Forwarded-Proto \"\(ssl ? "https" : "http")\"\n"
            body += "ProxyPass / \(upstream) upgrade=websocket\n"
            body += "ProxyPassReverse / \(upstream)\n"
        }
        if !site.servedPHP.isEmpty {
            let tag = Paths.phpTag(site.servedPHP).replacingOccurrences(of: ".", with: "-")
            body += """
            <FilesMatch "\\.php$">
                <If "-f %{REQUEST_FILENAME}">
                    SetHandler "proxy:unix:\(Paths.phpSocket(site.servedPHP))|fcgi://\(tag)/"
                </If>
            </FilesMatch>

            """
        }
        if !trimmed(o.virtualHostParams).isEmpty { body += o.virtualHostParams + "\n" }
        return "<VirtualHost *:\(port)>\n\(indent(body))</VirtualHost>\n\n"
    }

    // MARK: - Nginx

    func nginxConfig() -> String {
        let n = config.nginx
        let run = Paths.run + "/nginx"
        var out = """
        # Generated by Server. Do not edit: changes are overwritten.
        worker_processes \(n.workerProcesses);
        pid \(q(Paths.run + "/nginx.pid"));
        error_log \(q(Paths.logs + "/nginx_error.log")) \(n.logLevel);

        events {
            worker_connections \(n.workerConnections);
        }

        http {
            include \(q(nginxEtc + "/mime.types"));
            default_type application/octet-stream;
            client_body_temp_path \(q(run + "/client_body"));
            proxy_temp_path \(q(run + "/proxy"));
            fastcgi_temp_path \(q(run + "/fastcgi"));
            uwsgi_temp_path \(q(run + "/uwsgi"));
            scgi_temp_path \(q(run + "/scgi"));
            access_log \(q(Paths.logs + "/nginx_access.log"));
            sendfile \(n.sendfile ? "on" : "off");
            keepalive_timeout \(n.keepaliveTimeout);
            client_max_body_size \(n.clientMaxBodySize);
            server_tokens \(n.serverTokens ? "on" : "off");

        """
        if n.gzip {
            out += "    gzip on;\n    gzip_vary on;\n    gzip_types text/plain text/css text/xml application/json application/javascript application/xml image/svg+xml;\n"
        }
        if n.gzipStatic { out += "    gzip_static on;\n" }
        // WebSocket upgrades for Node.js sites behind the proxy.
        out += "    map $http_upgrade $connection_upgrade {\n        default upgrade;\n        '' close;\n    }\n"
        if !trimmed(n.customConfig).isEmpty { out += "\n    # Custom configuration\n" + indent(n.customConfig) + "\n" }

        // Default server: answers unknown host names on the default port.
        var def = listen(n.httpPort, "default_server") + "server_name _;\nroot \(q(Self.defaultDocRoot));\nindex index.html;\n"
        if n.stubStatus { def += "location = /nginx_status {\n    stub_status;\n    allow 127.0.0.1;\n    deny all;\n}\n" }
        out += "\n    server {\n" + indent(def, 8) + "    }\n"

        for site in config.sites(for: .nginx) {
            out += "\n    # ── \(oneLine(site.name)) (\(site.hostname))\n"
            let httpPort = config.httpPort(site)
            if site.ssl.enabled && site.ssl.redirectHTTP {
                let sp = config.httpsPort(site)
                let block = listen(httpPort) + "server_name \(site.allHostnames.joined(separator: " "));\nreturn 301 https://$host\(sp == 443 ? "" : ":\(sp)")$request_uri;\n"
                out += "    server {\n" + indent(block, 8) + "    }\n"
            } else {
                out += "    server {\n" + indent(nginxServer(site, port: httpPort, ssl: false), 8) + "    }\n"
            }
            if site.ssl.enabled {
                out += "    server {\n" + indent(nginxServer(site, port: config.httpsPort(site), ssl: true), 8) + "    }\n"
            }
        }
        out += "}\n"
        return out
    }

    private func nginxServer(_ site: Website, port: Int, ssl: Bool) -> String {
        let o = site.nginx
        let logBase = Paths.siteLogs + "/" + site.slug + "-nginx" + (ssl ? "-ssl" : "")
        var s = listen(port, ssl ? "ssl" : "")
        if ssl && config.nginx.http2 { s += "http2 on;\n" }
        s += "server_name \(site.allHostnames.joined(separator: " "));\n"
        s += "root \(q(site.documentRoot));\n"
        let index = trimmed(o.directoryIndex).isEmpty
            ? (site.servedPHP.isEmpty ? "index.html index.htm" : "index.php index.html index.htm") : trimmed(o.directoryIndex)
        s += "index \(index);\n"
        s += "access_log \(q(logBase + "-access.log"));\nerror_log \(q(logBase + "-error.log"));\n"
        if ssl {
            let c = Self.certificatePaths(site)
            s += "ssl_certificate \(q(c.cert));\nssl_certificate_key \(q(c.key));\n"
        }
        let allows = o.allow.split(separator: "\n").map { trimmed(String($0)) }.filter { !$0.isEmpty }
        let denies = o.deny.split(separator: "\n").map { trimmed(String($0)) }.filter { !$0.isEmpty }
        for a in allows { s += "allow \(a);\n" }
        for d in denies { s += "deny \(d);\n" }
        if !allows.isEmpty && denies.isEmpty { s += "deny all;\n" }

        let tryFiles = trimmed(o.tryFiles).isEmpty
            ? (site.servedPHP.isEmpty ? "$uri $uri/ =404" : "$uri $uri/ /index.php?$query_string") : trimmed(o.tryFiles)
        var loc = site.isNode ? """
            proxy_pass http://127.0.0.1:\(site.node.port);
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 300s;

            """ : "try_files \(tryFiles);\n"
        if o.autoindex { loc += "autoindex on;\n" }
        if !trimmed(o.locationParams).isEmpty { loc += o.locationParams + "\n" }
        s += "\nlocation / {\n" + indent(loc) + "}\n"

        if !site.servedPHP.isEmpty {
            s += """

            location ~ [^/]\\.php(/|$) {
                fastcgi_split_path_info ^(.+?\\.php)(/.*)$;
                if (!-f $document_root$fastcgi_script_name) { return 404; }
                fastcgi_pass unix:\(Paths.phpSocket(site.servedPHP));
                fastcgi_index index.php;
                include \(q(nginxEtc + "/fastcgi_params"));
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_param PATH_INFO $fastcgi_path_info;
                fastcgi_param HTTPS \(ssl ? "on" : "off");
            }

            """
        }
        s += "\nlocation ~ /\\.(?!well-known) {\n    deny all;\n}\n"
        if !trimmed(o.serverParams).isEmpty { s += o.serverParams + "\n" }
        return s
    }

    // MARK: - PHP-FPM

    func phpFPMConfig(_ formula: String) -> String {
        let tag = Paths.phpTag(formula)
        return """
        ; Generated by Server. Do not edit: changes are overwritten.
        [global]
        pid = \(q(Paths.run + "/\(tag)-fpm.pid"))
        error_log = \(q(Paths.logs + "/\(tag)-fpm.log"))
        daemonize = yes

        [www]
        listen = \(Paths.phpSocket(formula))
        listen.mode = 0660
        pm = ondemand
        pm.max_children = 10
        pm.process_idle_timeout = 30s
        catch_workers_output = yes
        php_admin_flag[log_errors] = on
        php_admin_value[error_log] = \(q(Paths.logs + "/\(tag)-error.log"))

        """
    }
    static func phpPIDFile(_ formula: String) -> String { Paths.run + "/\(Paths.phpTag(formula))-fpm.pid" }

    // MARK: - MySQL

    func mysqlConfig() -> String {
        let m = config.mysql
        var out = """
        # Generated by Server. Do not edit: changes are overwritten.
        [mysqld]
        basedir=\(q(prefix + "/opt/" + m.formula))
        datadir=\(q(Paths.mysqlDataDir(m.formula)))
        socket=\(q(Paths.mysqlSocket))
        pid-file=\(q(Paths.run + "/mysql.pid"))
        log-error=\(q(Paths.logs + "/mysql_error.log"))
        port=\(m.port)
        bind-address=127.0.0.1
        mysqlx=OFF
        max_connections=\(m.maxConnections)
        innodb_buffer_pool_size=\(m.innodbBufferPoolSize)
        max_allowed_packet=\(m.maxAllowedPacket)
        character-set-server=\(m.characterSet)
        collation-server=\(m.collation)

        """
        if !trimmed(m.sqlMode).isEmpty { out += "sql_mode=\(q(trimmed(m.sqlMode)))\n" }
        if !trimmed(m.customConfig).isEmpty { out += "\n# Custom configuration\n\(m.customConfig)\n" }
        out += "\n[client]\nsocket=\(q(Paths.mysqlSocket))\nport=\(m.port)\n"
        return out
    }
    static var mysqlPIDFile: String { Paths.run + "/mysql.pid" }
}
