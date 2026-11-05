#!/usr/bin/env bash
set -euo pipefail

# 发布 Electron macOS 版到远程服务器（双架构打包 → 签名 → 合并 manifest → 上传 → 验证）
#
# 用法:
#   deploy-mac-electron.sh                       # 打 arm64+x64，自动递增补丁版本，只写 mac* 字段
#   deploy-mac-electron.sh --check               # 只检查环境、打印计划版本
#   deploy-mac-electron.sh --dry-run             # 跑到签名 + 生成 manifest 就停，不上传
#   deploy-mac-electron.sh --skip-build          # 复用 dist 里已打好的包
#   deploy-mac-electron.sh --arch arm64          # 只发一个架构（官网会提示「仅提供该架构」）
#   deploy-mac-electron.sh v1.1.001 "更新说明"    # 指定版本
#   deploy-mac-electron.sh --takeover ...        # 同时接管 Swift 通道（version/file），
#                                                # 需要 dist 里有 universal zip（见 --help）
#
# 安全边界：
#   - 默认只改 mac* / macFiles 字段：Swift 原生版通道（version/file）原样保留，老用户不会被强推
#   - --takeover 才会改 version/file，且**必须用 universal zip**：老 Swift 用户里可能有 Intel Mac，
#     只发 arm64 会让他们的 App 被替换成跑不起来的版本
#   - 先传安装包、最后换 manifest；上传后回读 /api/app/latest 校验

SCRIPT_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_REAL")
REPO="${CUTE_PET_REPO:-$(cd "$SCRIPTS_DIR/../../.." && pwd)}"
ELECTRON_DIR="$REPO/DesktopPetElectron"
DIST_DIR="$ELECTRON_DIR/dist"
SERVER="${CUTE_PET_SERVER:-http://101.96.248.75}"
KEY_DIR="${CUTE_PET_KEY_DIR:-$HOME/.cute-pet-release}"
PRIVATE_KEY="$KEY_DIR/ed25519_private.pem"
REMOTE_DIR="${CUTE_PET_REMOTE_DIST:-/opt/petserver/dist}"
source "$SCRIPTS_DIR/remote.sh"

MODE="deploy"
SKIP_BUILD=0
DRY_RUN=0
TAKEOVER=0
ARCH="both"
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --takeover) TAKEOVER=1 ;;
    --arch=*) ARCH="${1#--arch=}" ;;
    --arch) shift; ARCH="${1:-both}" ;;
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done
VERSION="${POSITIONAL[0]:-}"
NOTES="${POSITIONAL[1]:-常规更新}"
case "$ARCH" in both|arm64|x64) ;; *) echo "未知架构：$ARCH（both / arm64 / x64）" >&2; exit 2 ;; esac

say() { printf '%s\n' "$*"; }
fail() { say "❌ $*"; exit 1; }

# ── 1. 环境检查 ──────────────────────────────────────────────
[ -d "$ELECTRON_DIR" ] || fail "未找到 Electron 工程：$ELECTRON_DIR"
[ -f "$PRIVATE_KEY" ] || fail "缺少发布签名私钥：$PRIVATE_KEY"
curl -sf --max-time 8 "$SERVER/api/ping" >/dev/null || fail "服务器不可达：$SERVER/api/ping"

LOCAL_PKG_VER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ELECTRON_DIR/package.json")
REMOTE_MAC_VER=$(curl -sf --max-time 8 "$SERVER/api/app/latest" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)['data'].get('macVersion') or '')
except Exception:
    print('')
" || true)

say "服务器 macVersion : ${REMOTE_MAC_VER:-（尚未发布）}"
say "本地 package 版本 : $LOCAL_PKG_VER"

plain_version() {
  python3 - "$1" <<'PY'
import sys
v = (sys.argv[1] or '').strip()
for p in ('electron', 'v', 'V'):
    if v.lower().startswith(p.lower()):
        v = v[len(p):]
print(v)
PY
}

next_version() {
  python3 - "$1" <<'PY'
import sys
v = sys.argv[1].lstrip('vV').lstrip('electron')
parts = v.split('.')
if len(parts) >= 3 and parts[2].isdigit():
    width = len(parts[2])
    parts[2] = str(int(parts[2]) + 1).zfill(width)
else:
    parts.append('1')
print('.'.join(parts))
PY
}

if [ -z "$VERSION" ]; then
  BASE=$(plain_version "${REMOTE_MAC_VER:-$LOCAL_PKG_VER}")
  VERSION=$(next_version "$BASE")
fi
PLAIN=$(plain_version "$VERSION")
printf '%s' "$PLAIN" | grep -Eq '^[0-9]+(\.[0-9]+)+$' || fail "版本号格式不对：$PLAIN（应形如 1.1.001）"
MANIFEST_VER="v$PLAIN"

