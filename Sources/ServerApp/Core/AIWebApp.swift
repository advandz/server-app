// Copyright © 2026 Advandz Technologies, LLC. Released under the MIT License (see LICENSE.md).
// SPDX-License-Identifier: MIT

import Foundation

/// The chat web app (HTML, CSS, JS) served by the AI server. Raw strings (#"""…"""#) keep the
/// backslashes in the JavaScript literal.
enum AIWebApp {
    static let icon = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#0d0d0d"/><path d="M32 14c-9.4 0-17 6.6-17 14.8 0 4.6 2.4 8.7 6.2 11.4-.3 2.3-1.3 4.6-3.2 6.8 3.6-.2 6.6-1.4 8.9-3.2 1.6.4 3.3.6 5.1.6 9.4 0 17-6.6 17-14.8S41.400 14 32 14z" fill="#fff"/></svg>
    """#

    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="color-scheme" content="light dark">
    <title>Chat</title>
    <link rel="icon" href="/favicon.svg" type="image/svg+xml">
    <link rel="stylesheet" href="/app.css">
    </head>
    <body>
    <section id="login" class="login" hidden>
      <form id="loginForm" class="card">
        <div class="logo"><svg viewBox="0 0 24 24" width="28" height="28" fill="currentColor"><path d="M12 3C7 3 3 6.500 3 11c0 2.400 1.200 4.500 3.200 6-.2 1.200-.7 2.400-1.700 3.500 1.900-.1 3.500-.7 4.700-1.700.9.200 1.800.3 2.800.3 5 0 9-3.500 9-8s-4-8-9-8z"/></svg></div>
        <h1>Sign in</h1>
        <p class="sub">Use your Mac user name and password.</p>
        <label>User name<input id="user" name="username" autocomplete="username" autocapitalize="none" autocorrect="off" spellcheck="false" required></label>
        <label>Password<input id="pass" name="password" type="password" autocomplete="current-password" required></label>
        <p id="loginError" class="error" role="alert" hidden></p>
        <button id="loginBtn" class="primary" type="submit">Continue</button>
      </form>
    </section>

    <div id="app" class="app" hidden>
      <aside id="sidebar" class="sidebar">
        <div class="side-top">
          <button id="newChat" class="new" type="button"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg><span>New chat</span></button>
        </div>
        <nav id="chatList" class="chat-list" aria-label="Chats"></nav>
        <div class="side-foot">
          <div class="who"><span id="avatar" class="avatar"></span><span id="whoName" class="who-name"></span></div>
          <button id="signOut" class="link" type="button">Sign out</button>
        </div>
      </aside>
      <div id="scrim" class="scrim" hidden></div>
      <main class="main">
        <header class="top">
          <button id="openSide" class="icon menu" type="button" aria-label="Open sidebar"><svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg></button>
          <div id="modelName" class="model"></div>
          <button id="newChat2" class="icon" type="button" aria-label="New chat"><svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.500 3.500a2.120 2.120 0 0 1 3 3L7 19l-4 1 1-4z"/></svg></button>
        </header>
        <div id="thread" class="thread"><div id="col" class="col"></div></div>
        <footer class="composer">
          <form id="form" class="box">
            <textarea id="input" rows="1" placeholder="Message the model" aria-label="Message"></textarea>
            <button id="send" class="send" type="submit" aria-label="Send message" disabled><svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.500" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg></button>
          </form>
          <p class="hint">Answered on this Mac by Apple Intelligence. It can make mistakes.</p>
        </footer>
      </main>
    </div>
    <div id="toast" class="toast" role="status" hidden></div>
    <script src="/app.js"></script>
    </body>
    </html>
    """#

