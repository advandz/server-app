// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import AppKit
import CoreLocation
import CoreWLAN
import Observation

/// macOS only reveals Wi-Fi network names (SSIDs) to apps the user has allowed to use
/// Location Services. This tracks that permission and asks for it on request.
@MainActor @Observable
final class WiFiAccess: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiAccess()

    private(set) var status: CLAuthorizationStatus
    @ObservationIgnored private let manager = CLLocationManager()

    var allowed: Bool { status == .authorizedAlways || status == .authorized }
    var denied: Bool { status == .denied || status == .restricted }

    private override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func request() {
        if denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
    }

    /// The Wi-Fi network name for an interface (or the default Wi-Fi interface), when allowed.
    nonisolated static func ssid(interface bsd: String? = nil) -> String? {
        let client = CWWiFiClient.shared()
        let iface = bsd.flatMap { client.interface(withName: $0) } ?? client.interface()
        return iface?.ssid()
    }
}
