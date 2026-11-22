// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// Whether the macOS services Server manages but doesn't run itself (SSH, Screen Sharing, File
/// Sharing, Content Caching) are on, for the sidebar's green dots. Checked every few seconds
/// without privileges.
@MainActor @Observable
final class SystemServices {
    static let shared = SystemServices()

    private(set) var on: Set<SidebarItem> = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func isOn(_ item: SidebarItem) -> Bool { on.contains(item) }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refresh() async {
        let found = await Self.check()
        if found != on { on = found }
    }

    nonisolated private static func check() async -> Set<SidebarItem> {
        async let disabled = Shell.run("/bin/launchctl", ["print-disabled", "system"])
        async let net = Shell.run("/usr/sbin/netstat", ["-an", "-p", "tcp"])
        async let agent = Shell.run("/usr/bin/pgrep", ["-x", "ARDAgent"])
        async let cache = Shell.run(ContentCaching.tool, ["-j", "status"])
        let (d, n, a, c) = await (disabled, net, agent, cache)

        let disabledLines = d.output.split(separator: "\n")
        func enabled(_ label: String) -> Bool {
            guard let line = disabledLines.first(where: { $0.contains("\"\(label)\"") }) else { return true }
            return !line.contains("disabled")
        }
        let netLines = n.output.split(separator: "\n")
        func listening(_ port: String) -> Bool { netLines.contains { $0.contains(".\(port) ") && $0.contains("LISTEN") } }

        var result: Set<SidebarItem> = []
        if enabled("com.openssh.sshd") && listening("22") { result.insert(.ssh) }
        if enabled("com.apple.smbd") && listening("445") { result.insert(.fileSharing) }
        if (enabled("com.apple.screensharing") && listening("5900")) || (a.ok && listening("3283")) { result.insert(.screenSharing) }
        if c.output.contains("\"Active\":true") { result.insert(.caching) }
        return result
    }
}
