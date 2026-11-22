// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import AppKit
import Observation

/// Finds a website's own icon (apple-touch-icon or favicon), so the list can show it instead
/// of the generic globe. Looks in the document root first, then asks the running site.
@MainActor @Observable
final class SiteIcons {
    static let shared = SiteIcons()

    private var images: [String: NSImage?] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    /// The cached icon, or nil while loading / when the site has none.
    /// `serving` is the site's address when its web server is running.
    func icon(for site: Website, serving: URL?) -> NSImage? {
        let key = "\(site.id)|\(site.documentRoot)|\(serving?.absoluteString ?? "-")"
        if let cached = images[key] { return cached }
        if !loading.contains(key) {
            loading.insert(key)
            let root = site.documentRoot
            Task {
                let image = await Self.load(root: root, base: serving)
                images[key] = .some(image)
                loading.remove(key)
            }
        }
        // While a new lookup runs, keep showing an icon found earlier for this site.
        return images.first { $0.key.hasPrefix("\(site.id)|") && $0.value != nil }?.value ?? nil
    }

    // MARK: Lookup

    /// Well-known names, best first (apple-touch icons are 180px, favicons often 16–32px).
    nonisolated private static let wellKnown = ["apple-touch-icon.png", "apple-touch-icon-precomposed.png",
                                    "favicon.svg", "favicon.png", "favicon.ico"]

    nonisolated private static func load(root: String, base: URL?) async -> NSImage? {
        // 1. Files in the document root: <link> tags in a static index page, then well-known names.
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        for index in ["index.html", "index.htm"] {
            if let html = try? String(contentsOf: rootURL.appendingPathComponent(index), encoding: .utf8) {
                for href in iconLinks(in: html) where !href.contains("://") && !href.hasPrefix("//") {
                    let path = href.hasPrefix("/") ? String(href.dropFirst()) : href
                    if let img = image(file: rootURL.appendingPathComponent(path)) { return img }
                }
            }
        }
        for name in wellKnown {
            if let img = image(file: rootURL.appendingPathComponent(name)) { return img }
        }

        // 2. The running site: <link> tags in its home page, then well-known names.
        guard let base, let host = base.host, resolvesToThisMac(host) else { return nil }
        if let (data, _) = try? await session.data(from: base), let html = String(data: data, encoding: .utf8) {
            for href in iconLinks(in: html) {
                if let url = URL(string: href, relativeTo: base), let img = await image(url: url) { return img }
            }
        }
        for name in wellKnown {
            if let url = URL(string: "/" + name, relativeTo: base), let img = await image(url: url) { return img }
        }
        return nil
    }

    /// `href`s of <link rel="…icon…"> tags, apple-touch-icon first.
    nonisolated static func iconLinks(in html: String) -> [String] {
        guard let tagRx = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return [] }
        var touch: [String] = [], icons: [String] = []
        let ns = html as NSString
        for m in tagRx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  !rel.contains("mask-icon"), let href = attribute("href", in: tag), !href.isEmpty else { continue }
            if rel.contains("apple-touch-icon") { touch.append(href) } else { icons.append(href) }
        }
        return touch + icons
    }

    nonisolated private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = rx.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for i in 1...3 where m.range(at: i).location != NSNotFound {
            return (tag as NSString).substring(with: m.range(at: i)).replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }

    /// Only talk to hosts that point at this Mac, so a site named after a real domain
    /// never makes a request out to the internet.
    nonisolated private static func resolvesToThisMac(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let ai = node {
            switch Int32(ai.pointee.ai_family) {
            case AF_INET:
                let addr = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                if UInt32(bigEndian: addr) >> 24 != 127 { return false }
            case AF_INET6:
                var a = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let loopback = withUnsafeBytes(of: &a) { b in b.prefix(15).allSatisfy { $0 == 0 } && b[15] == 1 }
                if !loopback { return false }
            default: return false
            }
            node = ai.pointee.ai_next
        }
        return true
    }

    nonisolated private static func image(file: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: file), data.count < 2_000_000 else { return nil }
        return usable(NSImage(data: data))
    }

    nonisolated private static func image(url: URL) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { return nil }
        return usable(NSImage(data: data))
    }

    nonisolated private static func usable(_ image: NSImage?) -> NSImage? {
        guard let image, image.isValid, image.size.width >= 8, image.size.height >= 8 else { return nil }
        return image
    }

    /// Short timeouts, and trusts the self-signed certificates Server makes for local sites.
    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config, delegate: LocalTrust(), delegateQueue: nil)
    }()
}

private final class LocalTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        let local = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost") || host.hasSuffix(".test")
        if local, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
