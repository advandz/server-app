// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI

/// The Settings sheet (Server › Settings…, ⌘,).
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        let mode = app.config.startupMode
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(symbol: "gearshape", title: "Settings", subtitle: "Server", tint: .gray)
            Card(footer: footer(mode)) {
                FormRow(label: "Launch on Startup", labelWidth: 150) {
                    Picker("", selection: Binding(get: { app.config.startupMode }, set: choose)) {
                        ForEach(StartupMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).glassButton(prominent: true)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func choose(_ mode: StartupMode) {
        problem = LaunchAtStartup.apply(mode)
        app.update { $0.startupMode = problem == nil ? mode : .none }
    }

    private func footer(_ mode: StartupMode) -> LocalizedStringKey {
        switch mode {
        case .none: "Server doesn't open when you log in."
        case .minimized: "Server opens when you log in, minimized to the Dock."
        case .fullScreen: "Server opens when you log in, in full screen."
        }
    }
}
