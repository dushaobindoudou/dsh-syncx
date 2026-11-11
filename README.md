<div align="center">

# dsh-syncx

**Sync DeepSeek Harness (dsh) profiles to your own git repo — without leaking a single secret.**
Per-profile snapshots, automatic inline-secret redaction, AES-encrypted credentials,
and a hard gate that refuses to push while any plaintext secret remains.

[![npm](https://img.shields.io/npm/v/dsh-syncx?logo=npm&color=cb3837)](https://www.npmjs.com/package/dsh-syncx)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)](#requirements)
[![Node](https://img.shields.io/node/v/dsh-syncx?logo=nodedotjs&color=339933)](https://www.npmjs.com/package/dsh-syncx)

English · [简体中文](./README.zh-CN.md)

</div>

---

`dsh-syncx` backs up and restores every [dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)
profile — plugin dependency lists, bundle load orders, model routing and all
user settings — by carrying a handful of **declarative files** through a git
repo you control (GitHub, Gitea, a private server: any remote). dsh ships **no
built-in config sync**; this tool fills that gap with:

```
dsh-syncx push web        # export -> redact -> scan -> commit -> git push
dsh-syncx restore web     # clone elsewhere -> snapshot -> profile (secrets re-filled locally)
```

## ✨ What v0.3 adds

| Capability | Command | Notes |
|---|---|---|
| One-shot publish | `push [profile...]` | export + secret gate + commit + push, one line |
| Per-profile sync | `export acp`,`push web,acp`, `diff all` | sync only the profiles you name (`all` = every profile under `~/.dsh/profiles`) |
| Inline secret redaction | automatic on `export` | `token:`, `apiKey:`, passwords, keys inside `cordis.patch.yml` become `__REDACTED_<RULE>_<hash>__` |
| Pre-push gate | automatic on `push` | any high-severity plaintext secret in the repo blocks the push (`--allow-findings` overrides) |
| Faithful restore | automatic on `restore` | placeholders are re-filled from a local **encrypted** mapping, so the restored profile still works |
| History cleanup | `scrub-history --yes` | re-redacts snapshot files in every commit, expires reflogs, drops old objects |

## 📦 What gets synced

| State | Location | In repo as |
|---|---|---|
| Plugin deps + bundle load list | `~/.dsh/profiles/<name>/package.json` | plain |
| All user settings (models, theme, locale, plugin config) | `~/.dsh/profiles/<name>/cordis.patch.yml` | plain, **inline secrets redacted** |
| Locked versions | `pnpm-lock.yaml`, `pnpm-workspace.yaml` | plain |
| Model routing (`keyRef` env names only) | `~/.dsh/freeroute.json` | plain, redacted when needed |
| Model credentials (real API keys) | `~/.dsh/.credentials.yaml` | **AES-256-CBC `.enc`** + sha256 |
| `link:` plugin source paths | extracted from `package.json` | `links.manifest.json` |
| Redaction index (placeholder → secret) | `~/.config/dsh-syncx/redactions.json.enc` | **never committed** |

Not synced (session state, by design): `~/.dsh/sessions`, `~/.dsh/harness` agent memory.

## 🚀 Quick start

```bash
npm i -g dsh-syncx
cd ~/my-config-repo && git remote add origin git@github.com:<you>/dsh-syncx.git

dsh-syncx push all             # export + redact + scan + commit + push (the whole job)
dsh-syncx push web acp         # only these profiles
dsh-syncx diff all             # snapshot vs local, placeholders re-filled for a true comparison
dsh-syncx scan --snapshot      # what secret material sits where (report only)
dsh-syncx status               # profiles, redaction count, encryption, remote

# on the other machine
git clone git@github.com:<you>/dsh-syncx.git && cd dsh-syncx
dsh-syncx links                # every link: source present?
dsh-syncx restore-global       # ~/.dsh/freeroute.json + credentials (decrypted, 0600)
dsh-syncx restore web          # profile files, secrets re-filled from local mapping
cd ~/.dsh/profiles/web && pnpm install
```

## 🔐 Security model — three independent layers

1. **Credentials never land in plaintext.** Only `.credentials.yaml.enc` +
   sha256 is written; the key file is `~/.config/dsh-syncx/secret.key` (0600,
   local only, generated on first export).
2. **Inline secrets are redacted before commit.** The scanner knows token shapes
   (`sk-…`, `ghp_…`, `xoxb-…`, `AKIA…`, `AIza…`, JWTs, SSH/PEM blocks, 0x
   private keys, webhook URLs, Telegram bot tokens) *and* contextual keys
   (`token:`, `apiKey:`, `password:`, `secret:`, `passphrase:`, `webhook:` …),
   while ignoring env references (`DEEPSEEK_API_KEY`, `${VAR}`, `keyRef`,
   `apiKeyEnv`, `secretStore: keychain`, paths). Real values go to
   `redactions.json.enc` (same AES key, 0600, gitignored).
3. **Push is gated.** Before any commit, the whole repository is scanned again;
   a single high-severity hit aborts the push with the exact `file:line` and rule.

The repo can therefore leak in full — public even — without exposing an API key,
a bot token or a password. Restoring on **this** machine re-fills the redacted
values; restoring on a **new** machine needs two files moved by hand:
`secret.key` and `redactions.json.enc`.

## 🖥 Cross-machine workflow

1. **Old machine**: `dsh-syncx push all` (commit + push happen for you).
2. **New machine**: clone the repo, sync the `link:` source repos listed in
   `snapshot/links.manifest.json`, run `dsh-syncx links` until all OK.
3. Copy `~/.config/dsh-syncx/secret.key` **and** `redactions.json.enc` through
   your own secure channel (both are local-only, both are needed for a faithful restore).
4. `dsh-syncx restore-global && dsh-syncx restore web`, then `pnpm install` in each profile dir.

Two data modes are resolved automatically: inside a clone of the repo the
snapshot lives in that repo; a globally installed command defaults to
`~/.config/dsh-syncx/`. Override with `DSH_SYNC_DIR`, `DSH_SYNC_KEYFILE`,
`DSH_SYNC_REDACTIONS`, `DSH_HOME`, `DSH_SYNC_REMOTE`, `DSH_SYNC_BRANCH`.

## 🧰 Requirements

- bash + openssl (`pbkdf2`) — macOS and Linux stock toolchains
- python3 ≥ 3.7 — scanner/redactor (stdlib only, no pip installs)
- Node.js ≥ 18 for npm distribution
- git (only for `push` / `scrub-history`)

## ❓ FAQ

**Is this an official dsh plugin?** No — a standalone CLI over dsh's profile
directories. No cordis bundle, no host registration.

**Can I sync to a public repo?** v0.3 redacts inline secrets and gates the push,
so public is survivable — but your settings topology still describes which
models and services you use. Private remains the recommendation.

**A secret was already committed before redaction existed.** Run
`dsh-syncx scrub-history --yes`, then `git push --force-with-lease origin <branch>`.
The command writes a `backups/history-<ts>.bundle` first, so nothing is
unrecoverable locally.

**Multiple profiles?** `export`/`push`/`diff` accept any list:
`dsh-syncx push web acp headless`, or `all` (default).

## 🔗 The dsh plugin family

[dsh-bots](https://www.npmjs.com/package/dsh-bots) ·
[dsh-hyperliquid](https://www.npmjs.com/package/dsh-hyperliquid) ·
[dsh-plugin-security](https://www.npmjs.com/package/dsh-plugin-security) ·
[dsh-freeroute](https://www.npmjs.com/package/dsh-freeroute).
Browse all: `npm search dsh-plugin`.

## License

[MIT](./LICENSE)
