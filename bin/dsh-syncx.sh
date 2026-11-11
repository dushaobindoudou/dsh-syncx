#!/usr/bin/env bash
# dsh-syncx —— DeepSeek Harness (dsh) profile 插件与设置同步（v0.3.0）
#
# 一个 dsh profile 的全部状态由声明式文件构成：
#   profiles/<name>/package.json        插件依赖 + dsh.profile.bundles 装载清单
#   profiles/<name>/cordis.patch.yml    全部用户设置（模型、主题、语言、插件配置）
#   profiles/<name>/pnpm-workspace.yaml / pnpm-lock.yaml
# 全局层：
#   ~/.dsh/freeroute.json               模型路由（仅 keyRef 引用名）
#   ~/.dsh/.credentials.yaml            模型凭证（AES-256 加密后入仓）
#
# 安全模型（三层，缺一不可）：
#   1. 明文凭证永不落快照：.credentials.yaml 只以 .enc 形态入仓；
#   2. 配置里的内联密钥/令牌（cordis.patch.yml 的 token、apiKey、密码……）在
#      export 时自动扫描并替换为 __REDACTED_<RULE>_<hash>__ 占位符，
#      真实值只写进本机加密映射表（redactions.json.enc，永不入 git）；
#   3. push 前对整个仓库再扫一遍，有高危发现就直接拒绝推送（--allow-findings 可拦不住强制）。
#   加密密钥：$DSH_SYNC_KEYFILE（默认 ~/.config/dsh-syncx/secret.key，0600，永不入 git）。
#
# 用法:
#   dsh-syncx export [profile...|all]     本机 -> snapshot/（自动脱敏 + 凭证加密）
#   dsh-syncx push   [profile...|all]     export + 扫描 + commit + git push（一条命令发到 GitHub）
#   dsh-syncx diff   [profile...|all]     对比快照与本机（占位符按本机映射还原后比较）
#   dsh-syncx restore <profile>           快照 -> profile（自动备份 + 本机密钥回填）
#   dsh-syncx restore-global              快照 -> ~/.dsh（freeroute.json + credentials 解密回写）
#   dsh-syncx scan [--repo|--snapshot]    只扫描：列出明文敏感信息位置
#   dsh-syncx profiles                    列出本机 profile
#   dsh-syncx links                       校验 link: 插件源码目录在本机是否存在
#   dsh-syncx status                      快照概览（profile / 脱敏 / 加密 / 远端）
#
# 常用环境变量：
#   DSH_HOME             默认 ~/.dsh
#   DSH_SYNC_DIR         数据仓库根目录（默认：repo checkout 自身，否则 ~/.config/dsh-syncx）
#   DSH_SYNC_KEYFILE     加密密钥文件（默认 ~/.config/dsh-syncx/secret.key）
#   DSH_SYNC_REMOTE      远端名（默认 origin）
#   DSH_SYNC_BRANCH      推送分支（默认当前分支）
#   DSH_SYNC_NO_PUSH=1   只 commit 不 push
#   DSH_SYNC_MESSAGE     自定义 commit message
set -euo pipefail

VERSION="0.3.0"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
# resolve npm bin symlinks (~/.local/bin/dsh-syncx -> ../lib/node_modules/dsh-syncx/...)
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do _src="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$_src")"; done
_dir="$(cd -P "$(dirname "$_src")" && pwd)"
SYNC_DIR="${DSH_SYNC_DIR:-}"
if [ -z "$SYNC_DIR" ]; then
  _self="$(cd -P "$_dir/.." && pwd)"
  if [ -d "$_self/.git" ] || [ -d "$_self/snapshot" ]; then
    SYNC_DIR="$_self"
  else
    SYNC_DIR="$HOME/.config/dsh-syncx"
  fi
