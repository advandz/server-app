// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import AppKit

/// How Server opens when you log in to your Mac.
enum StartupMode: String, Codable, CaseIterable, Identifiable {
    case none, minimized, fullScreen
    var id: String { rawValue }
    var title: String {
        switch self { case .none: String(localized: "None"); case .minimized: String(localized: "Minimized"); case .fullScreen: String(localized: "Full Screen") }
    }
}

/// Opens Server at login through a per-user launch agent. The agent passes `--launched-at-login`,
/// so the window only minimizes or goes full screen on a startup launch, never when you open
/// the app yourself.
enum LaunchAtStartup {
    static let argument = "--launched-at-login"
    static let label = "com.local.serverapp.login"
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }

    static var launchedAtLogin: Bool { CommandLine.arguments.contains(argument) }

    /// Only an installed app bundle can be started at login (not a `swift run` build).
    static var canRegister: Bool { Bundle.main.bundlePath.hasSuffix(".app") && Bundle.main.executablePath != nil }

    /// Writes or removes the launch agent so it matches the setting. Also refreshes the app's
    /// path each launch, in case the app was moved.
    @discardableResult
    static func apply(_ mode: StartupMode) -> String? {
        let fm = FileManager.default
        if mode == .none {
            try? fm.removeItem(atPath: plistPath)
            return nil
        }
        guard canRegister, let exe = Bundle.main.executablePath else {
            return "Server has to run from the app bundle (Server.app) to open at startup."
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, argument],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        do {
            try fm.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            return nil
        } catch {
            return "Couldn't set up opening at startup: \(error.localizedDescription)"
        }
    }

    /// Minimizes or enters full screen for a startup launch.
    @MainActor
    static func arrangeWindow(_ mode: StartupMode) {
        guard launchedAtLogin, mode != .none else { return }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.styleMask.contains(.titled) }) else { return }
        switch mode {
        case .minimized: window.miniaturize(nil)
        case .fullScreen: if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .none: break
        }
    }
}