say "计划发布版本      : $MANIFEST_VER（manifest macVersion）"
say "更新说明          : $NOTES"
say "架构              : $ARCH"
[ "$TAKEOVER" = "1" ] && say "接管 Swift 通道    : ✅ 会同时写 version/file（universal zip）"

if [ "$MODE" = "check" ]; then
  say "✅ 环境检查通过（未打包、未发布）"
  exit 0
fi

# ── 2. 打包 ─────────────────────────────────────────────────
if [ "$SKIP_BUILD" = "1" ]; then
  say ""
  say "跳过打包，复用 dist 里的产物"
else
  say ""
  say "打包 Electron macOS（版本 $PLAIN，架构 $ARCH）…"
  if [ "$TAKEOVER" = "1" ]; then
    # 接管 Swift 通道要 universal zip（老用户里有 Intel Mac），
    # 官网/客户端又要按架构分流的 dmg → 先打双架构，再不清理地补一个 universal
    bash "$SCRIPTS_DIR/build-mac-electron-local.sh" --version "$PLAIN" --arch both \
      || fail "双架构打包失败"
    say ""
    say "补打 universal（接管 Swift 通道用）…"
    bash "$SCRIPTS_DIR/build-mac-electron-local.sh" --version "$PLAIN" --arch universal --no-clean \
      || fail "universal 打包失败"
  else
    bash "$SCRIPTS_DIR/build-mac-electron-local.sh" --version "$PLAIN" --arch "$ARCH" \
      || fail "打包失败"
  fi
fi

# ── 3. 收集产物 ─────────────────────────────────────────────
pick_dmg() {
  ls "$DIST_DIR"/DesktopPet-"$PLAIN"-"$1".dmg 2>/dev/null | head -1
}
pick_zip() {
  ls "$DIST_DIR"/DesktopPet-"$PLAIN"-"$1"-mac.zip 2>/dev/null | head -1
}

STAGE_DIR="$DIST_DIR/.mac-release"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

sign_file() {
  local file="$1"
  local sha sig
  sha=$(shasum -a 256 "$file" | awk '{print $1}')
  printf '%s' "$sha" > "$STAGE_DIR/.digest.txt"
  sig=$(openssl pkeyutl -sign -rawin -inkey "$PRIVATE_KEY" -in "$STAGE_DIR/.digest.txt" | base64 | tr -d '\n')
  rm -f "$STAGE_DIR/.digest.txt"
  printf '%s %s\n' "$sha" "$sig"
}

# 签名自检：用发布公钥验一遍，私钥损坏/公钥不匹配的包绝不能上线
PUB_B64_FILE="$KEY_DIR/ed25519_public.b64"
verify_sig() {
  local digest="$1" sig="$2"
  [ -f "$PUB_B64_FILE" ] || return 0
  python3 - "$PUB_B64_FILE" "$STAGE_DIR/.pub.der" <<'PY'
import base64, sys
raw = base64.b64decode(open(sys.argv[1]).read().strip())
if len(raw) != 32:
    sys.exit("公钥不是 32 字节 Ed25519 raw key")
open(sys.argv[2], 'wb').write(bytes.fromhex('302a300506032b6570032100') + raw)
PY
  printf '%s' "$digest" > "$STAGE_DIR/.digest.txt"
  printf '%s' "$sig" | base64 -d > "$STAGE_DIR/.sig.bin"
  local ok=0
  openssl pkeyutl -verify -pubin -inkey "$STAGE_DIR/.pub.der" -keyform DER \
    -rawin -in "$STAGE_DIR/.digest.txt" -sigfile "$STAGE_DIR/.sig.bin" >/dev/null 2>&1 || ok=1
  rm -f "$STAGE_DIR/.digest.txt" "$STAGE_DIR/.sig.bin" "$STAGE_DIR/.pub.der"
  return $ok
}

MANIFEST_ARGS=()
for a in arm64 x64; do
  if [ "$ARCH" != "both" ] && [ "$ARCH" != "$a" ]; then continue; fi
  DMG=$(pick_dmg "$a" || true)
  [ -n "$DMG" ] || fail "缺少 $a 架构的 dmg：dist/DesktopPet-$PLAIN-$a.dmg（先打包或去掉 --skip-build）"
  read -r SHA SIG <<<"$(sign_file "$DMG")"
  verify_sig "$SHA" "$SIG" || fail "$a 包签名自检失败：私钥与 ed25519_public.b64 不匹配"
  SIZE=$(stat -f%z "$DMG" 2>/dev/null || stat -c%s "$DMG")
  say "  $a: $(basename "$DMG")  $(python3 -c "import sys;print(f'{int(sys.argv[1])/1024/1024:.1f}')" "$SIZE") MB"
  MANIFEST_ARGS+=("$a" "$(basename "$DMG")" "$SHA" "$SIG" "$SIZE")
