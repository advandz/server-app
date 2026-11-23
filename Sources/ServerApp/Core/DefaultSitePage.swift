// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// The welcome page a new website starts with: a card with the site's name and a few facts about
/// how it's served, in the style of the old macOS Server welcome page.
enum DefaultSitePage {
    /// Where the running language's version goes ("PHP 8.5.1", "Node.js v22.1.0"). The PHP and Node
    /// starter files fill it in themselves, so it's always the version that is really running.
    static let runtimeToken = "{{RUNTIME}}"

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// - Parameter runtimeText: "PHP", "Node.js" or "Static files", shown as the third item's title.
    static func html(name: String, hostname: String, root: String, server: WebServer, runtimeText: String, runtimeDetail: String) -> String {
        let n = escape(name), h = escape(hostname), r = escape(root)
        func icon(_ color: String, _ glyph: String) -> String {
            """
            <svg viewBox="0 0 40 40" width="40" height="40" aria-hidden="true"><circle cx="20" cy="20" r="20" fill="\(color)"/>\
            <g fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\(glyph)</g></svg>
            """
        }
        let folder = icon("#3b82f6", #"<path d="M10 14h7l2 3h11v10H10z"/>"#)
        let serverIcon = icon("#8b5cf6", #"<rect x="10" y="12" width="20" height="7" rx="2"/><rect x="10" y="21" width="20" height="7" rx="2"/><path d="M14 15.5h.01M14 24.5h.01"/>"#)
        let code = icon("#f97316", #"<path d="M17 14l-6 6 6 6M23 14l6 6-6 6"/>"#)
        let gear = icon("#64748b", #"<circle cx="20" cy="20" r="4"/><path d="M20 10v3M20 27v3M10 20h3M27 20h3M13 13l2 2M25 25l2 2M13 27l2-2M25 15l2-2"/>"#)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(n)</title>
        <style>
        :root { color-scheme: light dark; --bg: #e9ebee; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #e2e2e5; --shadow: 0 1px 3px rgba(0,0,0,.12); }
        @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --card: #2a2a2d; --text: #f5f5f7; --muted: #98989d; --line: #3d3d41; --shadow: 0 1px 3px rgba(0,0,0,.5); } }
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 32px 16px; background: var(--bg); color: var(--text);
               font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }
        .card { width: 100%; max-width: 640px; background: var(--card); border-radius: 6px; box-shadow: var(--shadow); padding: 44px 48px 40px; }
        .globe { display: block; margin: 0 auto 22px; }
        h1 { margin: 0 0 10px; text-align: center; font-size: 30px; font-weight: 300; letter-spacing: -.01em; }
        .lead { margin: 0 auto 28px; max-width: 460px; text-align: center; color: var(--muted); font-size: 14px; }
        hr { border: 0; border-top: 1px solid var(--line); margin: 0 0 26px; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 26px 32px; }
        .item { display: flex; gap: 12px; align-items: flex-start; }
        .item svg { flex: none; }
        .item h2 { margin: 0 0 2px; font-size: 16px; font-weight: 400; }
        .item p { margin: 0; color: var(--muted); font-size: 12.5px; overflow-wrap: anywhere; }
        code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
        @media (max-width: 560px) { .card { padding: 32px 24px; } .grid { grid-template-columns: 1fr; } }
        </style>
        </head>
        <body>
        <main class="card">
        <svg class="globe" viewBox="0 0 120 120" width="112" height="112" aria-hidden="true">
          <defs><radialGradient id="g" cx="35%" cy="30%" r="80%"><stop offset="0" stop-color="#7cc4ff"/><stop offset=".55" stop-color="#2f80ed"/><stop offset="1" stop-color="#143f9a"/></radialGradient></defs>
          <circle cx="60" cy="60" r="56" fill="url(#g)"/>
          <g fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="2.2">
            <ellipse cx="60" cy="60" rx="24" ry="56"/><ellipse cx="60" cy="60" rx="46" ry="56" stroke-opacity=".3"/>
            <path d="M6 60h108M14 36h92M14 84h92"/></g>
          <g fill="#fff"><circle cx="40" cy="38" r="4.5"/><circle cx="78" cy="58" r="4.5"/><circle cx="52" cy="82" r="4.5"/></g>
        </svg>
        <h1>Welcome to \(n)</h1>
        <p class="lead">This website is up and running. Replace this page by adding your own index file to the website's folder.</p>
        <hr>
        <div class="grid">
          <div class="item">\(folder)<div><h2>Document Root</h2><p>Put your files in <code>\(r)</code>.</p></div></div>
          <div class="item">\(serverIcon)<div><h2>\(server.title)</h2><p>Serves this website at <code>\(h)</code>.</p></div></div>
          <div class="item">\(code)<div><h2>\(escape(runtimeText))</h2><p>\(runtimeDetail)</p></div></div>
          <div class="item">\(gear)<div><h2>Server</h2><p>Change this website's settings, SSL and databases in the Server app.</p></div></div>
        </div>
        </main>
        </body>
        </html>

        """
    }
}
