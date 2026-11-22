// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

/// "PHP 5.6 — end of life": a version's name with its support status.
@MainActor
func phpTitle(_ formula: String, brew: Homebrew, includeStatus: Bool = true) -> String {
    let version = brew.version(formula)
    var title = Homebrew.phpLabel(formula, version: version)
    guard includeStatus else { return title }
    switch PHPCatalog.status(formula, version: version) {
    case .endOfLife: title += " — end of life"
    case .endingSoon: title += " — support ending"
    case .supported: break
    }
    return title
}

extension View {
    /// Asks before installing a version from the community tap (old, unsupported PHP).
    func phpInstallConfirmation(_ formula: Binding<String?>, onInstalled: @escaping (String) -> Void = { _ in }) -> some View {
        modifier(PHPInstallConfirmation(formula: formula, onInstalled: onInstalled))
    }
}

struct PHPInstallConfirmation: ViewModifier {
    @Environment(AppState.self) private var app
    @Binding var formula: String?
    var onInstalled: (String) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            formula.map { "Install \(Homebrew.phpLabel($0, version: nil))?" } ?? "",
            isPresented: Binding(get: { formula != nil }, set: { if !$0 { formula = nil } }),
            presenting: formula
        ) { f in
            Button("Install") {
                Task {
                    await app.installPHP(f)
                    if app.brew.isInstalled(f) { onInstalled(f) }
                }
            }
        } message: { f in
            Text(message(f))
        }
    }

    private func message(_ f: String) -> String {
        var text = PHPCatalog.warning(f, version: nil).map { $0 + "\n\n" } ?? ""
        text += "Server installs it with Homebrew from the community tap \(PHPCatalog.tap), which publishes maintained builds of old PHP versions. "
        text += "The first one downloads many packages (a few hundred MB)."
        return text
    }
}

/// A warning for end-of-life (or soon-to-be) PHP versions, and an Install button when the
/// version isn't installed yet.
struct PHPNotice: View {
    @Environment(AppState.self) private var app
    let formula: String
    @State private var confirm: String?

    var body: some View {
        if !formula.isEmpty {
            let version = app.brew.version(formula)
            let warning = PHPCatalog.warning(formula, version: version)
            let missing = PHPCatalog.needsTap(formula) && !app.brew.isInstalled(formula)
            if warning != nil || missing {
                VStack(alignment: .leading, spacing: 8) {
                    if let warning {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(warning).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if missing {
                        HStack(spacing: 10) {
                            Text("\(Homebrew.phpLabel(formula, version: nil)) isn't installed yet.").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if app.phpInstalling.contains(formula) {
                                ProgressView().controlSize(.small)
                                Text("Installing…").font(.callout).foregroundStyle(.secondary)
                            } else {
                                Button("Install…") { confirm = formula }.glassButton()
                            }
                        }
                    }
                    if let error = app.phpInstallErrors[formula] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .phpInstallConfirmation($confirm)
            }
        }
    }
}

/// Progress and errors for PHP installs and removals, shown at the top of the PHP page.
struct PHPInstallStatus: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if !app.phpInstalling.isEmpty {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.brew.busyTask ?? "Working…").fontWeight(.medium)
                    Text(app.brew.activity.last ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(14)
            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        ForEach(app.phpInstallErrors.sorted(by: { $0.key < $1.key }), id: \.key) { formula, message in
            ErrorBanner(text: message) { app.phpInstallErrors[formula] = nil }
        }
    }
}
