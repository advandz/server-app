// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Update disk images are signed with a private key kept off GitHub (see Tools/sign-update.swift).
/// The app only installs an image whose signature matches this public key, so someone who
/// controls the download (a hijacked release, a proxy) can't make Server install their own app.
enum UpdateSigning {
    /// Ed25519 public key, base64.
    static let publicKey = "UOiNp5D5TroGobb5VU8Qv7pL8LT9Pjym3fdOLIwdlTk="

    /// What gets signed: the version is included, so an old signed image can't pass as a new release.
    static func message(version: String, sha256: String) -> Data {
        Data("server-app-update\n\(version)\n\(sha256)\n".utf8)
    }

    /// True when `signature` (base64 text) is a valid signature of this file and version.
    nonisolated static func verify(file: URL, version: String, signature: String, publicKey: String = UpdateSigning.publicKey) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let handle = try? FileHandle(forReadingFrom: file)
        else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return key.isValidSignature(sig, for: message(version: version, sha256: hash))
    }
}
