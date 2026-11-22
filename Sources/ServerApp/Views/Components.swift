// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SystemConfiguration

// MARK: - Liquid Glass helpers (fall back to materials before macOS 26)

extension View {
    @ViewBuilder func glassPanel(_ radius: CGFloat = 18) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

/// A rounded glass card holding a group of form rows, like the panes in Server.app.
struct Card<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.headline).foregroundStyle(.secondary).padding(.leading, 6)
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel()
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
        }
    }
}

extension LocalizedStringKey {
    /// True for the empty key (a form row without a label).
    var isBlank: Bool {
        Mirror(reflecting: self).children.first { $0.label == "key" }.map { ($0.value as? String)?.isEmpty ?? false } ?? false
    }
}

/// Right-aligned label + control, the classic Server.app form layout.
struct FormRow<Content: View>: View {
    let label: LocalizedStringKey
    var labelWidth: CGFloat = 170
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            (label.isBlank ? Text("") : Text(label) + Text(":"))
                .frame(width: labelWidth, alignment: .trailing)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color == .green ? .green.opacity(0.6) : .clear, radius: 3)
    }
}

/// Big icon + title header shown at the top of every detail page.
struct PageHeader<Accessory: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var tint: Color = .accentColor
    /// A realistic system icon (this Mac's model) shown instead of the symbol tile.
    var image: NSImage? = nil
    /// A one-color (template) logo drawn in white on the tinted tile instead of the symbol.
    var glyph: NSImage? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 18) {
            if let image {
                Image(nsImage: image)
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            } else {
                Group {
                    if let glyph {
                        Image(nsImage: glyph).renderingMode(.template)
                            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .padding(15)
                    } else {
                        Image(systemName: symbol).font(.system(size: 30, weight: .medium))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.65)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: tint.opacity(0.35), radius: 8, y: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 28, weight: .regular))
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            Spacer()
            accessory
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(symbol: String, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, tint: Color = .accentColor, image: NSImage? = nil, glyph: NSImage? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, tint: tint, image: image, glyph: glyph) { EmptyView() }
    }
}

/// Facts about this Mac shown in the window title.
enum SystemInfo {
    /// e.g. "macOS Tahoe 26.4 (25E246)".
    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let names = [26: "Tahoe", 15: "Sequoia", 14: "Sonoma"]
        let number = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        var build = ""
        var size = 0
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osversion", &buf, &size, nil, 0) == 0 { build = " (\(String(cString: buf)))" }
        }
        return ["macOS", names[v.majorVersion], number].compactMap { $0 }.joined(separator: " ") + build
    }()
}

/// Realistic macOS icons, the same artwork Finder and About This Mac use.
enum SystemIcon {
    private static let coreTypes = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

    /// Icon of this exact Mac model (Mac mini, MacBook Pro, iMac…), falling back to a generic Mac.
    static let thisMac: NSImage = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(cString: buf)
        if let type = UTType(tag: model, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSImage(contentsOfFile: coreTypes + "com.apple.mac.icns") ?? NSWorkspace.shared.icon(for: .application)
    }()

    /// Icons from System Settings › Network, so interfaces look as they do there.
    private static let networkPane = Bundle(path: "/System/Library/ExtensionKit/Extensions/Network.appex")

    /// The System Settings icon for an interface type ("Wi-Fi", "Ethernet", "VPN"…).
    static func networkInterface(_ type: String) -> NSImage? {
        let name: String
        switch type {
        case "Wi-Fi": name = "WiFi Icon"
        case "Thunderbolt Bridge": name = "Thunderbolt Icon"
        case "VPN": name = "VPN Icon"
        case "Bluetooth": name = "Bluetooth Icon"
        case "iPhone USB", "USB": name = "USB Icon"
        default: name = "Ethernet Icon"
        }
        return networkPane?.image(forResource: name)
    }

    /// Official project logos, bundled in Contents/Resources/Logos (see Resources/Logos).
    /// The nginx and MySQL files are cropped to their marks (the "N" hexagon and the dolphin).
    static let apache = logo("apache")
    static let nginx = logo("nginx")
    static let mysql = logo("mysql")
    static let redis = logo("redis")
    static let apacheMono = monochrome(apache)
    static let nginxMono = monochrome(nginx)
    static let mysqlMono = monochrome(mysql)
    static let redisMono = monochrome(redis)

    private static func logo(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Logos").flatMap(NSImage.init(contentsOf:))
    }

    /// One-color (template) version of a logo for the sidebar: every painted pixel becomes
    /// solid, and near-white areas (the "N" inside the nginx hexagon) are cut out.
    static func monochrome(_ image: NSImage?, size: CGFloat = 64) -> NSImage? {
        guard let image else { return nil }
        let aspect = image.size.width / max(image.size.height, 1)
        let w = Int(aspect >= 1 ? size : size * aspect), h = Int(aspect >= 1 ? size / aspect : size)
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        for i in stride(from: 0, to: rep.bytesPerRow * h, by: 4) {
            let a = Double(data[i + 3]) / 255
            guard a > 0 else { continue }
            // Pixels are premultiplied: un-premultiply to judge how close to white they are.
            let lum = (Double(data[i]) + Double(data[i + 1]) + Double(data[i + 2])) / (3 * 255 * a)
            let ink = lum > 0.85 ? 0 : a
            data[i] = 0; data[i + 1] = 0; data[i + 2] = 0
            data[i + 3] = UInt8(ink * 255)
        }
        let out = NSImage(size: NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2))
        out.addRepresentation(rep)
        out.isTemplate = true
        return out
    }
}

/// Centered segmented tab strip (Overview / Settings / …), as in Server.app.
struct TabStrip<Tab: Hashable & CaseIterable & RawRepresentable>: View where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(Tab.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
    }
}

/// Scrollable page scaffold: header, tabs and content.
struct DetailPage<Header: View, Content: View>: View {
    /// Content width shared by every page (Logs uses it too), so headers line up.
    static var maxWidth: CGFloat { 860 }
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                content
            }
            .padding(28)
            .frame(maxWidth: Self.maxWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ErrorBanner: View {
    let text: String
    var onDismiss: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button { onDismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Start / Stop control for a service, with status.
struct ServiceControl: View {
    @Environment(AppState.self) private var app
    let kind: ServiceKind
    var body: some View {
        let state = app.state(kind)
        HStack(spacing: 10) {
            StatusDot(color: state.color)
            Text(state.label).foregroundStyle(.secondary)
            if state == .starting || state == .stopping { ProgressView().controlSize(.small) }
            if state == .running {
                Button("Restart") { Task { await app.restart(kind) } }.glassButton()
                Button("Stop") { Task { await app.stop(kind) } }.glassButton()
            } else {
                Button(state == .notInstalled ? "Install & Start" : "Start") { Task { await app.start(kind) } }
                    .glassButton(prominent: true)
                    .disabled(state == .starting || state == .stopping)
            }
        }
    }
}

/// Numeric text field bound to an Int.
struct NumberField: View {
    @Binding var value: Int
    var width: CGFloat = 90
    var body: some View {
        TextField("", value: $value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).frame(width: width)
    }
}

/// Multi-line editor for raw config snippets.
struct CodeEditor: View {
    @Binding var text: String
    var height: CGFloat = 80
    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}

/// Tails one of several log files, refreshing every two seconds.

enum FolderPicker {
    @MainActor static func choose(startingAt path: String? = nil, files: Bool = false) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !files
        panel.canChooseFiles = files
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let path { panel.directoryURL = URL(fileURLWithPath: path) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
