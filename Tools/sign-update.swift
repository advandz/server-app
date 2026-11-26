// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT
//
// Signs update disk images so the app's updater can tell a real release from a forged one.
//
//   swift Tools/sign-update.swift keygen            creates the private key (once) and prints the public key
//   swift Tools/sign-update.swift sign <dmg> <ver>  writes <dmg>.sig
//
// The private key lives outside the repository (SERVER_APP_SIGNING_KEY, default
// ~/.server-app-signing/update-signing.key). Back it up and never commit it. The message that
// is signed must match UpdateSigning.message in Sources/ServerApp/Core/UpdateSigning.swift.

import CryptoKit
import Foundation

let keyPath = ProcessInfo.processInfo.environment["SERVER_APP_SIGNING_KEY"]
    ?? NSHomeDirectory() + "/.server-app-signing/update-signing.key"

func fail(_ text: String) -> Never { FileHandle.standardError.write(Data((text + "\n").utf8)); exit(1) }

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyPath). Run: swift Tools/sign-update.swift keygen") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    if FileManager.default.fileExists(atPath: keyPath) {
        print("Key already exists at \(keyPath)")
    } else {
        let dir = (keyPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        FileManager.default.createFile(atPath: keyPath, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
        print("Created \(keyPath). Back it up and keep it secret.")
    }
    print("Public key: \(loadKey().publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    let rest = Array(args.dropFirst())
    guard rest.count == 2, let data = try? Data(contentsOf: URL(fileURLWithPath: rest[0]), options: .mappedIfSafe)
    else { fail("usage: sign <dmg> <version>") }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let message = Data("server-app-update\n\(rest[1])\n\(hash)\n".utf8)
    let signature = try loadKey().signature(for: message)
    try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: rest[0] + ".sig"))
    print("Signed \(rest[0]) (version \(rest[1]))")
default:
    fail("usage: sign-update.swift keygen | sign <dmg> <version>")
}