fi
SNAP="$SYNC_DIR/snapshot"
SECRET_KEY_FILE="${DSH_SYNC_KEYFILE:-$HOME/.config/dsh-syncx/secret.key}"
REDACT_ENC="${DSH_SYNC_REDACTIONS:-$HOME/.config/dsh-syncx/redactions.json.enc}"
REMOTE="${DSH_SYNC_REMOTE:-origin}"
PY="$_dir/secret-scan.py"
PROFILE_FILES=(package.json cordis.patch.yml pnpm-workspace.yaml pnpm-lock.yaml)
GLOBAL_PLAIN=(freeroute.json)

ts() { date +%Y%m%d-%H%M%S; }
say() { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
die() { printf 'ERROR %s\n' "$*" >&2; exit "${2:-1}"; }

ensure_key() {
  if [ ! -f "$SECRET_KEY_FILE" ]; then
    mkdir -p "$(dirname "$SECRET_KEY_FILE")"
    umask 077; openssl rand -hex 32 > "$SECRET_KEY_FILE"
    say "generated new encryption key -> $SECRET_KEY_FILE (0600, never commit)"
  fi
  chmod 600 "$SECRET_KEY_FILE" 2>/dev/null || true
}

enc_file() { ensure_key; openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -in "$1" -out "$2" -pass file:"$SECRET_KEY_FILE"; }
dec_file() { ensure_key; openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$1" -out "$2" -pass file:"$SECRET_KEY_FILE"; }

sha256_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

# ---------------------------------------------------------------- profiles --
discover_profiles() {
  [ -d "$DSH_HOME/profiles" ] || return 0
  find "$DSH_HOME/profiles" -maxdepth 2 -name package.json -print 2>/dev/null \
    | sed -E 's#.*/profiles/([^/]+)/package\.json$#\1#' | LC_ALL=C sort -u
}

resolve_profiles() {
  local -a out=()
  local a p rest
  if [ "$#" -eq 0 ]; then set -- all; fi
  for a in "$@"; do
    case "$a" in
      all|ALL)
        while IFS= read -r p; do [ -n "$p" ] && out+=("$p"); done < <(discover_profiles)
        ;;
      *)
        rest="$a"
        while [ -n "$rest" ]; do
          p="${rest%%,*}"
          case "$rest" in *,*) rest="${rest#*,}" ;; *) rest="" ;; esac
          [ -z "$p" ] && continue
          [ -d "$DSH_HOME/profiles/$p" ] || die "profile '$p' not found under $DSH_HOME/profiles (try: dsh-syncx profiles)" 2
          out+=("$p")
        done
        ;;
    esac
  done
  # dedupe
  if [ "${#out[@]}" -eq 0 ]; then return 0; fi
  printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++'
}

