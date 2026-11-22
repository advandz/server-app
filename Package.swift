// swift-tools-version: 6.0
// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ServerApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ServerApp",
            path: "Sources/ServerApp",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
