#!/usr/bin/env bash
# dsh-profiles-sync —— DeepSeek Harness (dsh) profile 插件与设置同步
#
# dsh 本身没有内置配置同步；一个 profile 的全部状态由声明式文件构成：
#   profiles/<name>/package.json        插件依赖 + dsh.profile.bundles 装载清单
#   profiles/<name>/cordis.patch.yml    全部用户设置（模型、主题、语言、插件配置）
#   profiles/<name>/pnpm-workspace.yaml / pnpm-lock.yaml
# 加上全局层：
#   ~/.dsh/freeroute.json               模型路由（仅含 keyRef 引用名，无密钥，明文入仓）
#   ~/.dsh/.credentials.yaml            模型凭证（真实 API keys，仅以 AES-256 加密封包入仓）
#
# 安全模型：加密密钥保存在本机 $SECRET_KEY_FILE（0600，永不入 git）。
# 仓库即使整体泄露也无法解出任何 API key；本机侧泄露与不加密时等价。
#
# 用法:
#   dsh-profiles-sync export                 本机 ~/.dsh -> snapshot/（自动加密 credentials）
#   dsh-profiles-sync diff [profile]         对比快照与本机（profile + 全局）
#   dsh-profiles-sync restore <profile>      快照 -> profile（自动备份现状）
#   dsh-profiles-sync restore-global         快照 -> ~/.dsh（freeroute.json + credentials 解密回写）
#   dsh-profiles-sync links                  校验 link: 插件源码目录在本机是否存在
#   dsh-profiles-sync status                 快照概览（加密状态、checksum）
set -euo pipefail

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAP="$SYNC_DIR/snapshot"
SECRET_KEY_FILE="${DSH_SYNC_KEYFILE:-$HOME/.config/dsh-profiles-sync/secret.key}"
PROFILES=(web acp headless)
PROFILE_FILES=(package.json cordis.patch.yml pnpm-workspace.yaml pnpm-lock.yaml)
GLOBAL_PLAIN=(freeroute.json)

ts() { date +%Y%m%d-%H%M%S; }

ensure_key() {
  if [ ! -f "$SECRET_KEY_FILE" ]; then
    mkdir -p "$(dirname "$SECRET_KEY_FILE")"
    umask 077; openssl rand -hex 32 > "$SECRET_KEY_FILE"
    echo "generated new encryption key -> $SECRET_KEY_FILE (0600, never commit)"
  fi
  chmod 600 "$SECRET_KEY_FILE" 2>/dev/null || true
}

enc_file() { # enc_file <plain> <out.enc>
  ensure_key
  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
    -in "$1" -out "$2" -pass file:"$SECRET_KEY_FILE"
}

dec_file() { # dec_file <in.enc> <plain>
  ensure_key
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "$1" -out "$2" -pass file:"$SECRET_KEY_FILE"
}

sha256_of() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

export_snapshot() {
  mkdir -p "$SNAP/global"
  for p in "${PROFILES[@]}"; do
    [ -d "$DSH_HOME/profiles/$p" ] || { echo "skip profile $p (not present)"; continue; }
    mkdir -p "$SNAP/profiles/$p"
    for f in "${PROFILE_FILES[@]}"; do
      [ -f "$DSH_HOME/profiles/$p/$f" ] && cp -p "$DSH_HOME/profiles/$p/$f" "$SNAP/profiles/$p/$f"
    done
  done
  for f in "${GLOBAL_PLAIN[@]}"; do
    [ -f "$DSH_HOME/$f" ] && cp -p "$DSH_HOME/$f" "$SNAP/global/$f"
  done
  # credentials：明文永不落 snapshot；仅写 AES-256 封包 + sha256 校验
  if [ -f "$DSH_HOME/.credentials.yaml" ]; then
    enc_file "$DSH_HOME/.credentials.yaml" "$SNAP/global/.credentials.yaml.enc"
    sha256_of "$DSH_HOME/.credentials.yaml" > "$SNAP/global/.credentials.sha256"
    echo "credentials encrypted -> snapshot/global/.credentials.yaml.enc"
  fi
  # link: 源目录清单 —— 跨机器恢复前用 links 校验源码目录是否存在
  python3 - "$SNAP" <<'PY'
import json, glob, os, sys
snap = sys.argv[1]
links = {}
for pf in sorted(glob.glob(os.path.join(snap, "profiles", "*", "package.json"))):
    name = os.path.basename(os.path.dirname(pf))
    deps = json.load(open(pf)).get("dependencies", {})
    links[name] = sorted(v for v in deps.values() if v.startswith("link:"))
json.dump(links, open(os.path.join(snap, "links.manifest.json"), "w"), indent=2, ensure_ascii=False)
PY
  echo "exported -> $SNAP"
  ( cd "$SNAP" && find . -type f | sed 's|^\./||' | sort )
}