# -------------------------------------------------------------- export ------
redact_snapshot_files() { # redact_snapshot_files <file...>
  local -a files=("$@")
  [ "${#files[@]}" -eq 0 ] && { say "redaction: nothing to scan"; return 0; }
  local newmap oldmap merged
  newmap="$(mktemp)"; merged="$(mktemp)"; oldmap="$(mktemp)"
  python3 "$PY" redact "${files[@]}" --map-out "$newmap" --json > "$merged" || true
  # merge into the local (encrypted) mapping so old placeholders keep resolving
  if [ -f "$REDACT_ENC" ]; then
    dec_file "$REDACT_ENC" "$oldmap" 2>/dev/null || : > "$oldmap"
  else
    : > "$oldmap"
  fi
  python3 - "$newmap" "$oldmap" "$merged" <<'PY'
import json, sys
new, old, report = sys.argv[1], sys.argv[2], sys.argv[3]
def load(p):
    try:
        return json.load(open(p, encoding="utf-8"))
    except (OSError, ValueError):
        return {}
merged = load(old); merged.update(load(new))
json.dump(merged, open(new, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
import os; os.chmod(new, 0o600)
try:
    rep = json.load(open(report, encoding="utf-8"))
except ValueError:
    rep = {}
print("redaction: %d location(s), %d local secret(s); mapping holds %d"
      % (len(rep.get("redacted", [])), rep.get("secrets", 0), len(merged)))
for f in rep.get("redacted", []):
    print("  %s:%s  %s" % (f["file"], f["line"], f["rule"]))
PY
  if [ -s "$newmap" ]; then
    enc_file "$newmap" "$REDACT_ENC"
    chmod 600 "$REDACT_ENC" 2>/dev/null || true
  fi
  rm -f "$newmap" "$oldmap" "$merged"
  return 0
}

write_secret_report() {
  local out="$SNAP/secret-report.md"
  {
    echo "# dsh-syncx secret report"
    echo
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo
    echo "Inline secrets found in this snapshot are replaced by placeholders;"
    echo "real values live only in the local encrypted mapping"
    echo "(\`~/.config/dsh-syncx/redactions.json.enc\`, never committed)."
    echo
    if python3 "$PY" count-placeholders "$SNAP" --json >/dev/null 2>&1; then
      python3 "$PY" count-placeholders "$SNAP" --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d["files"]:
    print("No redacted placeholders in this snapshot.")
else:
    print("| file | placeholders |")
    print("|---|---|")
    for f, n in sorted(d["files"].items()):
        print("| `%s` | %d |" % (f.replace("'"$SNAP"'/", ""), n))
    print()
    print("Total: %d placeholder(s) — fill them locally, or restore on this machine to auto-fill." % d["total"])
'
    fi
    echo
    echo "Repo-wide scan (high severity must be zero before push):"
    echo '```'
    python3 "$PY" scan "$SNAP" 2>/dev/null || true
    echo '```'
  } > "$out"
  say "secret report -> $out"
}

write_sync_meta() { # write_sync_meta <profile list space separated>
  local profiles="$*" n_ph
  n_ph="$(python3 "$PY" count-placeholders "$SNAP" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])' 2>/dev/null || echo 0)"
  python3 - "$SNAP" "$profiles" "$VERSION" "$n_ph" <<'PY'
import json, sys, datetime
snap, profiles, version, ph = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
meta = {
    "tool": "dsh-syncx",
    "version": version,
    "exportedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "profiles": profiles.split(),
    "placeholders": int(ph or 0),
    "credentials": "AES-256-CBC .enc (key stays local, 0600)",
}
json.dump(meta, open(snap + "/.sync-meta.json", "w"), indent=2, ensure_ascii=False)
print("meta -> snapshot/.sync-meta.json (%d profile(s), %s placeholder(s))" % (len(meta["profiles"]), ph))
PY
}

export_snapshot() {
  local -a profiles=()
  local do_redact=1 p f
  for arg in "$@"; do
    case "$arg" in
      --no-redact) do_redact=0 ;;
      --dry-run) DRY_RUN=1 ;;
      *) profiles+=("$arg") ;;
    esac
  done
  [ "${#profiles[@]}" -eq 0 ] && profiles=("all")
  local -a resolved=()
  while IFS= read -r p; do [ -n "$p" ] && resolved+=("$p"); done < <(resolve_profiles "${profiles[@]}")
  [ "${#resolved[@]}" -eq 0 ] && die "no profile to export" 2

  mkdir -p "$SNAP/global"
  local -a redact_targets=()
  for p in "${resolved[@]}"; do
    [ -d "$DSH_HOME/profiles/$p" ] || { warn "skip profile $p (not present)"; continue; }
    mkdir -p "$SNAP/profiles/$p"
    for f in "${PROFILE_FILES[@]}"; do
      if [ -f "$DSH_HOME/profiles/$p/$f" ]; then
        cp -p "$DSH_HOME/profiles/$p/$f" "$SNAP/profiles/$p/$f"
        redact_targets+=("$SNAP/profiles/$p/$f")
      fi
    done
  done
  for f in "${GLOBAL_PLAIN[@]}"; do
    if [ -f "$DSH_HOME/$f" ]; then
      cp -p "$DSH_HOME/$f" "$SNAP/global/$f"
      redact_targets+=("$SNAP/global/$f")
    fi
  done

  if [ "$do_redact" = 1 ]; then
    redact_snapshot_files "${redact_targets[@]}"
  else
    warn "redaction disabled (--no-redact): inline secrets may reach git"
  fi

  # credentials: plaintext never lands in snapshot
  if [ -f "$DSH_HOME/.credentials.yaml" ]; then
    enc_file "$DSH_HOME/.credentials.yaml" "$SNAP/global/.credentials.yaml.enc"
    sha256_of "$DSH_HOME/.credentials.yaml" > "$SNAP/global/.credentials.sha256"
    say "credentials encrypted -> snapshot/global/.credentials.yaml.enc"
  fi

  # link: source manifest (merge; exported profiles overwrite their own key)
  python3 - "$SNAP" "${resolved[@]}" <<'PY'
