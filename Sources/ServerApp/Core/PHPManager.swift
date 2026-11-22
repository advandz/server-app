// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// Per-version PHP management on top of Homebrew: settings, PECL extensions, the default CLI
/// version and Composer. Settings Server manages live in one file in the version's conf.d
/// folder (zz-server.ini), so php.ini itself is only touched to turn PECL lines off.
enum PHPManager {
    struct Info: Sendable {
        var version = ""
        var iniFile = ""
        var scanDir = ""
        var extensionDir = ""
        var loaded: Set<String> = []            // lowercased extension names
        var values: [String: String] = [:]      // effective ini values (CLI)
        var sharedObjects: Set<String> = []     // *.so files in the extension dir
        var errorLevelValues: [String: String] = [:]   // "E_ALL" → "30719" for this version

        /// The error_reporting value as one of the named levels, when it matches one.
        var errorReportingName: String? {
            errorLevelValues.first { $0.value == values["error_reporting"] }?.key
        }
    }

    struct Setting: Identifiable {
        enum Kind { case text, bool, choice([String]) }
        var id: String { key }
        let key: String
        let title: String
        let kind: Kind
    }

    static let settings: [Setting] = [
        Setting(key: "memory_limit", title: "Memory Limit", kind: .text),
        Setting(key: "upload_max_filesize", title: "Max Upload Size", kind: .text),
        Setting(key: "post_max_size", title: "Max POST Size", kind: .text),
        Setting(key: "max_execution_time", title: "Max Execution Time", kind: .text),
        Setting(key: "max_input_time", title: "Max Input Time", kind: .text),
        Setting(key: "max_input_vars", title: "Max Input Vars", kind: .text),
        Setting(key: "date.timezone", title: "Time Zone", kind: .text),
        Setting(key: "display_errors", title: "Display Errors", kind: .bool),
        Setting(key: "error_reporting", title: "Error Reporting",
                kind: .choice(errorLevels)),
        Setting(key: "short_open_tag", title: "Short Open Tags", kind: .bool),
        Setting(key: "opcache.enable", title: "OPcache", kind: .bool),
        Setting(key: "opcache.validate_timestamps", title: "OPcache Checks for Changes", kind: .bool),
    ]

    static let errorLevels = ["E_ALL", "E_ALL & ~E_DEPRECATED", "E_ALL & ~E_NOTICE & ~E_DEPRECATED", "E_ERROR | E_WARNING | E_PARSE"]