restore_profile() {
  local p="$1"
  [ -d "$SNAP/profiles/$p" ] || { echo "snapshot has no profile '$p'"; exit 1; }
  local dst="$DSH_HOME/profiles/$p"
  if [ -d "$dst" ]; then
    local bak="$SYNC_DIR/backups/$p-$(ts)"
    mkdir -p "$bak"
    for f in "${PROFILE_FILES[@]}"; do
      [ -f "$dst/$f" ] && cp -p "$dst/$f" "$bak/$f"
    done
    echo "backed up current $p -> $bak"
  fi
  mkdir -p "$dst"
  for f in "${PROFILE_FILES[@]}"; do
    [ -f "$SNAP/profiles/$p/$f" ] && cp -p "$SNAP/profiles/$p/$f" "$dst/$f"
  done
  echo "restored declarative files into $dst"
  echo "next: (cd $dst && pnpm install)   # or: dsh plugin --profile $p install"
}

restore_global() {
  local bak="$SYNC_DIR/backups/global-$(ts)"
  mkdir -p "$bak"
  for f in "${GLOBAL_PLAIN[@]}"; do
    if [ -f "$SNAP/global/$f" ]; then
      [ -f "$DSH_HOME/$f" ] && cp -p "$DSH_HOME/$f" "$bak/$f"
      cp -p "$SNAP/global/$f" "$DSH_HOME/$f"
      echo "restored ~/.dsh/$f"
    fi
  done
  if [ -f "$SNAP/global/.credentials.yaml.enc" ]; then
    [ -f "$DSH_HOME/.credentials.yaml" ] && cp -p "$DSH_HOME/.credentials.yaml" "$bak/.credentials.yaml"
    chmod 600 "$bak/.credentials.yaml" 2>/dev/null || true
    dec_file "$SNAP/global/.credentials.yaml.enc" "$DSH_HOME/.credentials.yaml"
    chmod 600 "$DSH_HOME/.credentials.yaml"
    echo "decrypted credentials -> ~/.dsh/.credentials.yaml (0600)"
  fi
  echo "backup of previous state -> $bak"
}

diff_profile() {
  local p="${1:-web}" changed=0 dst="$DSH_HOME/profiles/${1:-web}"
  local snap_f dst_f f
  for f in "${PROFILE_FILES[@]}" "${GLOBAL_PLAIN[@]}"; do
    if [ "$f" = "freeroute.json" ]; then
      snap_f="$SNAP/global/freeroute.json"; dst_f="$DSH_HOME/freeroute.json"
    else
      snap_f="$SNAP/profiles/$p/$f"; dst_f="$dst/$f"
    fi
    if [ -f "$snap_f" ] && [ -f "$dst_f" ]; then
      cmp -s "$snap_f" "$dst_f" || { echo "DIFF          $p/$f"; changed=1; }
    elif [ -f "$snap_f" ] || [ -f "$dst_f" ]; then
      echo "ONLY-ONE-SIDE $p/$f"; changed=1
    fi
  done
  # credentials：用 sha256 对比（密文无法逐字节比较，明文不入快照）
  if [ -f "$SNAP/global/.credentials.sha256" ] && [ -f "$DSH_HOME/.credentials.yaml" ]; then
    local want have
    want="$(cat "$SNAP/global/.credentials.sha256")"
    have="$(sha256_of "$DSH_HOME/.credentials.yaml")"
    if [ "$want" != "$have" ]; then echo "DIFF          global/.credentials.yaml (hash)"; changed=1; fi
  fi
  [ "$changed" = 0 ] && echo "in sync: snapshot == local ($p + global)"
  return 0
}

status_overview() {
  echo "snapshot dir : $SNAP"
  echo "profiles     : $(find "$SNAP/profiles" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [ -f "$SNAP/global/.credentials.yaml.enc" ]; then
    echo "credentials  : ENCRYPTED ($(stat -f%z "$SNAP/global/.credentials.yaml.enc") bytes, sha256 recorded)"
  else
    echo "credentials  : (none in snapshot)"
  fi
  [ -f "$SNAP/global/freeroute.json" ] && echo "freeroute    : present (plain, keyRef-only)"
  [ -f "$SECRET_KEY_FILE" ] && echo "key file     : $SECRET_KEY_FILE (local only)" || echo "key file     : (not generated yet)"
}

check_links() {
  python3 - "$SNAP" <<'PY'
import json, os, sys
snap = sys.argv[1]
links = json.load(open(os.path.join(snap, "links.manifest.json")))
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
}

case "${1:-}" in
  export)         export_snapshot ;;
  diff)           diff_profile "${2:-web}" ;;
  restore)        restore_profile "${2:?usage: dsh-profiles-sync restore <profile>}" ;;
  restore-global) restore_global ;;
  links)          check_links ;;
  status)         status_overview ;;
  *) grep '^# ' "$0" | sed 's/^# \{0,1\}//' | head -20; exit 1 ;;
esac