import json, glob, os, sys
snap = sys.argv[1]
profiles = sys.argv[2:]
path = os.path.join(snap, "links.manifest.json")
try:
    links = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    links = {}
for pf in sorted(glob.glob(os.path.join(snap, "profiles", "*", "package.json"))):
    name = os.path.basename(os.path.dirname(pf))
    if profiles and name not in profiles:
        continue
    deps = json.load(open(pf, encoding="utf-8")).get("dependencies", {})
    links[name] = sorted(v for v in deps.values() if v.startswith("link:"))
json.dump(links, open(path, "w"), indent=2, ensure_ascii=False)
PY

  write_secret_report
  write_sync_meta "${resolved[@]}"
  say "exported -> $SNAP"
  ( cd "$SNAP" && find . -type f | sed 's|^\./||' | LC_ALL=C sort )
}

# -------------------------------------------------------------- compare -----
fill_secrets() { # fill_secrets <src> <dst>
  cp -p "$1" "$2"
  if [ -f "$REDACT_ENC" ] && grep -q '__REDACTED_' "$2" 2>/dev/null; then
    local m; m="$(mktemp)"
    dec_file "$REDACT_ENC" "$m" 2>/dev/null || : > "$m"
    python3 "$PY" substitute "$2" --map "$m" >/dev/null 2>&1 || true
    rm -f "$m"
  fi
}

diff_profile() {
  local -a profiles=()
  local p changed=0 tmp f src dst
  for arg in "$@"; do [ -n "$arg" ] && profiles+=("$arg"); done
  [ "${#profiles[@]}" -eq 0 ] && profiles=("all")
  local -a resolved=()
  while IFS= read -r p; do [ -n "$p" ] && resolved+=("$p"); done < <(resolve_profiles "${profiles[@]}")
  tmp="$(mktemp -d)"
  for p in "${resolved[@]}"; do
    for f in "${PROFILE_FILES[@]}"; do
      src="$SNAP/profiles/$p/$f"; dst="$DSH_HOME/profiles/$p/$f"
      if [ -f "$src" ] && [ -f "$dst" ]; then
        fill_secrets "$src" "$tmp/$f"
        cmp -s "$tmp/$f" "$dst" || { say "DIFF          $p/$f"; changed=1; }
      elif [ -f "$src" ] || [ -f "$dst" ]; then
        say "ONLY-ONE-SIDE $p/$f"; changed=1
      fi
    done
  done
  for f in "${GLOBAL_PLAIN[@]}"; do
    src="$SNAP/global/$f"; dst="$DSH_HOME/$f"
    if [ -f "$src" ] && [ -f "$dst" ]; then
      fill_secrets "$src" "$tmp/$f"
      cmp -s "$tmp/$f" "$dst" || { say "DIFF          global/$f"; changed=1; }
    elif [ -f "$src" ] || [ -f "$dst" ]; then
      say "ONLY-ONE-SIDE global/$f"; changed=1
    fi
  done
  if [ -f "$SNAP/global/.credentials.sha256" ] && [ -f "$DSH_HOME/.credentials.yaml" ]; then
    local want have
    want="$(cat "$SNAP/global/.credentials.sha256")"; have="$(sha256_of "$DSH_HOME/.credentials.yaml")"
    [ "$want" != "$have" ] && { say "DIFF          global/.credentials.yaml (hash)"; changed=1; }
  fi
  [ "$changed" = 0 ] && say "in sync: snapshot == local (${resolved[*]} + global)"
  rm -rf "$tmp"
  return 0
}