    static let css = #"""
    :root{
      --bg:#fff; --fg:#0d0d0d; --muted:#6b6b6b; --side:#f9f9f9; --border:#e3e3e3; --hover:#ececec; --active:#e3e3e3;
      --bubble:#f4f4f4; --composer:#fff; --accent:#0d0d0d; --accent-fg:#fff; --code:#f6f6f6; --codehead:#ebebeb;
      --danger:#d1281c; --link:#0a63d6; --shadow:0 2px 14px rgba(0,0,0,.08); --scrim:rgba(0,0,0,.35);
      color-scheme:light dark;
    }
    @media (prefers-color-scheme: dark){
      :root{
        --bg:#212121; --fg:#ececec; --muted:#a3a3a3; --side:#171717; --border:#3a3a3a; --hover:#262626; --active:#303030;
        --bubble:#303030; --composer:#2f2f2f; --accent:#ececec; --accent-fg:#171717; --code:#171717; --codehead:#2b2b2b;
        --danger:#ff6b60; --link:#6cb2ff; --shadow:0 2px 14px rgba(0,0,0,.45); --scrim:rgba(0,0,0,.6);
      }
    }
    *{box-sizing:border-box}
    html,body{height:100%;margin:0}
    body{font:16px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--fg);-webkit-font-smoothing:antialiased}
    [hidden]{display:none!important}
    button{font:inherit;color:inherit;cursor:pointer;background:none;border:0;padding:0}
    input,textarea{font:inherit;color:inherit}

    /* Sign in */
    .login{min-height:100%;display:grid;place-items:center;padding:24px}
    .card{width:100%;max-width:360px;display:flex;flex-direction:column;gap:14px;text-align:center}
    .logo{width:52px;height:52px;border-radius:14px;background:var(--accent);color:var(--accent-fg);display:grid;place-items:center;margin:0 auto 4px}
    .card h1{margin:0;font-size:26px;font-weight:600}
    .sub{margin:0 0 6px;color:var(--muted)}
    .card label{display:flex;flex-direction:column;gap:6px;text-align:left;font-size:14px;color:var(--muted)}
    .card input{height:46px;border:1px solid var(--border);border-radius:12px;padding:0 14px;background:var(--composer);outline:none;font-size:16px}
    .card input:focus{border-color:var(--muted)}
    .primary{height:46px;border-radius:12px;background:var(--accent);color:var(--accent-fg);font-weight:600;margin-top:4px}
    .primary:disabled{opacity:.5;cursor:default}
    .error{margin:0;color:var(--danger);font-size:14px;text-align:left}

    /* Layout */
    .app{display:flex;height:100vh;height:100dvh}
    .sidebar{width:268px;flex:none;background:var(--side);display:flex;flex-direction:column;padding:10px 8px;gap:8px}
    .side-top{display:flex;gap:6px}
    .new{flex:1;display:flex;align-items:center;gap:10px;padding:9px 12px;border-radius:10px;font-weight:500}
    .new:hover,.icon:hover{background:var(--hover)}
    .chat-list{flex:1;overflow-y:auto;padding:4px 0}
    .group{padding:14px 12px 6px;font-size:12px;font-weight:600;color:var(--muted)}
    .empty{padding:12px;color:var(--muted);font-size:14px}
    .item{position:relative;display:flex;align-items:center;border-radius:10px}
    .item:hover{background:var(--hover)}
    .item.active{background:var(--active)}
    .item .title{flex:1;min-width:0;text-align:left;padding:8px 12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:15px}
    .item .act{display:none;width:28px;height:28px;margin-right:2px;border-radius:8px;color:var(--muted);align-items:center;justify-content:center}
    .item:hover .act,.item:focus-within .act{display:flex}
    .item .act:hover{color:var(--fg);background:var(--active)}
    .item.active .act{display:flex}
    .item .rename{flex:1;min-width:0;margin:3px 6px;padding:5px 8px;border:1px solid var(--muted);border-radius:8px;background:var(--bg);outline:none;font-size:15px}
    .side-foot{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:10px 8px 4px;border-top:1px solid var(--border)}
    .who{display:flex;align-items:center;gap:10px;min-width:0}
    .who-name{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:14px;font-weight:500}
    .avatar{flex:none;width:30px;height:30px;border-radius:50%;background:var(--accent);color:var(--accent-fg);display:grid;place-items:center;font-size:14px;font-weight:600}
    .link{color:var(--muted);font-size:13px;padding:4px 6px;border-radius:6px}
    .link:hover{color:var(--fg);background:var(--hover)}

    .main{flex:1;min-width:0;display:flex;flex-direction:column}
    .top{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:8px 12px;min-height:52px}
    .model{font-weight:600;color:var(--muted);font-size:15px}
    .icon{width:38px;height:38px;border-radius:10px;display:flex;align-items:center;justify-content:center;color:var(--muted)}
    .menu{display:none}
    .thread{flex:1;overflow-y:auto;scroll-behavior:smooth}
    .col{max-width:760px;margin:0 auto;padding:16px 20px 28px;display:flex;flex-direction:column;gap:22px;min-height:100%}
    .hero{margin:auto;text-align:center;font-size:28px;font-weight:600;padding:40px 0}

    /* Messages */
    .msg{display:flex;flex-direction:column}
    .msg.user{align-items:flex-end}
    .msg.user .body{background:var(--bubble);border-radius:20px;padding:10px 18px;max-width:82%;white-space:pre-wrap;overflow-wrap:anywhere}
    .msg.assistant .body{line-height:1.65;overflow-wrap:anywhere}
    .msg.assistant .body>:first-child{margin-top:0}
    .msg.assistant .body>:last-child{margin-bottom:0}
    .body p{margin:.7em 0}
    .body ul,.body ol{margin:.7em 0;padding-left:1.5em}
    .body li{margin:.25em 0}
    .body h3,.body h4,.body h5,.body h6{margin:1.1em 0 .4em;line-height:1.3}
    .body a{color:var(--link)}
    .body code{font:13.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:.15em .4em;border-radius:6px}
    .body pre{margin:.9em 0;background:var(--code);border-radius:12px;overflow:hidden}
    .body pre code{display:block;background:none;padding:14px 16px;overflow-x:auto;white-space:pre;border-radius:0}
    .codehead{display:flex;justify-content:space-between;align-items:center;background:var(--codehead);padding:6px 12px;font-size:12px;color:var(--muted)}
    .copycode{font-size:12px;color:var(--muted);padding:2px 6px;border-radius:6px}
    .copycode:hover{color:var(--fg)}
    .tools{display:flex;gap:4px;margin-top:6px;opacity:0;transition:opacity .15s}
    .msg:hover .tools,.msg:focus-within .tools{opacity:1}
    .tools button{width:30px;height:30px;border-radius:8px;color:var(--muted);display:flex;align-items:center;justify-content:center}
    .tools button:hover{background:var(--hover);color:var(--fg)}
    .dots{display:inline-flex;gap:5px;padding:8px 0}
    .dots i{width:8px;height:8px;border-radius:50%;background:var(--muted);animation:blink 1.2s infinite ease-in-out}
    .dots i:nth-child(2){animation-delay:.18s}
    .dots i:nth-child(3){animation-delay:.36s}
    @keyframes blink{0%,80%,100%{opacity:.25;transform:scale(.8)}40%{opacity:1;transform:scale(1)}}

    /* Composer */
    .composer{padding:0 16px calc(10px + env(safe-area-inset-bottom));background:var(--bg)}
    .box{max-width:760px;margin:0 auto;display:flex;align-items:flex-end;gap:8px;background:var(--composer);border:1px solid var(--border);border-radius:28px;padding:8px 8px 8px 20px;box-shadow:var(--shadow)}
    .box:focus-within{border-color:var(--muted)}
    .box textarea{flex:1;border:0;outline:0;background:none;resize:none;max-height:200px;padding:7px 0;line-height:1.5}
    .send{flex:none;width:38px;height:38px;border-radius:50%;background:var(--accent);color:var(--accent-fg);display:grid;place-items:center}
    .send:disabled{opacity:.25;cursor:default}
    .hint{max-width:760px;margin:8px auto 0;text-align:center;font-size:12px;color:var(--muted)}
    .toast{position:fixed;left:50%;top:16px;transform:translateX(-50%);max-width:min(560px,calc(100vw - 32px));background:var(--accent);color:var(--accent-fg);padding:10px 16px;border-radius:12px;box-shadow:var(--shadow);font-size:14px;z-index:30}

    /* Small screens: the sidebar slides over the chat */
    .scrim{position:fixed;inset:0;background:var(--scrim);z-index:10}
    @media (max-width:820px){
      .sidebar{position:fixed;inset:0 auto 0 0;z-index:20;transform:translateX(-100%);transition:transform .2s;width:min(300px,86vw)}
      .sidebar.open{transform:none}
      .menu{display:flex}
      .item .act{display:flex}
    }
    """#

    static let js = #"""
    'use strict';
    (() => {
      const $ = (id) => document.getElementById(id);
      const ICON = {
        edit: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
        trash: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"/></svg>',
        copy: '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/></svg>',
        check: '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12l5 5 9-10"/></svg>'
      };
      const state = { me: null, chats: [], id: null, messages: [], sending: false };

      function el(tag, cls, text) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text != null) e.textContent = text;
        return e;
      }
      function iconButton(name, label, cls, onClick) {
        const b = el('button', cls);
        b.type = 'button';
        b.innerHTML = ICON[name];
        b.setAttribute('aria-label', label);
        b.title = label;
        b.addEventListener('click', onClick);
        return b;
      }

      async function api(method, path, body) {
        const res = await fetch(path, {
          method,
          headers: body ? { 'Content-Type': 'application/json' } : {},
          body: body ? JSON.stringify(body) : undefined,
          credentials: 'same-origin'
        });
        let data = null;
        try { data = await res.json(); } catch (e) { /* no body */ }
        if (res.status === 401 && path !== '/api/login') { showLogin(); throw new Error('Signed out'); }
        if (!res.ok) throw new Error((data && data.error) || 'Request failed (' + res.status + ')');
        return data;
      }

      let toastTimer = null;
      function toast(message) {
        const t = $('toast');
        t.textContent = message;
        t.hidden = false;
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => { t.hidden = true; }, 7000);
      }

      function copyText(text) {
        if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
        return new Promise((resolve, reject) => {
          const ta = el('textarea');
          ta.value = text;
          ta.setAttribute('readonly', '');
          ta.style.position = 'fixed';
          ta.style.opacity = '0';
          document.body.appendChild(ta);
          ta.select();
          const ok = document.execCommand('copy');
          ta.remove();
          ok ? resolve() : reject(new Error('Copy failed'));
        });
      }

      /* ---------- Markdown (escaped; model text is never inserted as HTML) ---------- */
      function esc(s) {
        return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
      }
      function inline(s) {
        return s.split(/(`[^`\n]+`)/).map((part) => {
          if (part.length > 1 && part[0] === '`' && part[part.length - 1] === '`') return '<code>' + esc(part.slice(1, -1)) + '</code>';
          let t = esc(part);
          t = t.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (m, label, url) => '<a href="' + url + '" target="_blank" rel="noopener noreferrer">' + label + '</a>');
          t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
          t = t.replace(/(^|[^*\w])\*([^*\n]+)\*/g, '$1<em>$2</em>');
          return t;
        }).join('');
      }
      function blocks(text) {
        const html = [];
        let para = [];
        let list = null;
        const flushPara = () => { if (para.length) { html.push('<p>' + para.map(inline).join('<br>') + '</p>'); para = []; } };
        const flushList = () => {
          if (list) { html.push('<' + list.tag + '>' + list.items.map((i) => '<li>' + inline(i) + '</li>').join('') + '</' + list.tag + '>'); list = null; }
        };
        for (const line of text.split('\n')) {
          let m;
          if (!line.trim()) { flushPara(); flushList(); continue; }
          if ((m = line.match(/^(#{1,4})\s+(.*)$/))) {
            flushPara(); flushList();
            const level = m[1].length + 2;
            html.push('<h' + level + '>' + inline(m[2]) + '</h' + level + '>');
          } else if ((m = line.match(/^\s*[-*+]\s+(.*)$/))) {
            flushPara();
            if (!list || list.tag !== 'ul') { flushList(); list = { tag: 'ul', items: [] }; }
            list.items.push(m[1]);
          } else if ((m = line.match(/^\s*\d+[.)]\s+(.*)$/))) {
            flushPara();
            if (!list || list.tag !== 'ol') { flushList(); list = { tag: 'ol', items: [] }; }
            list.items.push(m[1]);
          } else {
            flushList();
            para.push(line);
          }
        }
        flushPara(); flushList();
        return html.join('');
      }
      function markdown(text) {
        const out = [];
        const fence = /```([\w+-]*)[ \t]*\n?([\s\S]*?)(?:```|$)/g;
        let last = 0, m;
        while ((m = fence.exec(text)) !== null) {
          out.push(blocks(text.slice(last, m.index)));
          out.push('<pre data-lang="' + esc(m[1]) + '"><code>' + esc(m[2].replace(/\n$/, '')) + '</code></pre>');
          last = fence.lastIndex;
          if (m[0].length === 0) fence.lastIndex++;
        }
        out.push(blocks(text.slice(last)));
        return out.join('');
      }
      function decorate(root) {
        root.querySelectorAll('pre').forEach((pre) => {
          const head = el('div', 'codehead');
          head.appendChild(el('span', 'lang', pre.dataset.lang || 'code'));
          const btn = el('button', 'copycode', 'Copy');
          btn.type = 'button';
          btn.addEventListener('click', () => {
            copyText(pre.querySelector('code').textContent).then(() => {
              btn.textContent = 'Copied';
              setTimeout(() => { btn.textContent = 'Copy'; }, 1500);
            }).catch(() => toast('Couldn’t copy'));
          });
          head.appendChild(btn);
          pre.insertBefore(head, pre.firstChild);
        });
      }

      /* ---------- Sign in ---------- */
      function showLogin() {
        $('app').hidden = true;
        $('login').hidden = false;
        $('user').focus();
      }
      async function enter() {
        $('login').hidden = true;
        $('app').hidden = false;
        const name = state.me.name || state.me.user;
        $('whoName').textContent = name;
        $('avatar').textContent = (name[0] || '?').toUpperCase();
        $('modelName').textContent = 'Apple Intelligence';
        document.title = 'Chat';
        await loadChats();
        newChat();
      }
      $('loginForm').addEventListener('submit', async (e) => {
        e.preventDefault();
        const btn = $('loginBtn'), err = $('loginError');
        btn.disabled = true;
        err.hidden = true;
        try {
          state.me = await api('POST', '/api/login', { username: $('user').value.trim(), password: $('pass').value });
          $('pass').value = '';
          await enter();
        } catch (ex) {
          err.textContent = ex.message;
          err.hidden = false;
          $('pass').select();
        } finally {
          btn.disabled = false;
        }
      });
      $('signOut').addEventListener('click', async () => {
        try { await api('POST', '/api/logout'); } catch (e) { /* already signed out */ }
        state.me = null; state.chats = []; state.id = null; state.messages = [];
        $('col').textContent = '';
        $('chatList').textContent = '';
        showLogin();
      });

      /* ---------- Sidebar ---------- */
      function groupOf(iso) {
        const t = new Date(iso).getTime();
        const now = new Date();
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
        const day = 86400000;
        if (t >= today) return 'Today';
        if (today - t <= day) return 'Yesterday';
        if (today - t <= 7 * day) return 'Previous 7 days';
        if (today - t <= 30 * day) return 'Previous 30 days';
        return 'Older';
      }
      function renderSidebar() {
        const list = $('chatList');
        list.textContent = '';
        let group = null;
        for (const c of state.chats) {
          const g = groupOf(c.updated);
          if (g !== group) { list.appendChild(el('div', 'group', g)); group = g; }
          list.appendChild(chatItem(c));
        }
        if (!state.chats.length) list.appendChild(el('div', 'empty', 'No chats yet'));
      }
      function chatItem(c) {
        const row = el('div', 'item' + (c.id === state.id ? ' active' : ''));
        const open = el('button', 'title', c.title);
        open.type = 'button';
        open.addEventListener('click', () => openChat(c.id));
        row.append(open,
          iconButton('edit', 'Rename chat', 'act', () => rename(c, row)),
          iconButton('trash', 'Delete chat', 'act', () => remove(c)));
        return row;
      }
      function rename(c, row) {
        const title = row.querySelector('.title');
        const input = el('input', 'rename');
        input.value = c.title;
        input.maxLength = 80;
        row.replaceChild(input, title);
        input.focus();
        input.select();
        let done = false;
        const finish = async (save) => {
          if (done) return;
          done = true;
          const v = input.value.trim();
          if (save && v && v !== c.title) {
            try { c.title = (await api('PATCH', '/api/chats/' + c.id, { title: v })).title; } catch (e) { toast(e.message); }
          }
          renderSidebar();
        };
        input.addEventListener('keydown', (e) => { if (e.key === 'Enter') finish(true); else if (e.key === 'Escape') finish(false); });
        input.addEventListener('blur', () => finish(true));
      }
      async function remove(c) {
        if (!confirm('Delete “' + c.title + '”? This can’t be undone.')) return;
        try {
          await api('DELETE', '/api/chats/' + c.id);
          state.chats = state.chats.filter((x) => x.id !== c.id);
          if (state.id === c.id) newChat(); else renderSidebar();
        } catch (e) { toast(e.message); }
      }
      async function loadChats() {
        state.chats = (await api('GET', '/api/chats')).chats;
        renderSidebar();
      }
      function setSidebar(open) {
        $('sidebar').classList.toggle('open', open);
        $('scrim').hidden = !open;
      }
      $('openSide').addEventListener('click', () => setSidebar(true));
      $('scrim').addEventListener('click', () => setSidebar(false));

      /* ---------- Thread ---------- */
      function scrollDown() { const t = $('thread'); t.scrollTop = t.scrollHeight; }
      function messageEl(m) {
        const row = el('div', 'msg ' + m.role);
        const body = el('div', 'body');
        if (m.role === 'user') {
          body.textContent = m.content;
        } else {
          body.innerHTML = markdown(m.content);
          decorate(body);
        }
        row.appendChild(body);
        if (m.role === 'assistant') {
          const tools = el('div', 'tools');
          const btn = iconButton('copy', 'Copy reply', '', () => {
            copyText(m.content).then(() => {
              btn.innerHTML = ICON.check;
              setTimeout(() => { btn.innerHTML = ICON.copy; }, 1500);
            }).catch(() => toast('Couldn’t copy'));
          });
          tools.appendChild(btn);
          row.appendChild(tools);
        }
        return row;
      }
      function thinkingEl() {
        const row = el('div', 'msg assistant');
        const body = el('div', 'body');
        const dots = el('span', 'dots');
        dots.append(el('i'), el('i'), el('i'));
        dots.setAttribute('aria-label', 'Thinking');
        body.appendChild(dots);
        row.appendChild(body);
        return row;
      }
      function renderThread() {
        const col = $('col');
        col.textContent = '';
        if (!state.messages.length) {
          const name = (state.me && (state.me.name || state.me.user) || '').split(' ')[0];
          col.appendChild(el('div', 'hero', name ? 'How can I help, ' + name + '?' : 'How can I help?'));
        } else {
          for (const m of state.messages) col.appendChild(messageEl(m));
        }
        scrollDown();
      }
      function newChat() {
        state.id = null;
        state.messages = [];
        renderThread();
        renderSidebar();
        setSidebar(false);
        $('input').focus();
      }
      async function openChat(id) {
        if (state.sending) return;
        try {
          const chat = await api('GET', '/api/chats/' + id);
          state.id = chat.id;
          state.messages = chat.messages;
          renderThread();
          renderSidebar();
          setSidebar(false);
        } catch (e) { toast(e.message); }
      }
      $('newChat').addEventListener('click', () => { if (!state.sending) newChat(); });
      $('newChat2').addEventListener('click', () => { if (!state.sending) newChat(); });

      /* ---------- Composer ---------- */
      const input = $('input');
      function autosize() {
        input.style.height = 'auto';
        input.style.height = Math.min(input.scrollHeight, 200) + 'px';
      }
      function refreshSend() { $('send').disabled = state.sending || !input.value.trim(); }
      input.addEventListener('input', () => { autosize(); refreshSend(); });
      input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); $('form').requestSubmit(); }
      });
      $('form').addEventListener('submit', (e) => { e.preventDefault(); send(); });

      async function send() {
        const text = input.value.trim();
        if (!text || state.sending) return;
        state.sending = true;
        input.value = '';
        autosize();
        refreshSend();
        const col = $('col');
        if (!state.messages.length) col.textContent = '';
        const question = { role: 'user', content: text };
        state.messages.push(question);
        const questionEl = messageEl(question);
        col.appendChild(questionEl);
        const pending = thinkingEl();
        col.appendChild(pending);
        scrollDown();
        try {
          if (!state.id) {
            const chat = await api('POST', '/api/chats');
            state.id = chat.id;
            state.chats.unshift({ id: chat.id, title: chat.title, updated: chat.updated });
          }
          const reply = await api('POST', '/api/chats/' + state.id + '/messages', { content: text });
          pending.remove();
          state.messages.push(reply.message);
          col.appendChild(messageEl(reply.message));
          state.chats = [reply.chat].concat(state.chats.filter((c) => c.id !== reply.chat.id));
          renderSidebar();
        } catch (e) {
          pending.remove();
          questionEl.remove();
          state.messages.pop();
          if (!state.messages.length) renderThread();
          input.value = text;
          autosize();
          if (e.message !== 'Signed out') toast(e.message);
        } finally {
          state.sending = false;
          refreshSend();
          scrollDown();
          input.focus();
        }
      }

      (async () => {
        try { state.me = await api('GET', '/api/me'); await enter(); } catch (e) { showLogin(); }
      })();
    })();
    """#
}
