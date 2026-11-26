<p align="center">
  <img src="Support/AppIcon.png" width="128" height="128" alt="Server app icon">
</p>

<h1 align="center">Server</h1>

<p align="center">A native macOS app that replaces macOS Server, running websites, databases, DNS, FTP and more through Homebrew.</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
    <img src="docs/screenshot-light.png" width="760" alt="Server's overview page: this Mac's details, reachability and services">
  </picture>
</p>

## Features

- **Websites** on Apache or Nginx, with PHP (5.6 to the latest 8.x) or Node.js, SSL and MySQL databases
- **Services**: Apache, Nginx, MySQL, Redis, Object Caching (Memcached), FTP, DNS, Mail, SSH, File Sharing, Screen Sharing and Content Caching
- **Certificates**: trusted local HTTPS for your sites, and for the AI server and chat
- **Mail**: SMTP and IMAP with domains, accounts and aliases, plus a Sandbox that catches test mail
- **AI Models**: an OpenAI-compatible server and chat web app using Apple's on-device model
- **Cloudflare** quick tunnels to share a website or the chat on the internet
- Network, Firewall, Hosts, Storage and central Logs, with options to keep FTP and the web servers to this Mac only
- Installs and updates Homebrew and the formulae it uses on its own
- **Automatic updates** from this repository's releases
- In English, Spanish, French, German, Italian, Portuguese (Brazil), Japanese, Korean and Chinese (Simplified), following your Mac's language

See [docs/FEATURES.md](docs/FEATURES.md) for the details.

## Install

Download the latest `Server-x.y.z.dmg` from [Releases](https://github.com/advandz/server-app/releases), open it and drag **Server** to **Applications**.

Runs natively on Apple silicon and Intel. It isn't notarized, so if macOS can't verify it, choose **Open Anyway** in **System Settings → Privacy & Security**.

## macOS Gatekeeper

Server isn't notarized by Apple, so macOS Gatekeeper may stop it the first time you open it. You may see a message such as:

- “Server” is damaged and can't be opened. You should move it to the Trash.
- “Server” can't be opened because Apple cannot check it for malicious software.
- “Server” is not safe to open.

The download isn't corrupt. macOS marks every app downloaded from the internet as quarantined, and Gatekeeper blocks quarantined apps that aren't notarized.

**To open it**

1. Drag **Server** to **Applications**, then open it. When macOS blocks it, click **Done** (not **Move to Trash**).
2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
3. Next to the message about Server, click **Open Anyway**, then confirm with your password or Touch ID.

**If it says the app is damaged**

That message has no **Open Anyway** button. Remove the quarantine flag in Terminal, then open the app normally:

```bash
xattr -dr com.apple.quarantine "/Applications/Server.app"
```

If the app isn't in **Applications**, use its actual path. Only do this for a copy you downloaded from this repository's [Releases](https://github.com/advandz/server-app/releases) page.

## Build from source

```bash
./build.sh    # builds build/Server.app and build/Server-<version>.dmg
```

## Release

Updates are signed: the app only installs a disk image whose signature matches the public key built into it (`Sources/ServerApp/Core/UpdateSigning.swift`), so a forged or tampered download is rejected.

1. One time: `swift Tools/sign-update.swift keygen` creates the private key in `~/.com.advandz.server/` (outside this repository) and prints the public key to put in `UpdateSigning.swift`. Back the key up and never commit it. Losing it means existing installs can't be updated automatically.
2. Set `VERSION` in `build.sh`.
3. Run `./build.sh`. It builds the app and DMG and signs the DMG, writing `build/Server-<version>.dmg.sig`.
4. Tag and publish, attaching **both** files:

   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   gh release create v1.0.0 build/Server-1.0.0.dmg build/Server-1.0.0.dmg.sig --title "Server 1.0.0"
   ```

The app finds the newest version tag and offers to install the DMG attached to its release, after checking its signature. A release without the `.sig` file isn't installed automatically; the app sends people to the release page instead.

## License

Copyright © 2026 Advandz Technologies, LLC. Released under the [MIT License](LICENSE.md).
