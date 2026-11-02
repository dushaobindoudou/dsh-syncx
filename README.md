# dsh-profiles-sync

Sync [DeepSeek Harness (dsh)](https://www.npmjs.com/package/@deepseek-ai/dsh) profile plugins and settings across machines or profiles.

dsh ships **no built-in config sync** (no sync/export/import command in the CLI). But every profile's full state is declarative, so syncing = carrying a handful of files + one `pnpm install`.

## What gets synced

| State | Location | In repo as |
|---|---|---|
| Plugin deps + bundle load list | `~/.dsh/profiles/<name>/package.json` (`dependencies` + `dsh.profile.bundles`) | plain |
| All user settings (models, theme, locale, plugin config) | `~/.dsh/profiles/<name>/cordis.patch.yml` | plain |
| Locked versions | `pnpm-lock.yaml`, `pnpm-workspace.yaml` | plain |
| Model routing (contains `keyRef` names only, no secrets) | `~/.dsh/freeroute.json` | plain |
| Model credentials (real API keys) | `~/.dsh/.credentials.yaml` | **AES-256-CBC encrypted** (`.enc`) + sha256 for diff |

`cordis.patch.yml` may contain a local ACP token — it is only valid for `127.0.0.1:<port>` on the same machine and cannot be used remotely.

## Security model

- The encryption key lives **only on your machine** (`~/.config/dsh-profiles-sync/secret.key`, 0600, generated on first `export`, never committed).
- The repo can leak in full without exposing a single API key — the ciphertext is useless without the local key file.
- Losing the key file means losing the credentials snapshot; back it up in your own secret store.
- Plaintext credentials never touch the snapshot directory or git history (enforced by `.gitignore` + the script writing only `.enc`).

## Usage

```bash
npm i -g dsh-profiles-sync

dsh-profiles-sync export          # machine ~/.dsh -> snapshot/ (credentials auto-encrypted)
dsh-profiles-sync diff web        # compare snapshot vs local (profile + global, credentials by sha256)
dsh-profiles-sync restore web     # snapshot -> web profile (auto-backs-up current state)
dsh-profiles-sync restore-global  # snapshot -> ~/.dsh (freeroute.json + decrypt credentials back)
dsh-profiles-sync links           # verify link: plugin source dirs exist on this machine
dsh-profiles-sync status          # overview (encryption state, checksum)
```

Override targets with `DSH_HOME` and the key file with `DSH_SYNC_KEYFILE`. Requires bash + openssl (macOS/Linux).

## Cross-machine workflow

1. On the old machine: `dsh-profiles-sync export`, commit & push this repo (private recommended).
2. On the new machine: clone the repo, sync the `link:` source repos (see `snapshot/links.manifest.json`), then `dsh-profiles-sync links` until all OK.
3. Transfer the key file (`~/.config/dsh-profiles-sync/secret.key`) through your own secure channel.
4. `dsh-profiles-sync restore-global && dsh-profiles-sync restore web`, then in each profile dir: `pnpm install`.

`~/.dsh/sessions` (chat history) and `~/.dsh/harness` (agent memory) are session state, not config — intentionally out of scope.

## License

MIT
