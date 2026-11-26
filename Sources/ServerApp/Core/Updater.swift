// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

// MARK: - Versions

/// A release version such as 1.2.3, parsed from a tag like "v1.2.3".
/// Pre-release tags ("1.2.0-beta") and anything that isn't numeric are ignored.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty, !text.contains("-"), !text.contains("+") else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        return a.padded(to: n).lexicographicallyPrecedes(b.padded(to: n))
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        return a.padded(to: n) == b.padded(to: n)
    }

    var description: String { padded(to: 3).map(String.init).joined(separator: ".") }

    /// The version of the running app.
    static var current: AppVersion {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0")!
    }

    /// The newest release version among tag names, with the tag it came from.
    static func newest(in tags: [String]) -> (tag: String, version: AppVersion)? {
        tags.compactMap { tag in AppVersion(tag).map { (tag, $0) } }.max { $0.1 < $1.1 }
    }
}

// MARK: - GitHub

struct AvailableUpdate {
    let version: AppVersion
    let tag: String
    let notes: String
    /// The disk image attached to the tag's GitHub release, if there is one.
    let downloadURL: URL?
    let pageURL: URL
}

enum UpdateError: LocalizedError {
    case server(Int)
    case invalidDownload(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .server(let status): String(localized: "GitHub responded with an error (HTTP \(status)).")
        case .invalidDownload(let reason), .installFailed(let reason): reason
        }
    }
}

private struct GitHubTag: Decodable { let name: String }

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }
    let body: String?
    let htmlURL: URL?
    let assets: [Asset]
    enum CodingKeys: String, CodingKey { case body, assets, htmlURL = "html_url" }
}

// MARK: - Updater