# ----------------------------------------------------------------- push -----
repo_scan() {
  python3 "$PY" scan "$SYNC_DIR" 2>/dev/null || true
}

repo_high_count() {
  python3 "$PY" scan "$SYNC_DIR" 2>/dev/null | grep -c '^HIGH' || true
}

push_snapshot() {
  local msg="" no_export=0 allow_findings=0 do_redact=1
  local -a profiles=()
  local arg
  while [ "$#" -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --message=*)   msg="${arg#*=}" ;;
      --message|-m)  [ "$#" -gt 0 ] || die "--message needs a value" 2; msg="$1"; shift ;;
      --no-export)   no_export=1 ;;
      --no-push)     NO_PUSH=1 ;;
      --allow-findings) allow_findings=1 ;;
      --no-redact)   do_redact=0 ;;
      --dry-run)     DRY_RUN=1 ;;
      *)             profiles+=("$arg") ;;
    esac
  done
  if [ "${#profiles[@]}" -eq 0 ]; then profiles=("all"); fi

  if [ "$no_export" = 0 ]; then
    local -a ex=("${profiles[@]}")
    [ "$do_redact" = 0 ] && ex+=(--no-redact)
    export_snapshot "${ex[@]}" >/dev/null
  fi

  # gate: no plaintext secret may enter the repo
  if [ -f "$SYNC_DIR/snapshot/global/.credentials.yaml" ] || [ -f "$SYNC_DIR/.credentials.yaml" ]; then
    die "plaintext credentials file present in repo — refusing to push" 3
  fi
  local high
  high="$(repo_high_count)"
  if [ "${high:-0}" -gt 0 ]; then
    say "high-severity findings in repo: $high"
    repo_scan | grep '^HIGH' | sed 's/^/  /'
    if [ "$allow_findings" != 1 ]; then
      say "refusing to push (use --allow-findings only if you know the match is a false positive)"
      return 3
    fi
    warn "--allow-findings: pushing despite $high finding(s)"
  fi

  if [ ! -d "$SYNC_DIR/.git" ]; then
    die "$SYNC_DIR is not a git repo (set DSH_SYNC_DIR or run inside the data repo)" 4
  fi
  git -C "$SYNC_DIR" add -A
  local staged
  staged="$(git -C "$SYNC_DIR" diff --cached --name-only)"
  if [ -z "$staged" ]; then
    say "no snapshot changes to commit"
  else
    if [ -z "$msg" ]; then
      msg="${DSH_SYNC_MESSAGE:-}"
    fi
    if [ -z "$msg" ]; then
      local names
      names="$(printf '%s\n' "$staged" | head -5 | tr '\n' ' ')"
      msg="sync: $(printf '%s\n' "$staged" | wc -l | tr -d ' ') file(s) — $(printf '%s\n' "$names" | sed 's|snapshot/||g' | tr -s ' ')"
    fi
    if [ "${DRY_RUN:-0}" = 1 ]; then
      say "DRY-RUN would commit ${staged//$'\n'/, }"
      return 0
    fi
    git -C "$SYNC_DIR" commit -q -m "$msg"
    say "committed: $(git -C "$SYNC_DIR" log -1 --pretty='%h %s')"
  fi

  [ "${NO_PUSH:-0}" = 1 ] && { say "skip push (--no-push)"; return 0; }
  if [ "${DRY_RUN:-0}" = 1 ]; then say "DRY-RUN would push to $REMOTE"; return 0; fi

  local branch="${DSH_SYNC_BRANCH:-$(git -C "$SYNC_DIR" rev-parse --abbrev-ref HEAD)}"
  git -C "$SYNC_DIR" fetch -q "$REMOTE" || { warn "fetch failed (offline?) — local commit kept"; return 0; }
  local behind
  behind="$(git -C "$SYNC_DIR" rev-list --count "HEAD..$REMOTE/$branch" 2>/dev/null || echo 0)"
  if [ "${behind:-0}" -gt 0 ]; then
    say "remote ahead by $behind commit(s) — rebasing"
    if ! git -C "$SYNC_DIR" rebase --autostash "$REMOTE/$branch" >/dev/null 2>&1; then
      git -C "$SYNC_DIR" rebase --abort >/dev/null 2>&1 || true
      die "rebase conflict with $REMOTE/$branch — resolve locally, local commit kept" 4
    fi
  fi
  if git -C "$SYNC_DIR" push -q "$REMOTE" "HEAD:$branch" 2>/tmp/.dsh-syncx-push.err; then
    say "pushed -> $REMOTE/$branch ($(git -C "$SYNC_DIR" rev-parse --short HEAD))"
    say "repo: $(git -C "$SYNC_DIR" remote get-url "$REMOTE" 2>/dev/null || echo '?')"
  else
    warn "push failed: $(tr -d '\n' < /tmp/.dsh-syncx-push.err | tail -c 200)"
    warn "local commit is preserved; retry once when the network/remote is back"
    return 5
  fi
}

