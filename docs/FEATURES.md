# Server: features and details

A small macOS app (SwiftUI, Liquid Glass on macOS 26, falls back to materials on 14/15) that replaces the old
macOS Server app for local web development. It runs Apache, Nginx, PHP-FPM and MySQL from Homebrew, under your
own user account, with its own config files. It never touches `brew services` or other installs (MAMP etc).

No third-party Swift packages. Universal binary (Apple Silicon + Intel).

## Build

```bash
./build.sh            # → build/Server.app (arm64 + x86_64, ad-hoc signed)
```

## What it does

- **Homebrew**: installed automatically on first run if missing (official installer, non-interactive; if `sudo`
  needs a password, a macOS password dialog appears once). On every launch it runs `brew update` and upgrades
  **only** the formulae Server uses (`httpd`, `nginx`, the chosen MySQL, PHP versions used by websites).
- **Websites**: any number of sites, each with its own web server (Apache or Nginx), PHP version (`php`,
  `php@8.4`… installed on demand), ports, Apache/Nginx overrides, SSL (self-signed or custom), and MySQL databases
  with a dedicated user per database.
- **Apache / Nginx / MySQL** sidebar pages: status + start/stop/restart, default ports, basic settings,
  Apache modules / Nginx features.
- **SSH**: macOS Remote Login (built-in OpenSSH): turn it on or off, choose who can log in (all users, or
  administrators and chosen Mac users), see the `ssh` command and host key fingerprints, and manage your
  `~/.ssh/authorized_keys`. Like File Sharing, it's never turned off when Server quits.
- **Screen Sharing**: macOS's built-in VNC server: on/off, who can connect, a password for other VNC viewers,
  permission requests. Shows Remote Management (Apple Remote Desktop) and can turn it off; turning it on is done in
  System Settings.
- **DNS**: dnsmasq from Homebrew: wildcard local domains (e.g. `*.test` → 127.0.0.1, optionally used by this Mac
  through `/etc/resolver`), A/AAAA/CNAME/TXT/MX records, forwarding, and answering this Mac only or the network.
- **AI Models**: an OpenAI-compatible API (`/v1/chat/completions` with streaming and JSON schema, `/v1/completions`,
  `/v1/models`) answered by Apple's on-device Foundation Model through `afm-cli`. It runs as `Server --ai-server`,
  on port 8000 by default, with an optional API key. The same address also serves a ChatGPT-style **chat web app**
  (`/`): people sign in with a Mac user name and password (Open Directory) and each has their own saved chats
  (`ai-chats/<user>/` in Application Support). It follows the "accept requests from other devices" setting; with it
  on, sign-in is plain HTTP, so use it only on a trusted network. Sessions live in memory (a restart signs everyone
  out), failed sign-ins are rate limited, and the API key only applies to the `/v1` routes.
- **Redis**: Redis from Homebrew, run as your user with a generated config and data in `data/redis`. Settings
  (port, password, network access, memory limit and eviction policy, snapshots / append-only file), live statistics,
  and a small console. Network access requires a password.
- **Cloudflare**: share things on this Mac on the internet with Cloudflare quick tunnels (`cloudflared` from
  Homebrew, no account): any website (also from its **Share** tab), the AI chat (also from AI Models), or a saved
  custom address on this Mac such as a dev server. Each tunnel gets a random `trycloudflare.com` address that changes
  every time, shown as shared once it works. Tunnels stop when Server quits, and any left by a crash are stopped at the
  next launch. Over a tunnel, the AI server keeps the OpenAI-style API closed unless an API key is set, limits sign-in
  attempts per visitor and overall, and marks the session cookie Secure.
- **Node.js websites**: a site can use Node.js instead of PHP. Server runs its start command (default `npm start`)
  in the site folder with the chosen nvm version and `PORT`, while its web server runs, and Apache/Nginx proxy the
  host name to it (WebSockets included). Output goes to the site's log.
- **Node.js** page: an nvm wrapper (nvm from Homebrew, versions in `~/.nvm`): install LTS/current/any version,
  uninstall, set the default, and optionally load nvm in `~/.zshrc`.
- **Old PHP versions**: PHP 5.6, 7.0–7.4, 8.0 and 8.1 can be installed from the **PHP** page (Install Version) next to
  current releases. Homebrew's main repository only has current versions, so the older ones come from the community
  tap `shivammathur/php` (prebuilt packages of maintained backports); Server asks before adding it and never installs
  them silently. Versions past PHP's security support (dates from php.net) are marked end of life, with a warning
  wherever they're picked or used. A site can use any installed version; each runs in its own PHP-FPM pool.
- **PHP** page: per installed version — paths, PHP-FPM state, PECL extensions (install, on/off, uninstall),
  common settings (saved to `conf.d/zz-server.ini`, optionally for all versions), the default CLI `php`
  (`brew link`), and Composer (install, status, update through Homebrew).
- **This Mac**: computer name (editable; asks for an admin password), host name, macOS version, uptime,
  reachability with the public IP (looked up via ipify.org) and local IP, plus Storage and Components tabs.
- **Network**: every network service and active interface with its addresses, router, DNS, MAC, MTU and speed.
- **Logs**: every server, PHP and website log in one place (found by scanning the logs folder), plus the
  Homebrew activity log, with a live view, filter, Reveal in Finder and Clear.

Default ports: Apache 80/443, Nginx 8080/8443, MySQL 3306.
Host names ending in `.localhost` resolve to this Mac in browsers with no setup.

## Where things live

| What | Path |
|---|---|
| Settings | `~/Library/Application Support/Server/config.json` |
| Generated configs | `~/Library/Application Support/Server/conf/` |
| Logs | `~/Library/Application Support/Server/logs/` |
| MySQL data (one dir per version) | `~/Library/Application Support/Server/data/` |
| pid files and sockets | `/tmp/serverapp-<uid>/` |

Every config change is written to a staging file and checked with `httpd -t` / `nginx -t` first; a bad edit is
rejected and the running config stays in place.

## Logos

`Resources/Logos` holds the official project logos, used to identify each server in the sidebar (as one-color
marks) and on its page (full color on an icon tile). They're trademarks of their owners; check their guidelines
before distributing the app.

| File | Source |
|---|---|
| `apache.svg` | Apache feather, apache.org/foundation/press/kit/feather.svg (unchanged) |
| `nginx.svg` | nginx.org/img/nginx_logo.svg, view box cropped to the "N" hexagon |
| `mysql.svg` | labs.mysql.com/common/logos/mysql-logo.svg, wordmark paths removed to keep the dolphin |
| `redis.svg` | svgrepo.com/svg/303460/redis-logo (the classic Redis stack logo; SVG Repo "Logo" license, rights retained by the author), view box tightened |

## Self-test

Runs Apache, Nginx, PHP-FPM and MySQL end to end on spare ports in a scratch folder:

```bash
SERVER_APP_SUPPORT=/tmp/srv-test SERVER_APP_RUN=/tmp/srv-run SELFTEST_MYSQL=mysql \
  build/Server.app/Contents/MacOS/Server --self-test
```

---

Copyright © 2026 Advandz Technologies, LLC. Released under the [MIT License](../LICENSE.md).
