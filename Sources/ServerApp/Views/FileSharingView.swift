// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

/// macOS's built-in File Sharing (SMB). The on/off state is read without privileges; listing
/// shared folders and every change need an administrator password. Server never turns this
/// off on its own (it isn't one of the app's services).
enum FileSharing {
    static let daemon = "/System/Library/LaunchDaemons/com.apple.smbd.plist"
    static let sharing = "/usr/sbin/sharing"

    struct Share: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var path: String
        var shared = true
        var guest = false
        var readOnly = false
        var encrypted = false
    }

    /// File Sharing counts as on when smbd isn't disabled and something is listening on 445.
    static func isOn() async -> Bool {
        async let disabled = Shell.run("/bin/launchctl", ["print-disabled", "system"])
        async let net = Shell.run("/usr/sbin/netstat", ["-an", "-p", "tcp"])
        let (d, n) = await (disabled, net)
        let line = d.output.split(separator: "\n").first { $0.contains("\"com.apple.smbd\"") } ?? ""
        let notDisabled = !line.contains("disabled")
        let listening = n.output.split(separator: "\n").contains { $0.contains(".445 ") && $0.contains("LISTEN") }
        return notDisabled && listening
    }

    /// NetBIOS name and workgroup from the SMB server preferences (readable without privileges).
    static func serverInfo() -> (netbios: String?, workgroup: String?) {
        let prefs = NSDictionary(contentsOfFile: "/Library/Preferences/SystemConfiguration/com.apple.smb.server.plist")
        return (prefs?["NetBIOSName"] as? String, prefs?["Workgroup"] as? String)
    }

    /// Parses `sharing -l`:
    ///   name:  Public
    ///   path:  /Users/me/Public
    ///       smb: { name: Public  shared: 1  guest access: 1  read-only: 0 … }
    static func parse(_ text: String) -> [Share] {
        var shares: [Share] = []
        var current: Share?
        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indented = raw.hasPrefix("\t") || raw.hasPrefix(" ")
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else {
                if line == "}" { section = "" }
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !indented && key == "name" {
                if let current { shares.append(current) }
                current = Share(name: value, path: "")
                section = ""
            } else if !indented && key == "path" {
                current?.path = value
            } else if value.hasPrefix("{") {
                section = key
            } else if section == "smb" {
                let on = value.hasPrefix("1")
                switch key {
                case "shared": current?.shared = on
                case "guest access": current?.guest = on
                case "read-only", "read only", "readonly": current?.readOnly = on
                case "encrypted", "smb encrypted": current?.encrypted = on
                default: break
                }
            }
        }
        if let current { shares.append(current) }
        return shares.filter { !$0.path.isEmpty }
    }

    /// Runs privileged commands, then lists the shares in the same password prompt.
    static func perform(_ commands: [[String]]) async -> (shares: [Share]?, error: String?) {
        switch await Privileged.execute(commands + [[sharing, "-l"]]) {
        case .success(let output): return (parse(output), nil)
        case .cancelled: return (nil, "")
        case .failed(let message): return (nil, message)
        }
    }

    /// The SMB service's launchd state is the switch (it's what General › Sharing changes).
    /// Its preferences file is managed by macOS and can't be written directly, even as root.
    static func setOn(_ on: Bool) -> [[String]] {
        on
            ? [["/bin/launchctl", "enable", "system/com.apple.smbd"],
               ["/bin/launchctl", "load", "-w", daemon]]
            : [["/bin/launchctl", "unload", "-w", daemon],
               ["/bin/launchctl", "disable", "system/com.apple.smbd"]]
    }
}

// MARK: - Page

struct FileSharingView: View {
    @State private var on: Bool?
    @State private var shares: [FileSharing.Share]?
    @State private var working = false
    @State private var error: String?
    @State private var removing: FileSharing.Share?
    @State private var adding: FolderChoice?
    private let system = SystemStatus.shared

