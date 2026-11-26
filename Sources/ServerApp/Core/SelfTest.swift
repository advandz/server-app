// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// `Server --self-test` exercises the real service code end to end on spare ports.
/// Run it with SERVER_APP_SUPPORT / SERVER_APP_RUN pointing at a scratch folder so it
/// never touches the real configuration.
@MainActor
enum SelfTest {
    static func run() async -> Bool {
        var ok = true
        func check(_ cond: Bool, _ msg: String) { print(cond ? "  ✓ \(msg)" : "  ✗ \(msg)"); if !cond { ok = false } }
        print("Support: \(Paths.support)\nRun: \(Paths.run)")

        let app = AppState()
        let brewOK = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/brew")
        check(brewOK, "Homebrew present")
        await app.brew.refreshInstalledForTest()

        // Settings safety: one broken entry doesn't empty the list, and the file is private.
        let good = #"{"id":"11111111-1111-1111-1111-111111111111","name":"ok","hostname":"ok.localhost","documentRoot":"/tmp/x"}"#
        let mixed = #"{"websites":[\#(good),{"name":5}]}"#
        let decoded = try? JSONDecoder().decode(AppConfig.self, from: Data(mixed.utf8))
        check(decoded?.websites.count == 1, "A broken website entry is skipped, the others are kept")
        app.update { $0.ftp.port = $0.ftp.port }
        let mode = (try? FileManager.default.attributesOfItem(atPath: Paths.configFile)[.posixPermissions] as? Int) ?? 0
        check(mode == 0o600, "The settings file is readable only by you")
        var local = AppConfig(); local.webAllowNetwork = false
        local.websites = [Website(name: "x", hostname: "x.localhost", documentRoot: "/tmp/x")]
        let gen = ConfigGenerator(config: local, prefix: "/opt/homebrew")
        check(gen.apacheConfig().contains("Listen 127.0.0.1:80") && !gen.apacheConfig().contains("\nListen 80\n"), "Apache can listen on this Mac only")
        check(gen.nginxConfig().contains("listen 127.0.0.1:8080 default_server;"), "Nginx can listen on this Mac only")
        check(FTPServer.arguments(FTPSettings()).contains("127.0.0.1,21"), "FTP is limited to this Mac by default")
        if ProcessInfo.processInfo.environment["SELFTEST_MAIL"] == "only" { return await runMail(app, check: check) }
        if ProcessInfo.processInfo.environment["SELFTEST_CACHE"] == "only" { return await runCache(app, check: check) }

        let root = Paths.support + "/sites"
        let a = root + "/alpha", n = root + "/beta", g = root + "/gamma", dl = root + "/delta"
        let nodeApp = "require('http').createServer((q, r) => r.end('node:' + process.version + ':' + (q.headers['x-forwarded-proto'] || '-'))).listen(process.env.PORT, '127.0.0.1');"
        for d in [g, dl] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            try? nodeApp.write(toFile: d + "/server.js", atomically: true, encoding: .utf8)
        }
        for d in [a, n] { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        try? "<?php echo 'alpha:' . PHP_VERSION . ':' . ($_SERVER['HTTPS'] ?? 'off');".write(toFile: a + "/index.php", atomically: true, encoding: .utf8)
        try? "<?php echo 'beta:' . PHP_VERSION;".write(toFile: n + "/index.php", atomically: true, encoding: .utf8)

        // An old PHP version from the community tap, when one is installed: serve a site with it too.
        let legacyFormula = PHPCatalog.formulae.reversed().first { PHPCatalog.needsTap($0) && app.brew.isInstalled($0) }
        let legacyRoot = root + "/legacy"
        if legacyFormula != nil {
            try? FileManager.default.createDirectory(atPath: legacyRoot, withIntermediateDirectories: true)
            try? "<?php echo 'legacy:' . PHP_VERSION;".write(toFile: legacyRoot + "/index.php", atomically: true, encoding: .utf8)
        }
        app.update { c in
            c.apache.httpPort = 18080; c.apache.httpsPort = 18443
            c.nginx.httpPort = 28080; c.nginx.httpsPort = 28443
            c.mysql.port = 13306
            c.mysql.formula = ProcessInfo.processInfo.environment["SELFTEST_MYSQL"] ?? "mysql@8.4"
            var alpha = Website(name: "Alpha", hostname: "alpha.localhost", documentRoot: a, server: .apache, phpFormula: "php")
            alpha.ssl.enabled = true
            alpha.aliases = "www.alpha.localhost"
            var beta = Website(name: "Beta", hostname: "beta.localhost", documentRoot: n, server: .nginx, phpFormula: "php")
            beta.ssl.enabled = true
            beta.ssl.redirectHTTP = true
            var gamma = Website(name: "Gamma", hostname: "gamma.localhost", documentRoot: g, server: .nginx, phpFormula: "")
            gamma.runtime = .node
            gamma.node = NodeSiteSettings(version: "", command: "node server.js", port: 13901)
            var delta = Website(name: "Delta", hostname: "delta.localhost", documentRoot: dl, server: .apache, phpFormula: "")
            delta.runtime = .node
            delta.node = NodeSiteSettings(version: NVM.installed().last ?? "", command: "node server.js", port: 13902)
            c.websites = [alpha, beta, gamma, delta]
            if let legacyFormula {
                c.websites.append(Website(name: "Legacy", hostname: "legacy.localhost", documentRoot: legacyRoot, server: .nginx, phpFormula: legacyFormula))
            }
        }
        app.applyTask?.cancel()

        print("Apache")
        await app.start(.apache)
        check(app.isRunning(.apache), "Apache running \(app.errors[.apache] ?? "")")
        check(await curl("http://127.0.0.1:18080/", host: "alpha.localhost").hasPrefix("alpha:"), "Apache serves PHP over HTTP")
        check(await curl("https://127.0.0.1:18443/", host: "alpha.localhost").contains(":on"), "Apache serves PHP over HTTPS")

        // Certificates: create, import, check, use for a website, delete.
        print("Certificates")
        let created = await app.createSelfSignedCertificate(name: "Test cert", names: "alpha.localhost *.test 127.0.0.1", days: 90)
        check(created == nil, "Self-signed certificate created \(created ?? "")")
        if let cert = app.config.certificates.first {
            let info = app.certificateInfo[cert.id]
            check(info?.names == ["alpha.localhost", "*.test", "127.0.0.1"], "Names are read back (\(info?.names.joined(separator: ", ") ?? "none"))")
            check(info?.covers("shop.test") == true && info?.covers("a.b.test") == false && info?.covers("other.localhost") == false, "Wildcard names cover one label only")
            check((info?.daysLeft ?? 0) >= 88 && info?.isSelfIssued == true && !(info?.fingerprint.isEmpty ?? true), "Validity, issuer and fingerprint are read")
            let files = app.certificateFiles(cert.id)
            let imported = await app.importCertificate(name: "Imported", certificatePath: files.cert, keyPath: files.key, chainPath: "")
            check(imported == nil && app.config.certificates.count == 2, "A certificate and key can be imported \(imported ?? "")")
            let other = await app.createSelfSignedCertificate(name: "Other", names: "other.test", days: 90)
            let otherFiles = other == nil ? app.certificateFiles(app.config.certificates.last!.id) : files
            let mismatch = await app.importCertificate(name: "Bad", certificatePath: files.cert, keyPath: otherFiles.key, chainPath: "")
            check(mismatch != nil && app.config.certificates.count == 3, "A key that doesn't match the certificate is refused")
            let bad = await app.createSelfSignedCertificate(name: "x", names: "not valid!", days: 90)
            check(bad != nil, "Invalid names are refused")
            // Serve alpha over HTTPS with the stored certificate.
            let siteID = app.config.websites[0].id
            app.update { c in c.websites[0].ssl.mode = .stored; c.websites[0].ssl.certificateID = cert.id }
            check(app.certificateUsers(cert.id) == [app.config.websites[0].name], "The certificate shows which website uses it")
            check(app.deleteCertificate(cert.id) != nil, "A certificate in use can't be deleted")
            app.applyTask?.cancel()
            await app.applyConfiguration()
            try? await Task.sleep(for: .seconds(2))
            let served = await Shell.run("/usr/bin/curl", ["-sk", "-m", "8", "--resolve", "alpha.localhost:18443:127.0.0.1", "-w", "%{ssl_verify_result}", "-o", "/dev/null", "https://alpha.localhost:18443/"])
            check(served.ok, "Apache serves HTTPS with the stored certificate (\(served.output))")
            let presented = await Shell.run("/bin/sh", ["-c", "echo | /usr/bin/openssl s_client -connect 127.0.0.1:18443 -servername alpha.localhost 2>/dev/null | /usr/bin/openssl x509 -noout -fingerprint -sha256"])
            check(presented.output.contains(info?.fingerprint ?? "?"), "…and it presents that exact certificate")
            app.update { c in c.websites[0].ssl.mode = .selfSigned; c.websites[0].ssl.certificateID = nil }
            _ = siteID
            check(app.deleteCertificate(cert.id) == nil && !FileManager.default.fileExists(atPath: files.cert), "Deleting removes the files")
            for c in app.config.certificates { _ = app.deleteCertificate(c.id) }
            check(app.config.certificates.isEmpty, "All stored certificates removed")
            app.applyTask?.cancel()
            await app.applyConfiguration()
        }

        print("Nginx")
        await app.start(.nginx)
        check(app.isRunning(.nginx), "Nginx running \(app.errors[.nginx] ?? "")")
        check(await curl("https://127.0.0.1:28443/", host: "beta.localhost").hasPrefix("beta:"), "Nginx serves PHP over HTTPS")
        check(await curl("http://127.0.0.1:28080/", host: "beta.localhost", statusOnly: true) == "301", "Nginx redirects HTTP to HTTPS")

        if let legacyFormula {
            let series = PHPCatalog.series(legacyFormula, version: nil) ?? "?"
            let answer = await curl("http://127.0.0.1:28080/", host: "legacy.localhost")
            check(answer.hasPrefix("legacy:\(series)."), "Nginx serves a site with PHP \(series) (\(answer))")
            check(PHPCatalog.isEndOfLife(legacyFormula, version: nil), "PHP \(series) is flagged end of life")
        } else {
            print("  (no old PHP version installed: legacy check skipped)")
        }

        print("Node.js websites")
        let defaultNode = await NVM.defaultVersion(prefix: app.brew.prefix) ?? "?"
        check(app.config.websites.filter(\.isNode).allSatisfy { app.isNodeAppRunning($0) },
              "Node apps running \(app.nodeErrors.values.joined(separator: "; "))")
        check(await curl("http://127.0.0.1:28080/", host: "gamma.localhost") == "node:\(defaultNode):http",
              "Nginx proxies to Node.js (default \(defaultNode))")
        let pinned = app.config.websites[3].node.version
        check(await curl("http://127.0.0.1:18080/", host: "delta.localhost") == "node:\(pinned):http",
              "Apache proxies to Node.js \(pinned)")
        app.update { $0.websites[2].node.port = 13903 }
        await app.applyConfiguration()
        check(await curl("http://127.0.0.1:28080/", host: "gamma.localhost").hasPrefix("node:"), "App restarted on its new port")

        print("Reload with a bad directive keeps the old config")
        app.update { $0.websites[0].apache.virtualHostParams = "ThisIsNotADirective on" }
        await app.applyConfiguration()
        check(app.errors[.apache]?.contains("Configuration error") == true, "Bad config rejected")
        check(app.isRunning(.apache), "Apache still running after bad edit")
        app.update { $0.websites[0].apache.virtualHostParams = "" }
        await app.applyConfiguration()
        check(app.errors[.apache] == nil, "Config error cleared after fix")

        print("MySQL (\(app.config.mysql.formula))")
        await app.start(.mysql)
        check(app.isRunning(.mysql), "MySQL running \(app.errors[.mysql] ?? "")")
        let err = await app.createDatabase(name: "alpha_db", for: app.config.websites[0].id)
        check(err == nil, "Database created \(err ?? "")")
        if let rec = app.config.databases.first {
            let r = await Shell.run(app.generator.mysqlBin("mysql"), ["-h127.0.0.1", "-P13306", "-u\(rec.user)", "-p\(rec.password)", "-e", "CREATE TABLE \(rec.name).t (id int); SELECT 1"])
            check(r.ok, "Site user can use its database over TCP")
            let d = await app.dropDatabase(rec)
            check(d == nil, "Database dropped")
        }

        // Root password: change it, reset it without knowing the old one, and remove it.
        func rootLogin(_ password: String) async -> Bool {
            let login = app.mysqlLogin(password: password)
            defer { login.cleanup() }
            let r = await Shell.run(app.generator.mysqlBin("mysql"), login.args + ["--socket=\(Paths.mysqlSocket)", "-uroot", "-N", "-B"], input: "SELECT 1")
            return r.ok
        }
        check(await rootLogin(""), "Root starts without a password")
        let changed = await app.changeMySQLRootPassword(to: "first pass'w\\ord")
        check(changed == nil, "Root password changed \(changed ?? "")")
        check(!(await rootLogin("")), "Root can't log in without the password any more")
        check(await rootLogin("first pass'w\\ord"), "Root logs in with the new password (quotes and backslashes kept)")
        check(app.mysqlRootPassword == "first pass'w\\ord", "Server saved the new password")
        let withPassword = await app.createDatabase(name: "beta_db", for: nil)
        check(withPassword == nil, "Server still creates databases with a root password \(withPassword ?? "")")
        if let rec = app.config.databases.first(where: { $0.name == "beta_db" }) { _ = await app.dropDatabase(rec) }
        // Lose the saved password, then recover with a reset.
        let formula = app.config.mysql.formula
        app.update { $0.mysqlRootPasswords[formula] = "wrong" }
        let denied = await app.changeMySQLRootPassword(to: "x")
        check(denied?.contains("Reset Password") == true, "A lost password is reported with a hint to reset")
        let reset = await app.resetMySQLRootPassword(to: "second-pass")
        check(reset == nil, "Root password reset without the old one \(reset ?? "")")
        check(app.isRunning(.mysql), "MySQL is running again after the reset")
        let newWorks = await rootLogin("second-pass"), oldWorks = await rootLogin("first pass'w\\ord")
        check(newWorks && !oldWorks, "Only the new password works after the reset")
        check(!FileManager.default.fileExists(atPath: Paths.run + "/mysql-login-"), "No password files are left behind")
        let removed = await app.changeMySQLRootPassword(to: "")
        let openAgain = await rootLogin("")
        check(removed == nil && app.mysqlRootPassword.isEmpty && openAgain, "Password removed")

        print("DNS (dnsmasq)")
        app.update { c in
            c.dns.port = 15353
            c.dns.domains = [DNSDomain(name: "test", address: "127.0.0.1")]
            c.dns.records = [DNSRecord(kind: .a, name: "app.example.test", value: "10.0.0.5"),
                             DNSRecord(kind: .cname, name: "www.devbox", value: "app.example.test")]
        }
        await app.start(.dns)
        check(app.isRunning(.dns), "DNS running \(app.errors[.dns] ?? "")")
        check(await DNSServer.lookUp("anything.test", port: 15353) == "127.0.0.1", "Wildcard domain answers")
        check(await DNSServer.lookUp("app.example.test", port: 15353) == "10.0.0.5", "A record answers")
        check(await DNSServer.lookUp("www.devbox", port: 15353).contains("10.0.0.5"), "CNAME answers")
        app.update { $0.dns.records[0].value = "10.0.0.6" }
        await app.applyDNS()
        check(await DNSServer.lookUp("app.example.test", port: 15353) == "10.0.0.6", "Changed record applied")

        // FTP runs as root, so starting it shows a password dialog: only when asked for.
        if ProcessInfo.processInfo.environment["SELFTEST_FTP"] == "1" {
        print("FTP (pure-ftpd, asks for an administrator password)")
        app.update { c in c.ftp.port = 2121; c.ftp.passiveFrom = 30100; c.ftp.passiveTo = 30109 }
        let home = Paths.support + "/ftp-home"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let addErr = await FTPServer.addUser("tester", password: "s3cret-pass", home: home, prefix: app.brew.prefix)
        check(addErr == nil, "FTP user added \(addErr ?? "")")
        check(await FTPServer.users(prefix: app.brew.prefix).map(\.name) == ["tester"], "FTP user listed")
        await app.start(.ftp)
        check(app.isRunning(.ftp), "FTP running \(app.errors[.ftp] ?? "")")
        let upload = Paths.support + "/upload.txt"
        try? "hello ftp".write(toFile: upload, atomically: true, encoding: .utf8)
        let put = await Shell.run("/usr/bin/curl", ["-s", "-T", upload, "--user", "tester:s3cret-pass", "ftp://127.0.0.1:2121/hello.txt"])
        check(put.ok && (try? String(contentsOfFile: home + "/hello.txt", encoding: .utf8)) == "hello ftp", "Upload lands in the user's folder")
        let get = await Shell.run("/usr/bin/curl", ["-s", "--user", "tester:s3cret-pass", "ftp://127.0.0.1:2121/hello.txt"])
        check(get.output == "hello ftp", "Download works")
        let bad = await Shell.run("/usr/bin/curl", ["-s", "--user", "tester:wrong", "ftp://127.0.0.1:2121/"])
        check(!bad.ok, "Wrong password refused")
        let pw = await FTPServer.setPassword("tester", password: "n3w-password", prefix: app.brew.prefix)
        let list = await Shell.run("/usr/bin/curl", ["-s", "--list-only", "--user", "tester:n3w-password", "ftp://127.0.0.1:2121/"])
        check(pw == nil && list.output.contains("hello.txt"), "Password change applies without restart")
        let del = await FTPServer.deleteUser("tester", prefix: app.brew.prefix)
        let remaining = await FTPServer.users(prefix: app.brew.prefix)
        check(del == nil && remaining.isEmpty, "FTP user removed")
        await app.stop(.ftp)
        check(!app.isRunning(.ftp), "FTP stopped")
        }

        if app.brew.isInstalled(RedisServer.formula) {
            print("Redis")
            app.update { c in c.redis.port = 16379; c.redis.password = "redis-test-pass"; c.redis.maxMemoryMB = 64; c.redis.allowNetwork = false }
            await app.start(.redis)
            check(app.isRunning(.redis), "Redis running \(app.errors[.redis] ?? "")")
            func redis(_ args: [String]) async -> String {
                await RedisServer.run(args, settings: app.config.redis, prefix: app.brew.prefix).output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            check(await redis(["PING"]) == "PONG", "Redis answers PING with the password")
            let anonymous = await Shell.run(RedisServer.cli(prefix: app.brew.prefix), ["-p", "16379", "PING"])
            check(anonymous.output.contains("NOAUTH") || anonymous.output.contains("Authentication"), "Redis refuses a client without the password")
            _ = await redis(["SET", "greeting", "hello world"])
            check(await redis(["GET", "greeting"]) == "hello world", "Values are stored and read back")
            let info = await RedisServer.info(settings: app.config.redis, prefix: app.brew.prefix)
            check(info?.version.isEmpty == false && info?.totalKeys == 1, "Statistics are read (\(info?.version ?? "?"), \(info?.totalKeys ?? -1) key)")
            let lan = await Task.detached { NetworkScanner.primaryIPv4() }.value
            if let lan {
                let r = await Shell.run(RedisServer.cli(prefix: app.brew.prefix), ["-h", lan, "-p", "16379", "--no-auth-warning", "PING"], env: ["REDISCLI_AUTH": "redis-test-pass"])
                check(!r.output.contains("PONG"), "Network access off: not reachable at \(lan)")
            }
            await app.stop(.redis)
            check(!app.isRunning(.redis), "Redis stopped")
            await app.start(.redis)
            check(await redis(["GET", "greeting"]) == "hello world", "Data survives a restart")
            app.update { $0.redis.allowNetwork = true; $0.redis.password = "" }
            await app.stop(.redis)
            await app.start(.redis)
            check(!app.isRunning(.redis) && app.errors[.redis]?.contains("password") == true, "Network access without a password is refused")
            app.update { $0.redis.allowNetwork = false; $0.redis.password = "redis-test-pass" }
            app.errors[.redis] = nil
            await app.start(.redis)
            _ = await redis(["FLUSHALL"])
            await app.stop(.redis)
        } else {
            print("Redis: skipped (not installed)")
        }

        print("Cloudflare addresses")
        func parsed(_ text: String) -> LocalAddress.Parsed? { if case .success(let p) = LocalAddress.parse(text) { return p }; return nil }
        check(parsed("localhost:3000")?.origin == "http://127.0.0.1:3000" && parsed("localhost:3000")?.hostHeader == "localhost", "localhost:3000 is accepted")
        check(parsed("https://myapp.localhost:8443")?.origin == "https://127.0.0.1:8443" && parsed("https://myapp.localhost:8443")?.insecureTLS == true,
              "A .localhost name over HTTPS keeps its name and accepts a self-signed certificate")
        check(parsed("http://127.0.0.1:8080")?.origin == "http://127.0.0.1:8080" && parsed("http://127.0.0.1:8080")?.hostHeader == nil, "An IP address needs no Host header")
        check(parsed("http://[::1]:3000")?.origin == "http://[::1]:3000", "IPv6 loopback is accepted")
        if let own = await Task.detached(operation: { NetworkScanner.primaryIPv4() }).value {
            check(parsed("http://\(own):8080") != nil, "This Mac's own network address is accepted")
        }
        check(parsed("http://example.com") == nil, "A public host is refused")
        check(parsed("http://8.8.8.8") == nil, "A public address is refused")
        check(parsed("http://192.168.1.1") == nil || NetworkScanner.interfaceAddresses().values.contains { $0.v4.contains { $0.address == "192.168.1.1" } },
              "Another device on the network is refused")
        check(parsed("http://localhost:3000/admin") == nil, "An address with a path is refused")
        check(parsed("ftp://localhost") == nil && parsed("") == nil, "Non-web and empty addresses are refused")

        print("AI web app")
        setenv("SERVER_AI_TEST_USERS", "alice:alice-pass-1,bob:bob-pass-2", 1)      // test accounts, on top of real sign-in
        app.update { c in c.ai.port = 18000; c.ai.allowNetwork = false; c.ai.apiKey = ""; c.ai.webChat = true }
        let base = "http://127.0.0.1:18000"
        let aliceJar = Paths.work + "/alice.jar", bobJar = Paths.work + "/bob.jar"
        /// curl returning (status code, body); `jar` keeps the session cookie.
        func http(_ path: String, jar: String? = nil, method: String = "GET", json: String? = nil, headers: [String] = [],
                  host: String = base) async -> (code: String, body: String) {
            var args = ["-s", "-m", "60", "-w", "\n%{http_code}", "-X", method]
            if let jar { args += ["-b", jar, "-c", jar] }
            if let json { args += ["-H", "Content-Type: application/json", "-d", json] }
            for h in headers { args += ["-H", h] }
            let r = await Shell.run("/usr/bin/curl", args + [host + path])
            let lines = r.output.split(separator: "\n", omittingEmptySubsequences: false)
            return (lines.last.map(String.init) ?? "", lines.dropLast().joined(separator: "\n"))
        }
        await app.start(.ai)
        check(app.isRunning(.ai), "AI server running \(app.errors[.ai] ?? "")")
        let page = await http("/")
        check(page.code == "200" && page.body.contains("<title>Chat"), "Web app is served at /")
        let script = await http("/app.js")
        check(script.code == "200" && !script.body.contains("innerHTML = m.content"), "Scripts are served separately")
        check(await http("/api/chats").code == "401", "Chats need sign-in")
        check(await http("/api/login", method: "POST", json: #"{"username":"alice","password":"wrong"}"#).code == "401", "Wrong password refused")
        let real = await http("/api/login", method: "POST", json: "{\"username\":\"\(NSUserName())\",\"password\":\"definitely-wrong-password\"}")
        check(real.code == "401", "Real Mac account with a wrong password refused (Open Directory)")
        let signIn = await http("/api/login", jar: aliceJar, method: "POST", json: #"{"username":"alice","password":"alice-pass-1"}"#)
        check(signIn.code == "200", "Signed in with an account")
        check((await http("/api/me", jar: aliceJar)).body.contains("alice"), "Session identifies the user")
        let chatID = (await http("/api/chats", jar: aliceJar, method: "POST")).body
            .components(separatedBy: "\"id\":\"").dropFirst().first?.components(separatedBy: "\"").first ?? ""
        check(!chatID.isEmpty, "Chat created")
        let answer = await http("/api/chats/\(chatID)/messages", jar: aliceJar, method: "POST", json: #"{"content":"Reply with exactly one word: pong"}"#)
        check(answer.code == "200" && answer.body.lowercased().contains("pong"), "The on-device model answers a chat message")
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: AIServer.chatsDir + "/alice")) ?? []
        check(saved.contains("\(chatID).json"), "Chat saved under the user's own folder")
        _ = await http("/api/login", jar: bobJar, method: "POST", json: #"{"username":"bob","password":"bob-pass-2"}"#)
        check((await http("/api/chats", jar: bobJar)).body == #"{"chats":[]}"#, "Another user sees none of those chats")
        check(await http("/api/chats/\(chatID)", jar: bobJar).code == "404", "Another user can't open the chat")
        check(await http("/api/chats", jar: aliceJar, method: "POST", headers: ["Origin: http://evil.example"]).code == "403", "Cross-site request refused")
        let lan = await Task.detached { NetworkScanner.primaryIPv4() }.value
        if let lan {
            let r = await Shell.run("/usr/bin/curl", ["-s", "-m", "4", "-o", "/dev/null", "http://\(lan):18000/"])
            check(!r.ok, "Network access off: not reachable at \(lan)")
        }
        app.update { $0.ai.apiKey = "sk-selftest" }
        await app.restart(.ai)
        check(await http("/").code == "200", "With an API key set, the web app still loads")
        check(await http("/v1/models").code == "401", "The API still needs the key")
        check(await http("/v1/models", headers: ["Authorization: Bearer sk-selftest"]).code == "200", "The key works")
        check(await http("/api/chats", jar: aliceJar).code == "401", "Restarting signs everyone out")
        _ = await http("/api/chats/\(chatID)", jar: aliceJar, method: "DELETE")

        // HTTPS: the chat and API also answer over TLS, with a generated or a stored certificate.
        print("AI HTTPS")
        app.update { c in c.ai.httpsEnabled = true; c.ai.httpsPort = 19443; c.ai.certificateID = nil }
        await app.restart(.ai)
        check(app.isRunning(.ai), "AI server running with HTTPS \(app.errors[.ai] ?? "")")
        let secure = "https://127.0.0.1:19443"
        let tlsPage = await Shell.run("/usr/bin/curl", ["-sk", "-m", "20", "-o", "/dev/null", "-w", "%{http_code}", secure + "/"])
        check(tlsPage.output == "200", "The chat loads over HTTPS (\(tlsPage.output))")
        let strict = await Shell.run("/usr/bin/curl", ["-s", "-m", "20", "-o", "/dev/null", "-w", "%{http_code}", secure + "/"])
        check(!strict.ok, "A browser that doesn't trust the generated certificate would warn about it")
        let tlsLogin = await Shell.run("/usr/bin/curl", ["-sk", "-m", "30", "-D", "-", "-o", "/dev/null", "-c", aliceJar, "-X", "POST", "-H", "Content-Type: application/json",
                                                         "-d", #"{"username":"alice","password":"alice-pass-1"}"#, secure + "/api/login"])
        check(tlsLogin.output.contains("200") && tlsLogin.output.contains("Secure"), "Signing in over HTTPS sets a Secure cookie")
        let tlsMe = await Shell.run("/usr/bin/curl", ["-sk", "-m", "20", "-b", aliceJar, secure + "/api/me"])
        check(tlsMe.output.contains("alice"), "The session works over HTTPS")
        let tlsAPI = await Shell.run("/usr/bin/curl", ["-sk", "-m", "20", "-H", "Authorization: Bearer sk-selftest", "-o", "/dev/null", "-w", "%{http_code}", secure + "/v1/models"])
        check(tlsAPI.output == "200", "The API answers over HTTPS with its key")
        check(await http("/").code == "200", "Plain HTTP still works")
        // A stored certificate that this client can verify.
        let certErr = await app.createSelfSignedCertificate(name: "AI cert", names: "localhost 127.0.0.1", days: 30)
        check(certErr == nil, "Certificate for the chat created \(certErr ?? "")")
        if let cert = app.config.certificates.last {
            app.update { $0.ai.certificateID = cert.id }
            await app.restart(.ai)
            let files = app.certificateFiles(cert.id)
            let verified = await Shell.run("/usr/bin/curl", ["-s", "-m", "20", "--cacert", files.cert, "-o", "/dev/null", "-w", "%{http_code}", "https://localhost:19443/"])
            check(verified.output == "200", "A stored certificate is presented and verifies (\(verified.output))")
            check(app.deleteCertificate(cert.id) != nil, "It can't be deleted while the chat uses it")
            app.update { $0.ai.certificateID = nil; $0.ai.httpsEnabled = false }
            await app.restart(.ai)
            check(!FileManager.default.fileExists(atPath: AIServer.tlsBundle), "No key bundle is left on disk")
            let gone = await Shell.run("/usr/bin/curl", ["-sk", "-m", "5", "-o", "/dev/null", secure + "/"])
            check(!gone.ok, "HTTPS is off again")
            _ = app.deleteCertificate(cert.id)
        }
        // Real Cloudflare quick tunnels (public for a few seconds): only when asked for.
        if ProcessInfo.processInfo.environment["SELFTEST_CLOUDFLARE"] == "1" {
            print("Cloudflare quick tunnels (public, short-lived)")
            func waitForURL(_ key: String) async -> String? {
                for _ in 0..<120 {
                    if let u = app.tunnels.state(key).url { return u }
                    if case .failed = app.tunnels.state(key) { return nil }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                return nil
            }
            /// New trycloudflare.com names take a moment to resolve and connect.
            func reachable(_ url: String, path: String = "/", headers: [String] = []) async -> (code: String, body: String) {
                var last = (code: "", body: "")
                for _ in 0..<30 {
                    last = await http(path, headers: headers, host: url)
                    if last.code == "200" || last.code == "401" || last.code == "403" { return last }
                    try? await Task.sleep(for: .seconds(2))
                }
                return last
            }

            // 1. A website: the tunnel reaches a name-based virtual host through its Host header.
            let site = app.config.websites[0]
            let siteSpec = app.tunnelSpec(for: site)
            check(siteSpec.hostHeader == "alpha.localhost" && siteSpec.origin.hasSuffix(":18080"), "Website tunnel targets its web server and host name")
            let started = await app.shareOnline(siteSpec)
            check(started == nil, "Website tunnel started \(started ?? "")")
            let siteURL = await waitForURL(siteSpec.key)
            check(siteURL?.hasSuffix(".trycloudflare.com") == true, "A public address was issued (\(siteURL ?? app.tunnels.state(siteSpec.key).description))")
            if let siteURL {
                let page = await reachable(siteURL)
                check(page.code == "200" && page.body.hasPrefix("alpha:"), "The website answers on the internet (\(page.body.prefix(20)))")
                app.tunnels.stop(siteSpec.key)
                try? await Task.sleep(for: .seconds(2))
                check(app.tunnels.state(siteSpec.key) == .stopped, "Stopping the tunnel works")
                let gone = await http("/", host: siteURL)
                check(gone.code != "200", "The address stops working after sharing ends (\(gone.code))")
            }

            // 2. The AI chat: HTTPS cookie, API closed without a key, sign-in limited per visitor.
            let aiSpec = app.aiTunnelSpec
            check(aiSpec.hostHeader == nil, "Chat tunnel keeps the original Host header")
            _ = await app.shareOnline(aiSpec)
            if let aiURL = await waitForURL(aiSpec.key) {
                let chatPage = await reachable(aiURL)
                check(chatPage.code == "200" && chatPage.body.contains("<title>Chat"), "The chat page loads over the tunnel")
                check((await http("/api/chats", host: aiURL)).code == "401", "Chats still need sign-in over the tunnel")
                check((await http("/v1/models", host: aiURL)).code == "401", "The API needs its key over the tunnel")
                check((await http("/v1/models", headers: ["Authorization: Bearer sk-selftest"], host: aiURL)).code == "200", "The API works with its key")
                app.update { $0.ai.apiKey = "" }
                await app.restart(.ai)
                let open = await reachable(aiURL, path: "/v1/models")
                check(open.code == "403", "With no API key set, the API is refused over the tunnel (\(open.code))")
                check((await http("/v1/models")).code == "200", "…but still works locally")
                let login = await Shell.run("/usr/bin/curl", ["-s", "-m", "30", "-D", "-", "-o", "/dev/null", "-X", "POST", "-H", "Content-Type: application/json",
                                                              "-d", #"{"username":"alice","password":"alice-pass-1"}"#, aiURL + "/api/login"])
                check(login.output.contains("200") && login.output.lowercased().contains("set-cookie") && login.output.contains("Secure"),
                      "Sign-in over the tunnel sets a Secure cookie")
                var codes: [String] = []
                for _ in 0..<6 {
                    codes.append((await http("/api/login", method: "POST", json: #"{"username":"carol","password":"x"}"#, host: aiURL)).code)
                }
                check(codes.last == "429", "Repeated wrong passwords over the tunnel get blocked (\(codes.joined(separator: " ")))")
                app.tunnels.stop(aiSpec.key)
                try? await Task.sleep(for: .seconds(2))
                check(app.tunnels.state(aiSpec.key) == .stopped, "Chat tunnel stopped")
            } else {
                check(false, "Chat tunnel got an address (\(app.tunnels.state(aiSpec.key).description))")
            }
            check(app.tunnels.activeKeys.isEmpty, "No tunnels left running")
        }

        // Reaching it over the network can pop up a firewall question, so only when asked for.
        if ProcessInfo.processInfo.environment["SELFTEST_AI_NETWORK"] == "1", let lan {
            app.update { $0.ai.allowNetwork = true }
            await app.restart(.ai)
            check((await http("/api/chats", host: "http://\(lan):18000")).code == "401", "Network access on: reachable at \(lan)")
        }
        await app.stop(.ai)
        unsetenv("SERVER_AI_TEST_USERS")
        try? FileManager.default.removeItem(atPath: aliceJar); try? FileManager.default.removeItem(atPath: bobJar)

        print("Stop")
        await app.stopAll()
        check(ServiceKind.allCases.allSatisfy { !app.isRunning($0) }, "All stopped")
        check(app.phpRunning.isEmpty, "PHP-FPM stopped")
        check(app.config.websites.filter(\.isNode).allSatisfy { !app.isNodeAppRunning($0) }, "Node apps stopped")
        print(ok ? "SELF-TEST PASSED" : "SELF-TEST FAILED")
        return ok
    }


    /// Mail end to end: Postfix and Dovecot (two administrator prompts), then the Mailpit sandbox.
    private static func runMail(_ app: AppState, check: (Bool, String) -> Void) async -> Bool {
        var failed = false
        func check(_ cond: Bool, _ msg: String) { if !cond { failed = true }; print(cond ? "  ✓ \(msg)" : "  ✗ \(msg)") }
        func py(_ code: String) async -> String {
            let r = await Shell.run("/usr/bin/python3", ["-c", code])
            print("    py → \(r.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
            return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func send(_ port: Int, to: String, subject: String, login: (String, String)? = nil, tls: Bool = false) async -> String {
            let auth = login.map { "s.login('\($0.0)', '\($0.1)')" } ?? "pass"
            let starttls = tls ? "import ssl; c=ssl.create_default_context(); c.check_hostname=False; c.verify_mode=ssl.CERT_NONE; s.starttls(context=c)" : "pass"
            return await py("""
            import smtplib
            from email.message import EmailMessage
            m = EmailMessage(); m['From'] = 'sender@example.org'; m['To'] = '\(to)'; m['Subject'] = '\(subject)'; m.set_content('body')
            try:
                s = smtplib.SMTP('127.0.0.1', \(port), timeout=15)
                \(starttls)
                \(auth)
                s.send_message(m); s.quit(); print('sent')
            except Exception as e:
                print('error', e)
            """)
        }
        func imapCount(_ port: Int, user: String, password: String) async -> String {
            await py("""
            import imaplib
            try:
                m = imaplib.IMAP4('127.0.0.1', \(port)); m.login('\(user)', '\(password)')
                t, d = m.select('INBOX'); t2, ids = m.search(None, 'ALL'); print('count', len(ids[0].split()))
                subs = []
                for i in ids[0].split():
                    t3, data = m.fetch(i, '(BODY[HEADER.FIELDS (SUBJECT)])'); subs.append(data[0][1].decode().strip())
                print(subs); m.logout()
            except Exception as e:
                print('error', e)
            """)
        }
        func waitFor(_ what: String, seconds: Double = 25, _ cond: () async -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(500)) }
            return false
        }

        print("Mail (Postfix + Dovecot, asks for an administrator password)")
        app.update { c in
            c.mail.hostName = "mail.test.dev"; c.mail.smtpPort = 2525; c.mail.submissionPort = 2587; c.mail.smtpsPort = 2465
            c.mail.imapPort = 2143; c.mail.imapsPort = 2993; c.mail.sandbox = false; c.mail.requireEncryption = false
            c.mail.sandboxWebPort = 18025
        }
        check(await app.addMailDomain("test.dev") == nil, "Domain added")
        check(await app.addMailAccount(user: "bob", domain: "test.dev", password: "bob-secret-1") == nil, "Account added")
        check(await app.addMailAlias(source: "info@test.dev", destination: "bob@test.dev") == nil, "Alias added")
        check(await app.addMailAlias(source: "@test.dev", destination: "bob@test.dev") == nil, "Catch-all added")
        await app.start(.mail)
        check(app.isRunning(.mail), "Mail running \(app.errors[.mail] ?? "")")
        check(app.mailPostfixRunning, "Postfix running")
        let imapUp = await waitFor("imap") { await py("import socket; s=socket.create_connection(('127.0.0.1',2143),3); print(s.recv(100).decode()[:20])").hasPrefix("* OK") }
        check(imapUp, "IMAP answers on its port")
        let smtpUp = await waitFor("smtp") { await py("import socket; s=socket.create_connection(('127.0.0.1',2525),3); print(s.recv(100).decode()[:20])").hasPrefix("220") }
        check(smtpUp, "SMTP answers on its port")

        check(await send(2525, to: "bob@test.dev", subject: "direct") == "sent", "SMTP accepts mail for a mailbox")
        check(await send(2525, to: "info@test.dev", subject: "via-alias") == "sent", "SMTP accepts mail for an alias")
        check(await send(2525, to: "nobody@test.dev", subject: "via-catchall") == "sent", "SMTP accepts mail for the catch-all")
        let arrived = await waitFor("delivery") { await imapCount(2143, user: "bob@test.dev", password: "bob-secret-1").contains("via-catchall") }
        let box = await imapCount(2143, user: "bob@test.dev", password: "bob-secret-1")
        check(arrived, "IMAP shows the delivered messages")
        check(box.contains("direct") && box.contains("via-alias") && box.contains("via-catchall"), "Mailbox holds direct, alias and catch-all mail")
        check((await imapCount(2143, user: "bob@test.dev", password: "wrong")).hasPrefix("error"), "IMAP refuses a wrong password")
        let sub = await send(2587, to: "bob@test.dev", subject: "submitted", login: ("bob@test.dev", "bob-secret-1"), tls: true)
        check(sub == "sent", "Submission accepts an authenticated, encrypted client (\(sub.prefix(80)))")
        let subBad = await send(2587, to: "bob@test.dev", subject: "bad", login: ("bob@test.dev", "nope"), tls: true)
        check(subBad.hasPrefix("error"), "Submission refuses a wrong password")
        let subOpen = await send(2587, to: "bob@test.dev", subject: "plain")
        check(subOpen.hasPrefix("error"), "Submission refuses a client that doesn't sign in")
        check(await app.changeMailPassword(app.config.mailAccounts[0].id, to: "bob-secret-2") == nil, "Password changed")
        let changed = await imapCount(2143, user: "bob@test.dev", password: "bob-secret-2")
        check(changed.contains("count"), "New password works without a restart (\(changed.prefix(40)))")
        check((await imapCount(2143, user: "bob@test.dev", password: "bob-secret-1")).hasPrefix("error"), "Old password stops working")
        await app.stop(.mail)
        check(!app.isRunning(.mail) && !app.mailPostfixRunning, "Mail stopped \(app.errors[.mail] ?? "")")

        print("Mail sandbox (Mailpit)")
        app.update { $0.mail.sandbox = true }
        await app.start(.mail)
        check(app.mailSandboxRunning && app.isRunning(.mail), "Sandbox running \(app.errors[.mail] ?? "")")
        check(!app.mailPostfixRunning, "Postfix stays off in sandbox mode")
        check(await send(2525, to: "anyone@anywhere.example", subject: "caught") == "sent", "Sandbox accepts mail for any address on the SMTP port")
        check(await send(2525, to: "x@y.example", subject: "caught2", login: ("any", "thing")) == "sent", "Sandbox accepts any sign-in")
        let inbox = await py("import urllib.request, json; d = json.load(urllib.request.urlopen('http://127.0.0.1:18025/api/v1/messages')); print(d['total'], sorted(m['Subject'] for m in d['messages']))")
        check(inbox.hasPrefix("2") && inbox.contains("caught"), "Mailpit's inbox holds the messages")
        check((await imapCount(2143, user: "bob@test.dev", password: "bob-secret-2")).contains("count"), "IMAP still works in sandbox mode")
        await app.stop(.mail)
        check(!app.isRunning(.mail) && !app.mailSandboxRunning, "Sandbox stopped \(app.errors[.mail] ?? "")")
        print(failed ? "MAIL TEST FAILED" : "MAIL TEST PASSED")
        return !failed
    }

    /// Object cache (memcached): start, store and read back, statistics, flush, restart, stop.
    private static func runCache(_ app: AppState, check: (Bool, String) -> Void) async -> Bool {
        var failed = false
        func check(_ cond: Bool, _ msg: String) { if !cond { failed = true }; print(cond ? "  ✓ \(msg)" : "  ✗ \(msg)") }
        print("Object Caching (memcached)")
        app.update { $0.memcached.port = 21211; $0.memcached.memoryMB = 64; $0.memcached.logLevel = 2 }
        await app.start(.memcached)
        check(app.isRunning(.memcached), "Object cache running \(app.errors[.memcached] ?? "")")
        let port = 21211
        let set = await MemcachedServer.talk("set greeting 0 0 5\r\nhello", port: port) ?? ""
        check(set.contains("STORED"), "A value is stored")
        let get = await MemcachedServer.talk("get greeting", port: port) ?? ""
        check(get.contains("VALUE greeting 0 5") && get.contains("hello"), "…and read back")
        let st = await MemcachedServer.stats(port: port)
        check(st?.items == 1 && st?.limit == 64 * 1_048_576 && st?.hits == 1, "Statistics are read (\(st?.version ?? "?"), \(st?.items ?? -1) item, limit \(st?.limit ?? -1))")
        let lan = await Task.detached { NetworkScanner.primaryIPv4() }.value
        if let lan {
            let outside = await Shell.run("/usr/bin/nc", ["-z", "-w", "2", lan, String(port)])
            check(!outside.ok, "Not reachable from the network by default")
        }
        check(await MemcachedServer.flush(port: port), "Flush succeeds")
        let after = await MemcachedServer.talk("get greeting", port: port) ?? ""
        check(!after.contains("hello"), "The flushed value is gone")
        check((try? String(contentsOfFile: MemcachedServer.logFile, encoding: .utf8))?.isEmpty == false, "The log records commands")
        let clash = await Shell.run("/bin/sh", ["-c", "echo | /usr/bin/nc -w1 127.0.0.1 \(port) >/dev/null && echo up"])
        check(clash.output.contains("up"), "Port answers")
        app.update { $0.memcached.port = 21212; $0.memcached.allowNetwork = true }
        await app.restart(.memcached)
        let restarted = await MemcachedServer.stats(port: 21212)
        check(app.isRunning(.memcached) && restarted != nil, "Restart applies the new port \(app.errors[.memcached] ?? "")")
        if let lan {
            let outside = await Shell.run("/usr/bin/nc", ["-z", "-w", "2", lan, "21212"])
            check(outside.ok, "Reachable from the network when allowed")
        }
        await app.stop(.memcached)
        check(!app.isRunning(.memcached), "Object cache stopped")
        let leftover = await MemcachedServer.stats(port: 21212)
        check(leftover == nil, "Nothing listens after stopping")
        print(failed ? "CACHE TEST FAILED" : "CACHE TEST PASSED")
        return !failed
    }

    private static func curl(_ url: String, host: String, statusOnly: Bool = false) async -> String {
        let u = URL(string: url)!
        var args = ["-sk", "--max-time", "5", "--resolve", "\(host):\(u.port!):127.0.0.1",
                    url.replacingOccurrences(of: "127.0.0.1", with: host)]
        if statusOnly { args = ["-o", "/dev/null", "-w", "%{http_code}"] + args }
        let r = await Shell.run("/usr/bin/curl", args)
        print("    \(url) [\(host)] → \(r.output.prefix(80))")
        return r.output
    }
}

extension Homebrew {
    func refreshInstalledForTest() async {
        if brewPath == nil {
            await bootstrapDetectOnly()
        }
        await refreshInstalled()
    }
}