# -------------------------------------------------------------- restore -----
restore_profile() {
  local p="$1"
  [ -d "$SNAP/profiles/$p" ] || die "snapshot has no profile '$p'" 2
  local dst="$DSH_HOME/profiles/$p" f
  if [ -d "$dst" ]; then
    local bak="$SYNC_DIR/backups/$p-$(ts)"
    mkdir -p "$bak"
    for f in "${PROFILE_FILES[@]}"; do [ -f "$dst/$f" ] && cp -p "$dst/$f" "$bak/$f"; done
    say "backed up current $p -> $bak"
  fi
  mkdir -p "$dst"
  local -a written=()
  for f in "${PROFILE_FILES[@]}"; do
    [ -f "$SNAP/profiles/$p/$f" ] || continue
    fill_secrets "$SNAP/profiles/$p/$f" "$dst/$f"
    written+=("$dst/$f")
  done
  local unresolved
  unresolved="$(python3 "$PY" count-placeholders "${written[@]}" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])' 2>/dev/null || echo 0)"
  say "restored declarative files into $dst"
  if [ "${unresolved:-0}" -gt 0 ]; then
    warn "$unresolved placeholder(s) could not be filled from this machine's mapping:"
    python3 "$PY" count-placeholders "${written[@]}" --json 2>/dev/null | sed 's/^/  /' || true
    warn "fill them by hand in $dst/cordis.patch.yml, or copy secret.key + redactions.json.enc from the old machine"
  fi
  say "next: (cd $dst && pnpm install)   # or: dsh plugin --profile $p install"
}

restore_global() {
  local bak="$SYNC_DIR/backups/global-$(ts)" f
  mkdir -p "$bak"
  for f in "${GLOBAL_PLAIN[@]}"; do
    if [ -f "$SNAP/global/$f" ]; then
      [ -f "$DSH_HOME/$f" ] && cp -p "$DSH_HOME/$f" "$bak/$f"
      fill_secrets "$SNAP/global/$f" "$DSH_HOME/$f"
      say "restored ~/.dsh/$f"
    fi
  done
  if [ -f "$SNAP/global/.credentials.yaml.enc" ]; then
    [ -f "$DSH_HOME/.credentials.yaml" ] && cp -p "$DSH_HOME/.credentials.yaml" "$bak/.credentials.yaml"
    chmod 600 "$bak/.credentials.yaml" 2>/dev/null || true
    dec_file "$SNAP/global/.credentials.yaml.enc" "$DSH_HOME/.credentials.yaml"
    chmod 600 "$DSH_HOME/.credentials.yaml"
    say "decrypted credentials -> ~/.dsh/.credentials.yaml (0600)"
  fi
  say "backup of previous state -> $bak"
}