    struct PECLExtension: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let title: String
        var zend = false
        var brewDeps: [String] = []
    }

    static let catalog: [PECLExtension] = [
        PECLExtension(name: "xdebug", title: "Xdebug (debugger and profiler)", zend: true),
        PECLExtension(name: "redis", title: "Redis client"),
        PECLExtension(name: "apcu", title: "APCu (in-memory cache)"),
        PECLExtension(name: "imagick", title: "Imagick (ImageMagick)", brewDeps: ["imagemagick"]),
        PECLExtension(name: "mongodb", title: "MongoDB driver"),
        PECLExtension(name: "memcached", title: "Memcached client", brewDeps: ["libmemcached", "zlib"]),
        PECLExtension(name: "igbinary", title: "igbinary (fast serializer)"),
        PECLExtension(name: "pcov", title: "PCOV (code coverage)"),
        PECLExtension(name: "yaml", title: "YAML", brewDeps: ["libyaml"]),
    ]

    static func php(_ formula: String, prefix: String) -> String { prefix + "/opt/\(formula)/bin/php" }
    static func pecl(_ formula: String, prefix: String) -> String { prefix + "/opt/\(formula)/bin/pecl" }

    static func info(_ formula: String, prefix: String) async -> Info {
        let keys = settings.map(\.key)
        let code = """
        echo json_encode([
          'version' => PHP_VERSION,
          'ini' => php_ini_loaded_file() ?: '',
          'scan' => PHP_CONFIG_FILE_SCAN_DIR,
          'extdir' => ini_get('extension_dir'),
          'loaded' => array_merge(get_loaded_extensions(), get_loaded_extensions(true)),
          'values' => array_map(fn($k) => (string) ini_get($k), array_combine(\(phpArray(keys)), \(phpArray(keys)))),
          'levels' => [\(errorLevels.map { "'\($0)' => (string)(\($0))" }.joined(separator: ", "))],
        ]);
        """
        let r = await Shell.run(php(formula, prefix: prefix), ["-r", code])
        var info = Info()
        guard let start = r.output.firstIndex(of: "{"),
              let data = String(r.output[start...]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return info }
        info.version = o["version"] as? String ?? ""
        info.iniFile = o["ini"] as? String ?? ""
        info.scanDir = o["scan"] as? String ?? ""
        info.extensionDir = o["extdir"] as? String ?? ""
        info.loaded = Set(((o["loaded"] as? [String]) ?? []).map { $0.lowercased() })
        info.values = (o["values"] as? [String: String]) ?? [:]
        info.errorLevelValues = (o["levels"] as? [String: String]) ?? [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: info.extensionDir)) ?? []
        info.sharedObjects = Set(files.filter { $0.hasSuffix(".so") }.map { String($0.dropLast(3)) })
        return info
    }

    private static func phpArray(_ items: [String]) -> String { "[" + items.map { "'\($0)'" }.joined(separator: ",") + "]" }

    // MARK: Settings (conf.d/zz-server.ini)

    static func overridesFile(_ info: Info) -> String { info.scanDir + "/zz-server.ini" }

    static func readOverrides(_ info: Info) -> [String: String] {
        guard let text = try? String(contentsOfFile: overridesFile(info), encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix(";") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { out[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return out
    }

    static func writeOverrides(_ values: [String: String], _ info: Info) throws {
        var text = "; Managed by Server. Edit these settings on the PHP page.\n"
        for s in settings {
            guard let v = values[s.key], !v.isEmpty else { continue }
            let needsQuotes = v.contains(" ") || v.contains("/") || v.contains("&") || v.contains("|")
            text += "\(s.key) = \(needsQuotes ? "\"\(v)\"" : v)\n"
        }
        try FileManager.default.createDirectory(atPath: info.scanDir, withIntermediateDirectories: true)
        try text.write(toFile: overridesFile(info), atomically: true, encoding: .utf8)
    }

    // MARK: Extensions

    static func iniFile(for ext: PECLExtension, _ info: Info) -> String { info.scanDir + "/ext-\(ext.name).ini" }

    static func isEnabled(_ ext: PECLExtension, _ info: Info) -> Bool {
        info.loaded.contains(ext.name) || (ext.name == "xdebug" && info.loaded.contains("xdebug"))
    }

    /// Loads the extension through its own conf.d file.
    static func enable(_ ext: PECLExtension, _ info: Info) throws {
        try commentOutPHPIni(ext, info)        // avoid loading it twice
        let directive = ext.zend ? "zend_extension" : "extension"
        try "; Managed by Server\n\(directive)=\"\(ext.name).so\"\n"
            .write(toFile: iniFile(for: ext, info), atomically: true, encoding: .utf8)
    }

    static func disable(_ ext: PECLExtension, _ info: Info) throws {
        try? FileManager.default.removeItem(atPath: iniFile(for: ext, info))
        try commentOutPHPIni(ext, info)
    }

    /// `pecl install` adds `extension="name.so"` to php.ini; comment such lines out (php.ini is
    /// backed up once first).
    private static func commentOutPHPIni(_ ext: PECLExtension, _ info: Info) throws {
        guard !info.iniFile.isEmpty, let text = try? String(contentsOfFile: info.iniFile, encoding: .utf8) else { return }
        let pattern = #"^\s*(zend_)?extension\s*=\s*"?([^"\s]*/)?"# + NSRegularExpression.escapedPattern(for: ext.name) + #"(\.so)?"?\s*$"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return }
        var changed = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard rx.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil else { return line }
            changed = true
            return ";" + line
        }
        guard changed else { return }
        let backup = info.iniFile + ".server-backup"
        if !FileManager.default.fileExists(atPath: backup) { try? text.write(toFile: backup, atomically: true, encoding: .utf8) }
        try lines.joined(separator: "\n").write(toFile: info.iniFile, atomically: true, encoding: .utf8)
    }

    /// Builds and installs a PECL extension for one PHP version, then turns it on.
    static func install(_ ext: PECLExtension, formula: String, prefix: String,
                        onLine: @escaping @Sendable (String) -> Void) async -> String? {
        // pecl asks questions for some extensions; empty answers accept the defaults.
        let r = await Shell.run(pecl(formula, prefix: prefix), ["install", ext.name], input: String(repeating: "\n", count: 20),
                                onLine: onLine)
        let info = await info(formula, prefix: prefix)
        guard info.sharedObjects.contains(ext.name) else {
            return r.output.split(separator: "\n").suffix(12).joined(separator: "\n")
        }
        do { try enable(ext, info) } catch { return error.localizedDescription }
        return nil
    }

    static func uninstall(_ ext: PECLExtension, formula: String, prefix: String) async -> String? {
        let info = await info(formula, prefix: prefix)
        try? disable(ext, info)
        let r = await Shell.run(pecl(formula, prefix: prefix), ["uninstall", ext.name])
        return r.ok ? nil : r.output
    }

    // MARK: Default CLI PHP

    /// The formula Homebrew has linked as `php` on the PATH (e.g. "php" or "php@8.4").
    static func linkedFormula(prefix: String) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix + "/bin/php") else { return nil }
        let parts = target.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "Cellar"), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }
}