done

# 老字段 macFile 指向第一个架构（读取方不会跨架构回落，保留只为兼容旧客户端）
FIRST_FILE=$(basename "$(pick_dmg "${MANIFEST_ARGS[0]}")")
FIRST_SHA="${MANIFEST_ARGS[2]}"
FIRST_SIG="${MANIFEST_ARGS[3]}"
FIRST_SIZE="${MANIFEST_ARGS[4]}"

# 接管 Swift 通道
TAKEOVER_ZIP=""
TAKEOVER_SHA=""
TAKEOVER_SIG=""
TAKEOVER_SIZE=0
TAKEOVER_DMG=""
TAKEOVER_DMG_SHA=""
TAKEOVER_DMG_SIG=""
TAKEOVER_DMG_SIZE=0
if [ "$TAKEOVER" = "1" ]; then
  TAKEOVER_ZIP=$(pick_zip universal || true)
  TAKEOVER_DMG=$(ls "$DIST_DIR"/DesktopPet-"$PLAIN"-universal.dmg 2>/dev/null | head -1)
  [ -n "$TAKEOVER_ZIP" ] || fail "--takeover 需要 universal zip（dist/DesktopPet-$PLAIN-universal-mac.zip）。
   老 Swift 用户里可能有 Intel Mac，只发单架构会把他们换成跑不起来的版本。
   先跑：build-mac-electron-local.sh --version $PLAIN --arch universal"
  [ -n "$TAKEOVER_DMG" ] || fail "--takeover 需要 universal dmg（dist/DesktopPet-$PLAIN-universal.dmg）"
  read -r TAKEOVER_SHA TAKEOVER_SIG <<<"$(sign_file "$TAKEOVER_ZIP")"
  verify_sig "$TAKEOVER_SHA" "$TAKEOVER_SIG" || fail "universal zip 签名自检失败"
  TAKEOVER_SIZE=$(stat -f%z "$TAKEOVER_ZIP" 2>/dev/null || stat -c%s "$TAKEOVER_ZIP")
  # Swift 客户端优先用 dmgFile（见 UpdateService.selectPackage）：不接管 dmg 字段的话，
  # 它会拿"version 是新的、文件是老的 Swift dmg"这一对，把用户替换回旧版
  read -r TAKEOVER_DMG_SHA TAKEOVER_DMG_SIG <<<"$(sign_file "$TAKEOVER_DMG")"
  verify_sig "$TAKEOVER_DMG_SHA" "$TAKEOVER_DMG_SIG" || fail "universal dmg 签名自检失败"
  TAKEOVER_DMG_SIZE=$(stat -f%z "$TAKEOVER_DMG" 2>/dev/null || stat -c%s "$TAKEOVER_DMG")
  say "  universal: $(basename "$TAKEOVER_ZIP")（zip）+ $(basename "$TAKEOVER_DMG")（dmg）"
fi

# ── 4. 合并 manifest（只改自己那段）──────────────────────────
PREV="$STAGE_DIR/.latest-prev.json"
curl -sf --max-time 8 "$SERVER/api/app/latest" \
  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("data") or {}))' \
  > "$PREV" 2>/dev/null || echo '{}' > "$PREV"

python3 - "$STAGE_DIR/latest.json" "$PREV" "$MANIFEST_VER" "$FIRST_FILE" "$FIRST_SHA" "$FIRST_SIG" \
  "$FIRST_SIZE" "$NOTES" "$TAKEOVER" "$TAKEOVER_ZIP" "$TAKEOVER_SHA" "$TAKEOVER_SIG" "$TAKEOVER_SIZE" \
  "$TAKEOVER_DMG" "$TAKEOVER_DMG_SHA" "$TAKEOVER_DMG_SIG" "$TAKEOVER_DMG_SIZE" \
  "${MANIFEST_ARGS[@]}" <<'PY'
import json, sys, os

args = sys.argv[1:]
path, prev_path, version, first_file, first_sha, first_sig, first_size, notes = args[:8]
takeover = args[8] == '1'
tz_file, tz_sha, tz_sig, tz_size = args[9:13]
tz_dmg, tz_dmg_sha, tz_dmg_sig, tz_dmg_size = args[13:17]
pairs = args[17:]

try:
    merged = json.load(open(prev_path))
    if not isinstance(merged, dict):
        merged = {}
except Exception:
    merged = {}

mac_files = {}
for i in range(0, len(pairs), 5):
    arch, filename, sha, sig, size = pairs[i:i+5]
    mac_files[arch] = {"file": filename, "sha256": sha, "signature": sig, "size": int(size)}

