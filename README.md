<div align="center">

# dsh-syncx

**Sync DeepSeek Harness (dsh) profiles across machines** —
plugins & settings as declarative snapshots in git, with model credentials
AES-encrypted by a local-only key.

[![npm](https://img.shields.io/npm/v/dsh-syncx?logo=npm&color=cb3837)](https://www.npmjs.com/package/dsh-syncx)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)](#requirements)
[![Node](https://img.shields.io/node/v/dsh-syncx?logo=nodedotjs&color=339933)](https://www.npmjs.com/package/dsh-syncx)

English · [简体中文](./README.zh-CN.md)

</div>

---

`dsh-syncx` backs up and restores every [dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)
profile — plugin dependency lists, bundle load orders, model routing and all
user settings — by carrying a handful of **declarative files** through a private
git repo. dsh ships **no built-in config sync** (no sync/export/import command
in its CLI); this tool fills that gap with a snapshot → push → clone → restore
workflow that makes a fresh machine production-ready in minutes.

## ✨ Why it works

dsh profiles are already declarative — one `package.json` (plugin deps + bundle
load list), one `cordis.patch.yml` (every user setting), plus lockfiles. So
syncing is just: **capture those files, replay them with `pnpm install`**. What
this tool adds:

- **One command** per direction: `export` / `restore`, with `diff` to detect drift
- **Encrypted credentials**: real API keys never touch git — only AES-256-CBC
  ciphertext, decryptable only with a key file that lives on your machine
- **`link:` awareness**: dsh profiles load local plugin sources via `link:` deps;
  the snapshot records every source path and `links` verifies them on the target
- **Auto-backup**: every restore stashes the current state to `backups/` first

## 📦 What gets synced

| State | Location | In repo as |
|---|---|---|
| Plugin deps + bundle load list | `~/.dsh/profiles/<name>/package.json` | plain |
| All user settings (models, theme, locale, plugin config) | `~/.dsh/profiles/<name>/cordis.patch.yml` | plain |
| Locked versions | `pnpm-lock.yaml`, `pnpm-workspace.yaml` | plain |
| Model routing (contains `keyRef` names only — no secrets) | `~/.dsh/freeroute.json` | plain |
| Model credentials (real API keys) | `~/.dsh/.credentials.yaml` | **AES-256-CBC `.enc`** + sha256 |
| `link:` plugin source paths | extracted from `package.json` | `links.manifest.json` |

Not synced (session state, by design): `~/.dsh/sessions`, `~/.dsh/harness` agent memory.

## 🚀 Quick start

```bash
npm i -g dsh-syncx

dsh-syncx export          # machine ~/.dsh -> snapshot/ (credentials auto-encrypted)
dsh-syncx diff web        # compare snapshot vs local (profile + global, credentials by sha256)
dsh-syncx restore web     # snapshot -> web profile (auto-backs-up current state)
dsh-syncx restore-global  # snapshot -> ~/.dsh (freeroute.json + decrypt credentials back)
dsh-syncx links           # verify link: plugin source dirs exist on this machine
dsh-syncx status          # overview (encryption state, checksum)
```

## 🔐 Security model

- The encryption key lives **only on your machine**
  (`~/.config/dsh-syncx/secret.key`, `0600`, generated on first `export`, never committed).
- The repo can leak in full without exposing a single API key — the ciphertext
  is useless without the local key file. Losing the key file loses the
  credentials snapshot, so back the key up in your own secret store.
- Plaintext credentials never touch the snapshot directory or git history
  (enforced by the script writing only `.enc`, plus `.gitignore`).
- `cordis.patch.yml` may contain a local ACP token — valid only for
  `127.0.0.1:<port>` on the same machine, useless remotely.

## 🖥 Cross-machine workflow

1. **Old machine**: `dsh-syncx export`, commit & push this repo (private recommended).
2. **New machine**: clone the repo, sync the `link:` source repos listed in
   `snapshot/links.manifest.json`, then `dsh-syncx links` until all OK.
3. Transfer `~/.config/dsh-syncx/secret.key` through your own secure channel.
4. `dsh-syncx restore-global && dsh-syncx restore web`, then in each profile dir: `pnpm install`.

Two data modes are supported automatically: running inside a clone of this repo
uses the repo's `snapshot/`; running the globally-installed command uses
`~/.config/dsh-syncx/`. Override both with `DSH_SYNC_DIR`; override the key file
with `DSH_SYNC_KEYFILE` and the dsh home with `DSH_HOME`.

## 🧰 Requirements

- bash + openssl (`pbkdf2` support) — macOS and Linux stock toolchains
- Node.js ≥ 18 (for npm distribution)
- python3 (only for the `links` manifest generation/verification)

## ❓ FAQ

**Is this an official dsh plugin?**
No — it's a standalone CLI that operates on dsh's profile directories. It needs
no cordis bundle, no host registration; it just reads and writes the
declarative files dsh already defines.

**Can I sync to a public repo?**
Technically yes for everything except the credentials blob — but the repo also
carries your full settings topology (which models you use where). Private is
recommended; if you go public, keep `snapshot/global/` out of git.

**Multiple profiles?**
The snapshot carries every profile found under `~/.dsh/profiles`; restore
per-profile with `dsh-syncx restore <name>`.

## 🔗 The dsh plugin family

More tools for DeepSeek Harness by the same author:
[dsh-bots](https://www.npmjs.com/package/dsh-bots) (multi-bot workbench) ·
[dsh-hyperliquid](https://www.npmjs.com/package/dsh-hyperliquid) (Hyperliquid
trading desk) · [dsh-plugin-security](https://www.npmjs.com/package/dsh-plugin-security)
(plugin security gate) · [dsh-freeroute](https://www.npmjs.com/package/dsh-freeroute)
(model routing). Browse all: `npm search dsh-plugin`.

## License

[MIT](./LICENSE)