    var body: some View {
        DetailPage {
            PageHeader(symbol: "folder.badge.person.crop", title: "File Sharing",
                       subtitle: on == nil ? "macOS File Sharing (SMB)" : on! ? "On · smb://\(system.hostName)" : "Off",
                       tint: .blue) {
                if working { ProgressView().controlSize(.small) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
                statusCard
                sharesCard
            }
        }
        .task { on = await FileSharing.isOn() }
        .sheet(item: $adding) { choice in
            let url = choice.url
            NewShareSheet(folder: url) { name, guest, readOnly in
                perform([[FileSharing.sharing, "-a", url.path, "-n", name, "-S", name, "-s", "001",
                          "-g", guest ? "001" : "000", "-R", readOnly ? "1" : "0"]])
            }
        }
        .confirmationDialog("Stop sharing “\(removing?.name ?? "")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { share in
            Button("Stop Sharing", role: .destructive) { perform([[FileSharing.sharing, "-r", share.name]]) }
        } message: { _ in
            Text("The folder and its files stay where they are.")
        }
    }

    private var statusCard: some View {
        let info = FileSharing.serverInfo()
        return Card(footer: "Share folders with other Macs and PCs on your network, like General › Sharing in System Settings. Changes ask for an administrator password.") {
            FormRow(label: "File Sharing") {
                Toggle("Share files and folders using SMB", isOn: Binding(get: { on ?? false }, set: { setOn($0) }))
                    .disabled(on == nil || working)
            }
            FormRow(label: "Address") {
                Text("smb://\(system.hostName)").textSelection(.enabled)
                    .foregroundStyle(on == true ? .primary : .secondary)
            }
            if let name = info.netbios {
                FormRow(label: "NetBIOS Name") { Text(name).textSelection(.enabled) }
            }
            if let group = info.workgroup {
                FormRow(label: "Workgroup") { Text(group) }
            }
        }
    }

    private var sharesCard: some View {
        Card(title: "Shared Folders") {
            if let shares {
                if shares.isEmpty {
                    Text("No folders are shared.").foregroundStyle(.secondary)
                }
                ForEach(shares) { share in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: share.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(share.name).fontWeight(.medium)
                            Text(share.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Toggle("Guests", isOn: Binding(get: { share.guest }, set: {
                            perform([[FileSharing.sharing, "-e", share.name, "-g", $0 ? "001" : "000"]])
                        }))
                        .toggleStyle(.checkbox).help("Allow guest users to connect without an account")
                        Toggle("Read only", isOn: Binding(get: { share.readOnly }, set: {
                            perform([[FileSharing.sharing, "-e", share.name, "-R", $0 ? "1" : "0"]])
                        }))
                        .toggleStyle(.checkbox)
                        Button { removing = share } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop sharing").accessibilityLabel("Stop Sharing")
                    }
                    .disabled(working)
                    if share.id != shares.last?.id { Divider() }
                }
                HStack {
                    Button("Add Folder…") {
                        if let path = FolderPicker.choose(startingAt: NSHomeDirectory()) { adding = FolderChoice(url: URL(fileURLWithPath: path)) }
                    }
                    .glassButton()
                    Spacer()
                    Button("Reload") { perform([]) }.buttonStyle(.link)
                }
                .disabled(working)
            } else {
                HStack {
                    Text("macOS only lists shared folders to administrators.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Shared Folders…") { perform([]) }.glassButton().disabled(working)
                }
            }
        }
    }

    private func setOn(_ value: Bool) {
        working = true
        Task {
            let result = await Privileged.run(FileSharing.setOn(value))
            if let result, !result.isEmpty { error = result }
            on = await FileSharing.isOn()
            await SystemServices.shared.refresh()
            working = false
        }
    }

    private func perform(_ commands: [[String]]) {
        working = true
        Task {
            let (list, err) = await FileSharing.perform(commands)
            if let list { shares = list }
            if let err, !err.isEmpty { error = err }
            on = await FileSharing.isOn()
            await SystemServices.shared.refresh()
            working = false
        }
    }
}

struct FolderChoice: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct NewShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    var onAdd: (String, Bool, Bool) -> Void
    @State private var name = ""
    @State private var guest = false
    @State private var readOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(symbol: "folder.badge.person.crop", title: "Share Folder", subtitle: "\(folder.path)", tint: .blue)
            FormRow(label: "Share Name", labelWidth: 110) {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "", labelWidth: 110) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Allow guest users", isOn: $guest)
                    Toggle("Read only", isOn: $readOnly)
                }
            }
            Text("Who can open the folder still follows its file permissions. macOS asks for an administrator password.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Share") { onAdd(name.trimmingCharacters(in: .whitespaces), guest, readOnly); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 520)
        .onAppear { name = folder.lastPathComponent }
    }
}