# ---------------------------------------------------------- scrub history ----
scrub_history() {
  local apply=0 arg branch
  for arg in "$@"; do case "$arg" in --yes) apply=1 ;; esac; done
  [ -d "$SYNC_DIR/.git" ] || die "$SYNC_DIR is not a git repo" 4
  [ -z "$(git -C "$SYNC_DIR" status --porcelain)" ] || die "worktree dirty — export + commit before scrubbing history" 4
  local bak="$SYNC_DIR/backups/history-$(ts).bundle"
  mkdir -p "$(dirname "$bak")"
  git -C "$SYNC_DIR" bundle create "$bak" --all >/dev/null 2>&1
  say "history backup -> $bak (keep it local; it still contains the old secrets)"
  if [ "$apply" != 1 ]; then
    say "dry-run: history would be rewritten so snapshot files are re-redacted in every commit"
    say "rerun with: dsh-syncx scrub-history --yes   (then one force push)"
    return 0
  fi
  FILTER_BRANCH_SQUELCH_WARNING=1 git -C "$SYNC_DIR" filter-branch -f --tree-filter \
    "python3 '$PY' redact snapshot >/dev/null 2>&1 || true" -- --all >/dev/null
  git -C "$SYNC_DIR" for-each-ref --format='%(refname)' refs/original | while IFS= read -r r; do
    git -C "$SYNC_DIR" update-ref -d "$r" 2>/dev/null || true
  done
  git -C "$SYNC_DIR" reflog expire --expire=now --all
  git -C "$SYNC_DIR" gc --prune=now -q
  branch="$(git -C "$SYNC_DIR" rev-parse --abbrev-ref HEAD)"
  say "history rewritten locally (HEAD $(git -C "$SYNC_DIR" rev-parse --short HEAD))"
  say "publish it: git -C $SYNC_DIR push --force-with-lease $REMOTE $branch"
}

# ---------------------------------------------------------------- status -----
status_overview() {
  say "dsh-syncx     : $VERSION"
  say "snapshot dir  : $SNAP"
  say "profiles      : $(find "$SNAP/profiles" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed -E 's#.*/([^/]+)$#\1#' | tr '\n' ' ')"
  if [ -f "$SNAP/global/.credentials.yaml.enc" ]; then
    say "credentials   : ENCRYPTED ($(stat -f%z "$SNAP/global/.credentials.yaml.enc" 2>/dev/null || stat -c%s "$SNAP/global/.credentials.yaml.enc") bytes, sha256 recorded)"
  else
    say "credentials   : (none in snapshot)"
  fi
  if [ -f "$REDACT_ENC" ]; then
    local n
    n="$(mktemp)"; dec_file "$REDACT_ENC" "$n" 2>/dev/null || echo '{}' > "$n"
    say "redactions    : $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))) if True else 0)' "$n" 2>/dev/null || echo '?') secret(s) stored locally (encrypted)"
    rm -f "$n"
  else
    say "redactions    : (none yet)"
  fi
  local ph
  ph="$(python3 "$PY" count-placeholders "$SNAP" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])' 2>/dev/null || echo 0)"
  say "placeholders  : $ph in snapshot (filled from local mapping on restore)"
  [ -f "$SECRET_KEY_FILE" ] && say "key file      : $SECRET_KEY_FILE (local only)" || say "key file      : (not generated yet)"
  if [ -d "$SYNC_DIR/.git" ]; then
    say "remote        : $(git -C "$SYNC_DIR" remote get-url "$REMOTE" 2>/dev/null || echo '(none)')"
    say "branch        : $(git -C "$SYNC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    say "last commit   : $(git -C "$SYNC_DIR" log -1 --pretty='%h %ad %s' --date=short 2>/dev/null || echo '(none)')"
    say "worktree      : $(git -C "$SYNC_DIR" status --porcelain | wc -l | tr -d ' ') changed file(s)"
  fi
}

