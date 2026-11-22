// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

/// macOS Screen Sharing (the built-in VNC server, port 5900) and, read-mostly, Remote Management
/// (the Apple Remote Desktop agent). System services: Server switches and configures them but
/// never turns them off on its own.
enum ScreenSharing {
    static let daemon = "/System/Library/LaunchDaemons/com.apple.screensharing.plist"
    static let accessGroup = "com.apple.access_screensharing"
    static let kickstart = "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

    struct Status {
        var screenSharing = false        // VNC server enabled and listening on 5900
        var remoteManagement = false     // ARD agent active (listening on 3283)
        var allLocalUsers = false        // Remote Management: all local users may connect
        var vncPassword = false          // "VNC viewers may control screen with password"
        var requestPermission = false    // "Anyone may request permission to control screen"
    }

    static func status() async -> Status {
        async let disabled = Shell.run("/bin/launchctl", ["print-disabled", "system"])
        async let net = Shell.run("/usr/sbin/netstat", ["-an", "-p", "tcp"])
        async let agent = Shell.run("/usr/bin/pgrep", ["-x", "ARDAgent"])
        let (d, n, a) = await (disabled, net, agent)
        let listening = { (port: String) in
            n.output.split(separator: "\n").contains { $0.contains(".\(port) ") && $0.contains("LISTEN") }
        }
        let line = d.output.split(separator: "\n").first { $0.contains("\"com.apple.screensharing\"") } ?? ""
        let prefs = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.RemoteManagement.plist")
        func flag(_ key: String) -> Bool { (prefs?[key] as? NSNumber)?.boolValue ?? false }
        return Status(
            screenSharing: !line.contains("disabled") && listening("5900"),
            remoteManagement: a.ok && listening("3283"),
            allLocalUsers: flag("ARD_AllLocalUsers"),
            vncPassword: flag("VNCLegacyConnectionsEnabled"),
            requestPermission: flag("ScreenSharingReqPermEnabled")
        )
    }

    static func setScreenSharing(_ on: Bool) -> [[String]] {
        on
            ? [["/bin/launchctl", "enable", "system/com.apple.screensharing"], ["/bin/launchctl", "load", "-w", daemon]]
            : [["/bin/launchctl", "unload", "-w", daemon], ["/bin/launchctl", "disable", "system/com.apple.screensharing"]]
    }

    /// Lets standard VNC viewers connect with a password (VNC passwords are at most 8 characters).
    static func setVNCPassword(_ password: String) -> [[String]] {
        [[kickstart, "-configure", "-clientopts", "-setvnclegacy", "-vnclegacy", "yes", "-setvncpw", "-vncpw", password],
         [kickstart, "-restart", "-agent"]]
    }

    static func disableVNCPassword() -> [[String]] {
        [[kickstart, "-configure", "-clientopts", "-setvnclegacy", "-vnclegacy", "no"], [kickstart, "-restart", "-agent"]]
    }

    static func setRequestPermission(_ on: Bool) -> [[String]] {
        [[kickstart, "-configure", "-clientopts", "-setreqperm", "-reqperm", on ? "yes" : "no"], [kickstart, "-restart", "-agent"]]
    }

    static func turnOffRemoteManagement() -> [[String]] {
        [[kickstart, "-deactivate", "-configure", "-access", "-off"]]
    }

    static func openSharingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Page

struct ScreenSharingView: View {
    @State private var status: ScreenSharing.Status?
    @State private var access: SSHService.Access?
    @State private var users: [SSHService.MacUser] = []
    @State private var working = false
    @State private var error: String?
    @State private var confirmOff = false
    @State private var confirmARDOff = false
    @State private var settingPassword = false
    private let system = SystemStatus.shared

    var body: some View {
        DetailPage {
            PageHeader(symbol: "rectangle.on.rectangle", title: "Screen Sharing", subtitle: "\(subtitle)", tint: .blue) {
                if working { ProgressView().controlSize(.small) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
                if let status {
                    statusCard(status)
                    if !status.remoteManagement, let access { accessCard(access) }
                    vncCard(status)
                    connectCard(status)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
                }
            }
        }
        .task { await reload() }
        .confirmationDialog("Turn off Screen Sharing?", isPresented: $confirmOff) {
            Button("Turn Off", role: .destructive) { apply(ScreenSharing.setScreenSharing(false)) }
        } message: {
            Text("Anyone viewing or controlling this Mac's screen is disconnected.")
        }
        .confirmationDialog("Turn off Remote Management?", isPresented: $confirmARDOff) {
            Button("Turn Off", role: .destructive) { apply(ScreenSharing.turnOffRemoteManagement()) }
        } message: {
            Text("Apple Remote Desktop can no longer manage this Mac, and active sessions are disconnected. Turning it back on is done in System Settings.")
        }
        .sheet(isPresented: $settingPassword) {
            VNCPasswordSheet { password in apply(ScreenSharing.setVNCPassword(password)) }
        }
    }

    private var subtitle: String {
        guard let s = status else { return "macOS Screen Sharing (VNC)" }
        if s.remoteManagement { return "On through Remote Management · vnc://\(system.hostName)" }
        return s.screenSharing ? "On · vnc://\(system.hostName)" : "Off"
    }

    private func statusCard(_ s: ScreenSharing.Status) -> some View {
        Card(footer: "Lets others see and control this Mac's screen with the Screen Sharing app or any VNC viewer. Uses macOS's built-in server. Changes ask for an administrator password.") {
            FormRow(label: "Screen Sharing") {
                Toggle("Allow others to view and control this screen", isOn: Binding(get: { s.screenSharing || s.remoteManagement }, set: { on in
                    if on { apply(ScreenSharing.setScreenSharing(true)) } else { confirmOff = true }
                }))
                .disabled(working || s.remoteManagement)
            }
            FormRow(label: "Remote Management") {
                HStack(spacing: 10) {
                    StatusDot(color: s.remoteManagement ? .green : .secondary)
                    Text(s.remoteManagement ? "On (Apple Remote Desktop)" : "Off").foregroundStyle(.secondary)
                    if s.remoteManagement {
                        Button("Turn Off…") { confirmARDOff = true }.glassButton().disabled(working)
                    }
                    Button("Sharing Settings…") { ScreenSharing.openSharingSettings() }.buttonStyle(.link)
                }
            }
            if s.remoteManagement {
                Text("Remote Management includes Screen Sharing and controls who can connect"
                     + (s.allLocalUsers ? " (currently all users of this Mac)." : ". Choose users in System Settings."))
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 182)
            }
        }
    }

