// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--ai-server") {
            AIHTTPServer.main(CommandLine.arguments)      // headless OpenAI-compatible server; never returns
        }
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in exit(await SelfTest.run() ? 0 : 1) }
            dispatchMain()
        }
        ServerAppMain.main()
    }
}

struct ServerAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("Server") {
            RootView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(SystemStatus.demoValue == "light" ? .light : SystemStatus.demoValue == "dark" ? .dark : nil)
                .task {
                    delegate.app = app
                    Updater.shared.start()               // before the slower startup work, so it can't delay the check
                    await app.startup()
                    LaunchAtStartup.apply(app.config.startupMode)     // keeps the app's path current
                    LaunchAtStartup.arrangeWindow(app.config.startupMode)
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates(nil) }
            }
            CommandGroup(replacing: .sidebar) {}   // no "Hide Sidebar" menu item
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Whatever is shared through Cloudflare stops being public when Server closes.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { app?.tunnels.stopAllNow() }
    }

    /// Services keep running after quit (like Server.app) unless the user opted out.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app, app.config.stopServicesOnQuit else { return .terminateNow }
        Task { @MainActor in
            await app.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