scan_cmd() {
  local target=() a
  for a in "$@"; do
    case "$a" in
      --repo) target=("$SYNC_DIR") ;;
      --snapshot) target=("$SNAP") ;;
      *) target+=("$a") ;;
    esac
  done
  [ "${#target[@]}" -eq 0 ] && target=("$SYNC_DIR")
  python3 "$PY" scan "${target[@]}" --min-severity medium
}

print_help() {
  cat <<'EOF'
dsh-syncx 0.3.0 — sync dsh profiles to a private git repo without leaking secrets

USAGE
  dsh-syncx export   [profile...|all] [--no-redact]
      local ~/.dsh -> snapshot/, inline secrets redacted, credentials encrypted

  dsh-syncx push     [profile...|all] [--message MSG] [--no-push] [--allow-findings] [--dry-run]
      export + repo-wide secret gate + git commit + git push (one command to GitHub)

  dsh-syncx diff     [profile...|all]     compare snapshot vs local (placeholders re-filled)
  dsh-syncx restore  <profile>            snapshot -> profile (auto backup + local secret fill)
  dsh-syncx restore-global                snapshot -> ~/.dsh (freeroute.json + credentials)
  dsh-syncx scan     [path...] [--repo|--snapshot]   report plaintext secrets only
  dsh-syncx scrub-history [--yes]          re-redact snapshot in every commit (rewrites history)
  dsh-syncx profiles                      list profiles on this machine
  dsh-syncx links                         verify link: plugin sources exist locally
  dsh-syncx status                        snapshot / redaction / encryption / remote overview

SECRETS
  inline secrets in cordis.patch.yml (token, apiKey, password, ...) are replaced by
  __REDACTED_<RULE>_<hash>__ before commit; real values stay in
  ~/.config/dsh-syncx/redactions.json.enc (AES, key file 0600, never committed).
  push refuses to run while any high-severity plaintext secret remains in the repo.

ENV
  DSH_HOME, DSH_SYNC_DIR, DSH_SYNC_KEYFILE, DSH_SYNC_REDACTIONS,
  DSH_SYNC_REMOTE (default origin), DSH_SYNC_BRANCH, DSH_SYNC_NO_PUSH=1, DSH_SYNC_MESSAGE
EOF
}

DRY_RUN="${DRY_RUN:-0}"
NO_PUSH="${DSH_SYNC_NO_PUSH:-0}"

cmd="${1:-}"
[ "$#" -gt 0 ] && shift || true

case "$cmd" in
  export)          export_snapshot "$@" ;;
  push|sync)       push_snapshot "$@" ;;
  diff)            diff_profile "$@" ;;
  restore)         [ "$#" -gt 0 ] || die "usage: dsh-syncx restore <profile>" 2; restore_profile "$1" ;;
  restore-global)  restore_global ;;
  scan)            scan_cmd "$@" ;;
  scrub-history)   scrub_history "$@" ;;
  profiles)        discover_profiles ;;
  links)           python3 - "$SNAP" <<'PY'
import json, os, sys
snap = sys.argv[1]
path = os.path.join(snap, "links.manifest.json")
links = json.load(open(path, encoding="utf-8"))
missing = 0
for prof, paths in sorted(links.items()):
    for p in paths:
        src = p[5:]
        ok = os.path.isdir(src)
        print(f"{'OK  ' if ok else 'MISS'} {prof}: {src}")
        missing += (not ok)
if missing: raise SystemExit(f"{missing} link source(s) missing on this machine")
print("all link sources present")
PY
  ;;
  status)          status_overview ;;
  version|-V|--version) say "dsh-syncx $VERSION" ;;
  ""|help|-h|--help) print_help ;;
  *) die "unknown command '$cmd' (try: dsh-syncx help)" 2 ;;
esac