/// Composer, installed and upgraded with Homebrew. It runs with the default CLI PHP.
enum Composer {
    static let formula = "composer"
    static func binary(prefix: String) -> String { prefix + "/bin/composer" }

    struct Status: Sendable {
        var version: String?
        var php: String?
        var globalDir: String?
    }

    static func status(prefix: String) async -> Status {
        let bin = binary(prefix: prefix)
        guard FileManager.default.isExecutableFile(atPath: bin) else { return Status() }
        let env = ["COMPOSER_NO_INTERACTION": "1", "COMPOSER_ALLOW_SUPERUSER": "0"]
        async let v = Shell.run(bin, ["--version", "--no-ansi"], env: env)
        async let home = Shell.run(bin, ["global", "config", "home", "--no-ansi"], env: env)
        let (ver, h) = await (v, home)
        var status = Status()
        for line in ver.output.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            if line.hasPrefix("Composer version"), words.count >= 3 { status.version = words[2] }
            if line.hasPrefix("PHP version"), words.count >= 3 { status.php = words[2] }
        }
        let dir = h.output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }
        if let dir, dir.hasPrefix("/") { status.globalDir = dir }
        return status
    }
}

extension AppState {
    /// Installs a PHP version with Homebrew and prepares its configuration.
    func installPHP(_ formula: String) async {
        guard !phpInstalling.contains(formula) else { return }
        phpInstalling.insert(formula)
        phpInstallErrors[formula] = nil
        defer { phpInstalling.remove(formula) }
        if await brew.ensureInstalled(formula) {
            await applyConfiguration()
        } else {
            phpInstallErrors[formula] = "Couldn't install \(Homebrew.phpLabel(formula, version: nil)). See Logs › Homebrew Activity for details."
        }
    }

    /// Removes a PHP version (its configuration and data folders are left alone).
    func removePHP(_ formula: String) async {
        guard !phpInstalling.contains(formula) else { return }
        phpInstalling.insert(formula)
        defer { phpInstalling.remove(formula) }
        if let pid = ProcessInfoHelper.livePID(pidFile: ConfigGenerator.phpPIDFile(formula)) { kill(pid, SIGQUIT) }
        await brew.uninstall(formula)
        await syncPHP()
    }
}