merged.update({
    "macVersion": version,
    "macFile": first_file,
    "macSHA256": first_sha,
    "macSignature": first_sig,
    "macSize": int(first_size),
    "macNotes": notes,
    "macFiles": mac_files,
})
if takeover:
    merged.update({
        "version": version,
        "file": os.path.basename(tz_file),
        "sha256": tz_sha,
        "signature": tz_sig,
        "size": int(tz_size),
        "notes": notes,
        # Swift 客户端优先用 dmg：必须一起接管，否则会拿老 Swift dmg 把用户替换回旧版
        "dmgFile": os.path.basename(tz_dmg),
        "dmgSHA256": tz_dmg_sha,
        "dmgSignature": tz_dmg_sig,
        "dmgSize": int(tz_dmg_size),
    })

json.dump(merged, open(path, 'w'), ensure_ascii=False, indent=2)
kept = [k for k in ("version", "winVersion") if merged.get(k)]
print("   现有其它通道: " + (", ".join(f"{k}={merged[k]}" for k in kept) or "（无）"))
PY

if [ "$ARCH" != "both" ]; then
  say ""
  say "⚠️  本次只发了一个架构，官网会提示「当前仅提供该架构」，客户端也不会跨架构回落。"
fi

# ── 5. 上传 / 预演 ──────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  say ""
  say "── --dry-run 生成的 latest.json（未上传）──"
  python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])), ensure_ascii=False, indent=2))" "$STAGE_DIR/latest.json"
  say ""
  say "✅ --dry-run 完成：包已签名并通过自检，未上传任何文件"
  rm -f "$PREV" "$STAGE_DIR/latest.json"
  exit 0
fi

say ""
say "上传到服务器…"
remote_exec "mkdir -p $REMOTE_DIR" >/dev/null 2>&1 || fail "远端创建 $REMOTE_DIR 失败"
for a in arm64 x64; do
  if [ "$ARCH" != "both" ] && [ "$ARCH" != "$a" ]; then continue; fi
  DMG=$(pick_dmg "$a")
  remote_put "$DMG" "$REMOTE_DIR/$(basename "$DMG")" || fail "上传 $a dmg 失败"
done
if [ "$TAKEOVER" = "1" ]; then
  remote_put "$TAKEOVER_ZIP" "$REMOTE_DIR/$(basename "$TAKEOVER_ZIP")" || fail "上传 universal zip 失败"
  remote_put "$TAKEOVER_DMG" "$REMOTE_DIR/$(basename "$TAKEOVER_DMG")" || fail "上传 universal dmg 失败"
fi
remote_put "$STAGE_DIR/latest.json" "$REMOTE_DIR/latest.json" || fail "上传 manifest 失败"

# ── 6. 验证 ────────────────────────────────────────────────
say ""
say "验证服务器发布结果…"
python3 - "$SERVER" "$MANIFEST_VER" "$TAKEOVER" "${MANIFEST_ARGS[@]}" <<'PY'
import hashlib, json, sys, urllib.request

server, version, takeover = sys.argv[1:4]
pairs = sys.argv[4:]
with urllib.request.urlopen(server + "/api/app/latest", timeout=10) as r:
    data = json.load(r)["data"]

if data.get("macVersion") != version:
    sys.exit(f"❌ macVersion={data.get('macVersion')} != 期望 {version}")

files = data.get("macFiles") or {}
for i in range(0, len(pairs), 5):
    arch, filename, sha = pairs[i], pairs[i+1], pairs[i+2]
    entry = files.get(arch) or {}
    if entry.get("file") != filename:
        sys.exit(f"❌ macFiles.{arch}.file={entry.get('file')} != {filename}")
    if entry.get("sha256") != sha:
        sys.exit(f"❌ macFiles.{arch}.sha256 与本地不一致（上传可能被截断）")

if takeover == '1':
    if not data.get("file"):
        sys.exit("❌ 接管 Swift 通道后 version/file 为空")
    if not data.get("dmgFile"):
        sys.exit("❌ 接管 Swift 通道后 dmgFile 为空（Swift 客户端会退回旧 dmg）")

print(f"✅ 发布验证通过：{version} | 架构 {', '.join(files)} | macFile {data.get('macFile')}")
PY

say ""
say "🎉 Electron macOS 发布完成：$MANIFEST_VER"
say "   官网：按访客 CPU 自动选 arm64 / x64（也可手动切换）"
say "   客户端：下次检查更新（启动 30 秒 / 每 24 小时 / 托盘「检查更新」）即可看到"
[ "$TAKEOVER" = "1" ] && say "   ⚠️ 已接管 Swift 通道：老 Swift 用户检查更新会被换成 Electron 版"
