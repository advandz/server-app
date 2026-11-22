// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit
import Combine
import DiskArbitration

/// One mounted volume, with what Foundation and Disk Arbitration know about it.
struct VolumeInfo: Identifiable, Sendable {
    let id: URL
    let name: String
    let format: String
    let total: Int64
    let available: Int64
    /// Free space counting purgeable data (caches, local snapshots) macOS can clear on demand.
    let availableIncludingPurgeable: Int64
    let isInternal: Bool?
    let isLocal: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let isReadOnly: Bool
    let isRoot: Bool
    let isEncrypted: Bool?
    let uuid: String?
    let bsdName: String?
    let deviceModel: String?
    let deviceVendor: String?
    let deviceProtocol: String?
    let mediaName: String?

    var used: Int64 { max(0, total - availableIncludingPurgeable) }
    var purgeable: Int64 { max(0, availableIncludingPurgeable - available) }

    var kind: String {
        if !isLocal { return "Network" }
        if isInternal == true { return "Internal" }
        if isRemovable || isEjectable { return "External" }
        return isInternal == false ? "External" : "Disk"
    }
}

enum StorageScanner {
    static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
            .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey,
            .volumeIsRootFileSystemKey, .volumeIsEncryptedKey, .volumeUUIDStringKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        return urls.compactMap { url -> VolumeInfo? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { return nil }
            var desc: [String: Any] = [:]
            if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
               let d = DADiskCopyDescription(disk) as? [String: Any] { desc = d }
            func text(_ key: CFString) -> String? {
                (desc[key as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            let available = Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeInfo(
                id: url,
                name: v.volumeLocalizedName ?? url.lastPathComponent,
                format: v.volumeLocalizedFormatDescription ?? "—",
                total: Int64(total),
                available: available,
                availableIncludingPurgeable: max(available, v.volumeAvailableCapacityForImportantUsage ?? available),
                isInternal: v.volumeIsInternal ?? (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool),
                isLocal: v.volumeIsLocal ?? true,
                isRemovable: v.volumeIsRemovable ?? false,
                isEjectable: v.volumeIsEjectable ?? false,
                isReadOnly: v.volumeIsReadOnly ?? false,
                isRoot: v.volumeIsRootFileSystem ?? false,
                isEncrypted: v.volumeIsEncrypted,
                uuid: v.volumeUUIDString,
                bsdName: text(kDADiskDescriptionMediaBSDNameKey),
                deviceModel: text(kDADiskDescriptionDeviceModelKey),
                deviceVendor: text(kDADiskDescriptionDeviceVendorKey),
                deviceProtocol: text(kDADiskDescriptionDeviceProtocolKey),
                mediaName: text(kDADiskDescriptionMediaNameKey)
            )
        }
        .sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Storage tab

struct StorageTab: View {
    @State private var volumes: [VolumeInfo] = []
    @State private var loaded = false

    private let mounts = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
        .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification),
               NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification))

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !loaded {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
            } else if volumes.isEmpty {
                Text("No storage devices found.").foregroundStyle(.secondary)
            } else {
                ForEach(volumes) { VolumeCard(volume: $0) }
            }
        }
        .task { await reload() }
        .onReceive(mounts) { _ in Task { await reload() } }
    }

    private func reload() async {
        volumes = await Task.detached(priority: .userInitiated) { StorageScanner.volumes() }.value
        loaded = true
    }
}

struct VolumeCard: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: volume.id.path))
                    .resizable().interpolation(.high).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(volume.name).font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(bytes(volume.availableIncludingPurgeable)) available").font(.callout.weight(.medium))
                    Text("of \(bytes(volume.total))").font(.callout).foregroundStyle(.secondary)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([volume.id]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show in Finder")
            }

            UsageBar(volume: volume)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    detail("Device", device)
                    detail("Connection", volume.deviceProtocol ?? volume.kind)
                }
                GridRow {
                    detail("File System", volume.format)
                    detail("BSD Device", volume.bsdName.map { "/dev/\($0)" } ?? "—")
                }
                GridRow {
                    detail("Mount Point", volume.id.path)
                    detail("Capacity", "\(bytes(volume.total)) (\(volume.total.formatted()) bytes)")
                }
                GridRow {
                    detail("Used", bytes(volume.used))
                    detail("Purgeable", bytes(volume.purgeable))
                }
                GridRow {
                    detail("Encrypted", volume.isEncrypted.map { $0 ? "Yes" : "No" } ?? "—")
                    detail("Read-only", volume.isReadOnly ? "Yes" : "No")
                }
                GridRow {
                    detail("Ejectable", volume.isEjectable ? "Yes" : "No")
                    detail("UUID", volume.uuid ?? "—")
                }
            }
            .font(.callout)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var subtitle: String {
        var parts = [volume.kind, volume.format]
        if volume.isRoot { parts.insert("Startup Disk", at: 0) }
        return parts.joined(separator: " · ")
    }

    private var device: String {
        let parts = [volume.deviceVendor, volume.deviceModel].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return volume.mediaName ?? "—"
    }

    @ViewBuilder private func detail(_ label: String, _ value: String) -> some View {
        Text(label + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
        Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Used / purgeable / free, like the bar in System Settings › Storage.
struct UsageBar: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let total = max(Double(volume.total), 1)
                HStack(spacing: 2) {
                    segment(.blue, Double(volume.used) / total * geo.size.width)
                    segment(.gray.opacity(0.6), Double(volume.purgeable) / total * geo.size.width)
                    Color.primary.opacity(0.08)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 14)
            HStack(spacing: 16) {
                legend(.blue, "Used", volume.used)
                if volume.purgeable > 0 { legend(.gray.opacity(0.6), "Purgeable", volume.purgeable) }
                legend(Color.primary.opacity(0.15), "Free", volume.available)
                Spacer()
                Text(percent).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var percent: String {
        let p = Double(volume.used) / max(Double(volume.total), 1)
        return p.formatted(.percent.precision(.fractionLength(0))) + " used"
    }

    private func segment(_ color: Color, _ width: CGFloat) -> some View {
        color.frame(width: max(0, width))
    }

    private func legend(_ color: Color, _ label: String, _ value: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption)
            Text(bytes(value)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
