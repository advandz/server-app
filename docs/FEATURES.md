# Features

Server runs web, database and network services on your Mac using [Homebrew](https://brew.sh), under your own user account with its own config files. It never touches `brew services` or other setups such as MAMP.

## Websites

- Any number of sites, each on **Apache** or **Nginx**, with **PHP** or **Node.js**.
- Custom ports, SSL (self-signed or your own certificate), per-site Apache and Nginx overrides, and MySQL databases with a dedicated user each.
- Host names ending in `.localhost` work in browsers with no setup.
- Every config change is checked with `httpd -t` or `nginx -t` first. A bad edit is rejected and the running config stays in place.
- A new site starts with a welcome page.

## PHP and Node.js

- **PHP**: install and switch between versions, from the latest down to 5.6. Older ones come from the community tap `shivammathur/php`, and Server asks before adding it. Versions past PHP's security support are marked end of life, with a warning wherever you pick or use them.
- Per version: PECL extensions, common settings, the default command-line `php`, and Composer.
- **Node.js**: a wrapper for nvm. Install, uninstall and set the default version. A site can run its start command (default `npm start`) with the version you choose, and its web server proxies to it, WebSockets included.

## Services

| Service | What it does |
|---|---|
| **Apache, Nginx, MySQL** | Start, stop and restart, ports, basic settings, Apache modules and Nginx features |
| **Redis** | Settings, live statistics and a small console. Network access needs a password |
| **Object Caching** | Memcached: memory limit, port, network access, log level, live statistics and Flush Cache |
| **FTP** | Pure-FTPd with separate FTP users, each locked in its own folder |
| **DNS** | dnsmasq with wildcard local domains such as `*.test`, records and forwarding |
| **Mail** | SMTP through macOS's built-in Postfix and IMAP through Dovecot, with domains, accounts and aliases. A **Sandbox** option swaps the real SMTP server for Mailpit on the same port, to catch test mail |
| **SSH** | macOS Remote Login: who can log in, and your authorized keys |
| **File Sharing** | macOS SMB sharing: shared folders and guest access |
| **Screen Sharing** | macOS's built-in VNC server and Remote Management |
| **Content Caching** | macOS Content Caching: cache size and status |

## AI Models

An OpenAI-compatible API (`/v1/chat/completions`, `/v1/completions`, `/v1/models`) answered by Apple's on-device model through `afm-cli`, on port 8000 by default with an optional API key.

The same address serves a chat web app. People sign in with a Mac user name and password, and each has their own saved chats. With access from other devices on, sign-in is plain HTTP, so use it only on a network you trust.

## Cloudflare

Share a website, the AI chat or any address on this Mac through a Cloudflare quick tunnel. No account is needed, and `cloudflared` is installed automatically the first time you share.

- Each tunnel gets a random `trycloudflare.com` address that changes every time.
- Tunnels stop when Server quits.
- Over a tunnel, the AI API stays closed unless an API key is set, and sign-in attempts are rate limited.

## This Mac

The Server page shows the computer name and host name (both editable), macOS version, uptime, reachability with your public and local IP, storage per device, and components. **Network** lists every interface, **Firewall** manages app rules, and **Hosts** edits `/etc/hosts`.

**Logs** collects every server, PHP, website and Homebrew log in one place, with a live view, filter and Clear.

## Homebrew

Homebrew is installed automatically if it's missing. On every launch Server updates it and upgrades **only** the formulae it uses.

## Settings and updates

- **Settings** (⌘,): open Server at login, minimized or in full screen.
- **Automatic updates** come from this repository's releases.
- Available in English, Spanish, French, German, Italian, Portuguese (Brazil), Japanese, Korean and Chinese (Simplified).

## Where things live

| What | Path |
|---|---|
| Settings | `~/Library/Application Support/Server/config.json` |
| Generated configs | `~/Library/Application Support/Server/conf/` |
| Logs | `~/Library/Application Support/Server/logs/` |
| MySQL data, one folder per version | `~/Library/Application Support/Server/data/` |

Default ports: Apache 80 and 443, Nginx 8080 and 8443, MySQL 3306.

## Self-test

Runs Apache, Nginx, PHP-FPM and MySQL end to end on spare ports in a scratch folder:

```bash
SERVER_APP_SUPPORT=/tmp/srv-test SERVER_APP_RUN=/tmp/srv-run SELFTEST_MYSQL=mysql \
  build/Server.app/Contents/MacOS/Server --self-test
```

---

Copyright © 2026 Advandz Technologies, LLC. Released under the [MIT License](../LICENSE.md).