/// Checks the GitHub repository's tags for a newer version and offers to
/// install it, remind later, or skip that version.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    static let repository = "advandz/server-app"

    private var isChecking = false
    private var pendingUpdate: AvailableUpdate?
    private var installer: UpdateInstaller?
    private var timer: Timer?

    /// The API base URL. For testing only, the SERVER_APP_UPDATE_FEED environment variable can
    /// point it elsewhere. (A stored preference is deliberately not honoured: any program running
    /// as you could set it and have Server install its own app.)
    private var feedOverride: String? { ProcessInfo.processInfo.environment["SERVER_APP_UPDATE_FEED"] }
    private var feedBase: String { feedOverride ?? "https://api.github.com/repos/\(Self.repository)" }

    // MARK: Scheduling

    /// Checks shortly after every launch, then again once a day while the app stays open.
    func start() {
        guard timer == nil else { return }               // only once, even if the window is reopened
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // An update found while the app was in the background waits until it's in front.
                guard let self, let update = self.pendingUpdate else { return }
                self.pendingUpdate = nil
                self.present(update)
            }
        }
    }

    private func checkIfDue() {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 24 * 60 * 60 else { return }
        check(userInitiated: false)
    }

    // MARK: Checking

    @objc func checkForUpdates(_ sender: Any?) {
        check(userInitiated: true)
    }

    func check(userInitiated: Bool) {
        if let installer {
            installer.bringToFront()
            return
        }
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { isChecking = false }
            do {
                let update = try await fetchNewestUpdate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

                guard let update, update.version > .current else {
                    if userInitiated { showUpToDate() }
                    return
                }
                // Automatic checks respect "Skip This Version"; asking explicitly always shows it.
                let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
                if !userInitiated, skipped == update.version.description { return }

                if userInitiated || NSApp.isActive {
                    present(update)
                } else {
                    pendingUpdate = update
                }
            } catch {
                if userInitiated { showCheckFailed(error) }
            }
        }
    }

    private func fetchNewestUpdate() async throws -> AvailableUpdate? {
        let tags: [GitHubTag] = try await get("tags?per_page=100")
        guard let newest = AppVersion.newest(in: tags.map(\.name)) else { return nil }

        let encodedTag = newest.tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? newest.tag
        let release: GitHubRelease? = try? await get("releases/tags/\(encodedTag)")
        let dmg = release?.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadURL
        let page = release?.htmlURL
            ?? URL(string: "https://github.com/\(Self.repository)/releases/tag/\(encodedTag)")!

        return AvailableUpdate(
            version: newest.version,
            tag: newest.tag,
            notes: release?.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            downloadURL: dmg.map { Self.isTrusted($0, testing: feedOverride != nil) } == true ? dmg : nil,
            pageURL: page
        )
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "\(feedBase)/\(path)") else { throw UpdateError.server(0) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Server/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.server(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Downloads must come over HTTPS from GitHub (or, when testing, from this Mac).
    nonisolated static func isTrusted(_ url: URL, testing: Bool = false) -> Bool {
        let host = (url.host ?? "").lowercased()
        if testing {
            if url.scheme == "https" { return true }
            return url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
        }
        guard url.scheme == "https" else { return false }
        return host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com")
    }

    // MARK: Prompts

    /// "Install Update", "Later" or "Skip This Version".
    private func present(_ update: AvailableUpdate) {
        NSApp.activate()
        let canInstall = update.downloadURL != nil && UpdateInstaller.canReplaceRunningApp

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        let newVersion = update.version.description, currentVersion = AppVersion.current.description
        alert.messageText = String(localized: "A new version of Server is available")
        alert.informativeText = canInstall
            ? String(localized: "Server \(newVersion) is available. You have \(currentVersion). Would you like to install it now? Server will restart when it's done.")
            : String(localized: "Server \(newVersion) is available. You have \(currentVersion).")
        if !update.notes.isEmpty {
            alert.accessoryView = Self.notesView(update.notes)
        }
        alert.addButton(withTitle: canInstall ? String(localized: "Install Update") : String(localized: "View Release"))
        let later = alert.addButton(withTitle: String(localized: "Later"))
        later.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Skip This Version"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canInstall {
                install(update)
            } else {
                NSWorkspace.shared.open(update.pageURL)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(update.version.description, forKey: "skippedVersion")
        default:
            break   // Later: ask again at the next check
        }
    }

    private func install(_ update: AvailableUpdate) {
        let installer = UpdateInstaller(update: update)
        installer.onFailure = { [weak self] error in
            self?.installer = nil
            self?.showInstallFailed(error, update: update)
        }
        installer.onCancel = { [weak self] in self?.installer = nil }
        self.installer = installer
        installer.start()
    }

    private func showUpToDate() {
        NSApp.activate()
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        let version = AppVersion.current.description
        alert.messageText = String(localized: "You're up to date")
        alert.informativeText = String(localized: "Server \(version) is the newest version available.")
        alert.runModal()
    }

    private func showCheckFailed(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't check for updates")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func showInstallFailed(_ error: Error, update: AvailableUpdate) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't install the update")
        let version = update.version.description
        alert.informativeText = error.localizedDescription + "\n\n"
            + String(localized: "You can download Server \(version) from GitHub instead.")
        alert.addButton(withTitle: String(localized: "Open GitHub"))
        alert.addButton(withTitle: String(localized: "Close"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.pageURL)
        }
    }

    /// Release notes from GitHub, shown under the alert text.
    private static func notesView(_ notes: String) -> NSView {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? NSMutableAttributedString(AttributedString(markdown: notes, options: options)))
            ?? NSMutableAttributedString(string: notes)
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let base = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            let font = (value as? NSFont).map { NSFontManager.shared.convert($0, toSize: base.pointSize) } ?? base
            attributed.addAttribute(.font, value: font, range: subrange)
        }

        // Fit short notes; scroll long ones.
        let width: CGFloat = 360
        let fitted = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let height = min(max(ceil(fitted) + 12, 28), 160)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.autoresizingMask = [.width]
        text.textStorage?.setAttributedString(attributed)
        scroll.documentView = text
        return scroll
    }
}

// MARK: - Installer

@MainActor
@Observable
private final class InstallProgress {
    var message = ""
    var fraction: Double? = 0
    var canCancel = true
}

/// Downloads the release's disk image, checks the app inside it, and swaps it
/// in for the running copy once Server quits, then relaunches.
@MainActor
final class UpdateInstaller: NSObject {
    let update: AvailableUpdate
    var onFailure: ((Error) -> Void)?
    var onCancel: (() -> Void)?

    private let progress = InstallProgress()
    private var window: NSWindow?
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ServerUpdate-\(UUID().uuidString)", isDirectory: true)

    init(update: AvailableUpdate) {
        self.update = update
    }

