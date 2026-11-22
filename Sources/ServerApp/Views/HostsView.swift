// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

/// Edits /etc/hosts. Changes are staged in the page and written in one go with Save
/// (one administrator prompt); lines Server doesn't touch are kept exactly as they were.
struct HostsView: View {
    @Environment(AppState.self) private var app
    @State private var original = ""
    @State private var lines: [HostsLine] = []
    @State private var editing: EditTarget?
    @State private var saving = false
    @State private var error: String?

    struct EditTarget: Identifiable {
        let id = UUID()
        var lineID: UUID?            // nil = new entry
        var entry: HostEntry
    }

    private var entries: [HostsLine] { lines.filter { $0.entry != nil } }
    private var changed: Bool { HostsFile.serialize(lines) != original && !(original.isEmpty && lines.isEmpty) }

    var body: some View {
        DetailPage {
            PageHeader(symbol: "list.bullet.rectangle", title: "Hosts",
                       subtitle: "\(HostsFile.path) · \(entries.count) entries", tint: .indigo) {
                Button { editing = EditTarget(entry: HostEntry(address: "127.0.0.1", names: [])) } label: {
                    Label("Add Entry", systemImage: "plus")
                }
                .glassButton(prominent: true)
            }
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                if let error, !error.isEmpty { ErrorBanner(text: error) { self.error = nil } }
                if changed { pendingBar }
                websiteSuggestions
                Card {
                    ForEach(entries) { line in
                        HostRow(line: line,
                                onToggle: { toggle(line.id) },
                                onEdit: { editing = EditTarget(lineID: line.id, entry: line.entry!) },
                                onDelete: { lines.removeAll { $0.id == line.id } })
                        if line.id != entries.last?.id { Divider() }
                    }
                }
            }
        }
        .sheet(item: $editing) { target in
            HostEntrySheet(entry: target.entry, isNew: target.lineID == nil) { updated in
                if let id = target.lineID, let i = lines.firstIndex(where: { $0.id == id }) {
                    lines[i].entry = updated
                    lines[i].edited = true
                } else {
                    lines.append(HostsLine(raw: updated.formatted, entry: updated, edited: true))
                }
            }
        }
        .task { reload() }
    }

    private var pendingBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
            Text("You have unsaved changes to the hosts file.")
            Spacer()
            Button("Revert") { reload() }.glassButton().disabled(saving)
            Button("Save Changes…") { save() }.glassButton(prominent: true).disabled(saving)
            if saving { ProgressView().controlSize(.small) }
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Website host names that don't end in .localhost need a hosts entry to resolve.
    @ViewBuilder private var websiteSuggestions: some View {
        let known = Set(entries.compactMap(\.entry).filter(\.enabled).flatMap(\.names).map { $0.lowercased() })
        let missing = app.config.websites.filter(\.enabled).flatMap(\.allHostnames)
            .map { $0.lowercased() }
            .filter { !$0.hasSuffix(".localhost") && $0 != "localhost" && !known.contains($0) && HostEntry.isValidName($0) }
        if !missing.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some websites need hosts entries").fontWeight(.medium)
                    Text(Array(Set(missing)).sorted().joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Entries") {
                    for name in Array(Set(missing)).sorted() {
                        let e = HostEntry(address: "127.0.0.1", names: [name], comment: "Server")
                        lines.append(HostsLine(raw: e.formatted, entry: e, edited: true))
                    }
                }
                .glassButton()
            }
            .padding(14)
            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func toggle(_ id: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == id }), var e = lines[i].entry, !e.isSystem else { return }
        e.enabled.toggle()
        lines[i].entry = e
        lines[i].edited = true
    }

    private func reload() {
        original = HostsFile.read()
        lines = HostsFile.parse(original)
        error = nil
    }

    private func save() {
        saving = true
        let text = HostsFile.serialize(lines)
        Task {
            let result = await HostsFile.save(text, original: original)
            saving = false
            if let result {
                if !result.isEmpty { error = result }
            } else {
                reload()
            }
        }
    }
}

struct HostRow: View {
    let line: HostsLine
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        let e = line.entry!
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { e.enabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(e.isSystem)
            Text(e.address).font(.body.monospaced()).frame(width: 150, alignment: .leading)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.names.joined(separator: " ")).lineLimit(1).truncationMode(.middle)
                if !e.comment.isEmpty {
                    Text(e.comment).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if line.edited { Badge(text: "Edited") }
            if e.isSystem {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Required by macOS")
            } else {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit").accessibilityLabel("Edit Entry")
                Button(action: onDelete) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove Entry")
            }
        }
        .opacity(e.enabled ? 1 : 0.55)
    }
}

struct HostEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: HostEntry
    let isNew: Bool
    var onSave: (HostEntry) -> Void
    @State private var names = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(symbol: "list.bullet.rectangle", title: isNew ? "New Hosts Entry" : "Edit Hosts Entry",
                       subtitle: "Point host names at an address", tint: .indigo)
            FormRow(label: "IP Address", labelWidth: 110) {
                TextField("127.0.0.1", text: $entry.address).textFieldStyle(.roundedBorder).frame(width: 260)
            }
            FormRow(label: "Host Names", labelWidth: 110) {
                TextField("mysite.test www.mysite.test", text: $names).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "Comment", labelWidth: 110) {
                TextField("Optional", text: $entry.comment).textFieldStyle(.roundedBorder)
            }
            FormRow(label: "", labelWidth: 110) { Toggle("Enabled", isOn: $entry.enabled) }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange).padding(.leading, 122)
            }
            Text("Changes are saved to the hosts file when you click Save Changes on the Hosts page.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done") {
                    var e = entry
                    e.address = e.address.trimmingCharacters(in: .whitespaces)
                    e.comment = e.comment.replacingOccurrences(of: "\n", with: " ")
                    e.names = parsedNames
                    onSave(e)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .glassButton(prominent: true)
                .disabled(problem != nil)
            }
        }
        .padding(26)
        .frame(width: 520)
        .onAppear { names = entry.names.joined(separator: " ") }
    }

    private var parsedNames: [String] {
        names.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map { String($0).lowercased() }
    }

    private var problem: String? {
        if !HostEntry.isValidAddress(entry.address.trimmingCharacters(in: .whitespaces)) { return "Enter a valid IPv4 or IPv6 address." }
        if parsedNames.isEmpty { return "Enter at least one host name." }
        if let bad = parsedNames.first(where: { !HostEntry.isValidName($0) }) { return "“\(bad)” isn't a valid host name." }
        return nil
    }
}