    private func accessCard(_ a: SSHService.Access) -> some View {
        Card(title: "Allow Access For") {
            FormRow(label: "Users") {
                Picker("", selection: Binding(get: { a.restricted }, set: { restricted in
                    var to = a
                    to.restricted = restricted
                    if restricted && !a.restricted { to.admins = true }
                    apply(SSHService.changeAccess(from: a, to: to, group: ScreenSharing.accessGroup))
                })) {
                    Text("All users").tag(false)
                    Text("Only these users").tag(true)
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            if a.restricted {
                FormRow(label: "") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Administrators", isOn: Binding(get: { a.admins }, set: { v in
                            var to = a; to.admins = v
                            apply(SSHService.changeAccess(from: a, to: to, group: ScreenSharing.accessGroup))
                        }))
                        ForEach(users) { u in
                            Toggle(isOn: Binding(get: { a.users.contains(u.name) || (a.admins && u.isAdmin) }, set: { v in
                                var to = a
                                if v { to.users.insert(u.name) } else { to.users.remove(u.name) }
                                apply(SSHService.changeAccess(from: a, to: to, group: ScreenSharing.accessGroup))
                            })) {
                                Text("\(u.realName) (\(u.name))") + Text(u.isAdmin ? "  · Admin" : "").foregroundStyle(.secondary)
                            }
                            .disabled(a.admins && u.isAdmin)
                        }
                    }
                }
            }
        }
        .disabled(working)
    }

    private func vncCard(_ s: ScreenSharing.Status) -> some View {
        Card(title: "Options",
             footer: "Mac users connect with their own account. A VNC password is for other VNC viewers (Windows, Linux, iPad apps); VNC only uses the first 8 characters, so prefer the Screen Sharing app on networks you don't trust.") {
            FormRow(label: "VNC Viewers") {
                HStack(spacing: 10) {
                    Text(s.vncPassword ? "May control the screen with a password" : "Off").foregroundStyle(.secondary)
                    Button(s.vncPassword ? "Change Password…" : "Set Password…") { settingPassword = true }.glassButton()
                    if s.vncPassword {
                        Button("Turn Off") { apply(ScreenSharing.disableVNCPassword()) }.glassButton()
                    }
                }
            }
            FormRow(label: "Requests") {
                Toggle("Anyone may request permission to control the screen", isOn: Binding(get: { s.requestPermission }, set: {
                    apply(ScreenSharing.setRequestPermission($0))
                }))
            }
        }
        .disabled(working)
    }

    private func connectCard(_ s: ScreenSharing.Status) -> some View {
        let address = "vnc://\(system.hostName)"
        return Card(title: "Connect") {
            FormRow(label: "Address") {
                HStack {
                    Text(address).font(.body.monospaced()).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy").accessibilityLabel("Copy Address")
                }
            }
            FormRow(label: "Ports") {
                Text(s.remoteManagement ? "5900 (VNC), 3283 (Remote Desktop)" : "5900 (VNC)").foregroundStyle(.secondary)
            }
        }
    }

    private func apply(_ commands: [[String]]) {
        guard !commands.isEmpty else { return }
        working = true
        Task {
            if let result = await Privileged.run(commands), !result.isEmpty { error = result }
            try? await Task.sleep(for: .seconds(1))     // services take a moment to (un)bind their ports
            await reload()
            working = false
        }
    }

    private func reload() async {
        async let s = ScreenSharing.status()
        async let a = SSHService.access(group: ScreenSharing.accessGroup)
        async let u = SSHService.users()
        (status, access, users) = await (s, a, u)
        await SystemServices.shared.refresh()
    }
}

struct VNCPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (String) -> Void
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "key", title: "VNC Password", subtitle: "For VNC viewers other than Screen Sharing", tint: .blue)
            FormRow(label: "Password", labelWidth: 110) { SecureField("", text: $password).textFieldStyle(.roundedBorder) }
            FormRow(label: "Confirm", labelWidth: 110) { SecureField("", text: $confirm).textFieldStyle(.roundedBorder) }
            if password.count > 8 {
                Text("VNC only uses the first 8 characters.").font(.caption).foregroundStyle(.orange).padding(.leading, 122)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Password") { onSave(password); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
                    .disabled(password.isEmpty || password != confirm)
            }
        }
        .padding(26)
        .frame(width: 480)
    }
}