    /// Updating replaces the app in place, so its folder must be writable and
    /// it mustn't be running from a disk image or a translocated copy.
    static var canReplaceRunningApp: Bool {
        let app = Bundle.main.bundleURL
        let path = app.path
        guard !path.contains("/AppTranslocation/") else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: path)
    }

    func start() {
        guard let url = update.downloadURL else { return }
        showWindow()
        let version = update.version.description
        progress.message = String(localized: "Downloading Server \(version)…")

        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let destination = workDirectory.appendingPathComponent("Server-\(update.version).dmg")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, error in
            // Move the file before this handler returns; URLSession deletes it afterwards.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var outcome: Result<URL, Error>
            if let error {
                outcome = .failure(error)
            } else if let location, status == 200 || status == 0 {
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    outcome = .success(destination)
                } catch {
                    outcome = .failure(error)
                }
            } else {
                outcome = .failure(UpdateError.server(status))
            }
            let result = outcome
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.downloadFinished(result) } }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] value, _ in
            let fraction = value.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.progress.fraction = fraction } }
        }
        self.task = task
        task.resume()
    }

    func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func cancel() {
        task?.cancel()
        finish()
        onCancel?()
    }

    private func downloadFinished(_ result: Result<URL, Error>) {
        observation = nil
        switch result {
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            fail(error)
        case .success(let dmg):
            let versionText = update.version.description
            progress.message = String(localized: "Installing Server \(versionText)…")
            progress.fraction = nil
            progress.canCancel = false
            let target = Bundle.main.bundleURL
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let version = update.version
            let work = workDirectory
            Task.detached {
                do {
                    let staged = try Self.stage(dmg: dmg, work: work, version: version, bundleID: bundleID, target: target)
                    await MainActor.run { self.relaunch(replacing: target, with: staged) }
                } catch {
                    await MainActor.run { self.fail(error) }
                }
            }
        }
    }

    /// Mounts the image, checks the app inside and copies it next to the
    /// running app (same volume, so the final swap is a quick rename).
    nonisolated private static func stage(dmg: URL, work: URL, version: AppVersion,
                                          bundleID: String, target: URL) throws -> URL {
        let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let apps = (try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "app" }
        guard let app = apps.first, let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else {
            throw UpdateError.invalidDownload(String(localized: "The downloaded disk image doesn't contain Server."))
        }
        let found = AppVersion(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        guard let found, found == version else {
            let foundVersion = found?.description ?? String(localized: "unknown")
            let expected = version.description
            throw UpdateError.invalidDownload(String(localized: "The downloaded app is version \(foundVersion), not \(expected)."))
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        } catch {
            throw UpdateError.invalidDownload(String(localized: "The downloaded app's code signature isn't valid."))
        }

        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// Hands the swap to a small script that waits for Server to quit.
    private func relaunch(replacing target: URL, with staged: URL) {
        let script = workDirectory.appendingPathComponent("install.sh")
        do {
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path]
            try helper.run()
        } catch {
            let reason = error.localizedDescription
            fail(UpdateError.installFailed(String(localized: "Couldn't start the installer: \(reason)")))
            return
        }
        progress.message = String(localized: "Restarting Server…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private static let installScript = """
    #!/bin/sh
    # Replaces Server.app once the running copy has quit, then relaunches it.
    PID="$1"; TARGET="$2"; STAGED="$3"
    [ -n "$PID" ] && [ -d "$TARGET" ] && [ -d "$STAGED" ] || exit 1
    waited=0
    while kill -0 "$PID" 2>/dev/null; do
      waited=$((waited + 1))
      if [ "$waited" -gt 600 ]; then rm -rf "${STAGED:?}"; exit 1; fi
      sleep 0.5
    done
    BACKUP="${TARGET:?}.previous"
    rm -rf "$BACKUP"
    if mv "$TARGET" "$BACKUP" && mv "$STAGED" "$TARGET"; then
      rm -rf "$BACKUP"
    else
      [ -d "$TARGET" ] || mv "$BACKUP" "$TARGET"
      rm -rf "${STAGED:?}"
    fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1
    for extension in "$TARGET"/Contents/PlugIns/*.appex; do pluginkit -a "$extension" >/dev/null 2>&1; done
    open "$TARGET"
    """

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            let status = Int(process.terminationStatus)
            throw UpdateError.installFailed(String(localized: "\(name) failed (\(status))."))
        }
    }

    private func fail(_ error: Error) {
        finish()
        onFailure?(error)
    }

    private func finish() {
        observation = nil
        window?.close()
        window = nil
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: Window

    private func showWindow() {
        let view = UpdateProgressView(progress: progress) { [weak self] in self?.cancel() }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Updating Server")
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct UpdateProgressView: View {
    let progress: InstallProgress
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 12) {
                Text(progress.message)
                    .font(.headline)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack {
                    Spacer()
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(!progress.canCancel)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
