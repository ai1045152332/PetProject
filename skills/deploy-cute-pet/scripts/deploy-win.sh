#!/usr/bin/env bash
set -euo pipefail

# 发布 Electron Windows 版到远程服务器（打包 → 签名 → 合并 manifest → 上传 → 验证）
# 这是「远程 Windows 版」的唯一入口：发完之后官网可下载、已装 Windows 客户端能自动更新。
#
# 用法:
#   deploy-win.sh                          # 自动递增 electron 补丁版本，说明「常规更新」
#   deploy-win.sh electron0.0.3 "更新说明"  # 指定版本（写成 0.0.3 也可以）
#   deploy-win.sh --check                  # 只检查环境、打印计划版本，不打包不上传
#   deploy-win.sh --skip-build             # 复用 dist 里已打好的包（不重新 npm run dist:win）
#   deploy-win.sh --dry-run                # 跑到签名 + 生成 manifest 就停，不上传（预演用）
#   deploy-win.sh --arm64                  # 打 ARM64（默认 x64，绝大多数 Windows 机器用这个）
#
# 安全边界：
#   - 只上传 NSIS 安装版 setup.exe（portable 便携版无法自我替换，不能做自动更新）
#   - manifest 是「合并写」：只改 win* 字段，mac 原生版 / Electron macOS 字段原样保留
#   - 上传后回读 /api/app/latest 校验 winVersion/winSHA256，并确认 mac 通道没被抹掉

SCRIPT_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_REAL")
REPO="${CUTE_PET_REPO:-$(cd "$SCRIPTS_DIR/../../.." && pwd)}"
ELECTRON_DIR="$REPO/DesktopPetElectron"
SERVER="${CUTE_PET_SERVER:-http://101.96.248.75}"
KEY_DIR="${CUTE_PET_KEY_DIR:-$HOME/.cute-pet-release}"
PRIVATE_KEY="$KEY_DIR/ed25519_private.pem"
REMOTE_DIR="${CUTE_PET_REMOTE_DIST:-/opt/petserver/dist}"
# 远端执行/上传统一后端（expect 助手不可用时自动切 paramiko）
source "$SCRIPTS_DIR/remote.sh"

MODE="deploy"
SKIP_BUILD=0
DRY_RUN=0
ARCH="x64"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --skip-build) SKIP_BUILD=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --arm64) ARCH="arm64" ;;
    *) ARGS+=("$arg") ;;
  esac
done
VERSION="${ARGS[0]:-}"
NOTES="${ARGS[1]:-常规更新}"

say() { printf '%s\n' "$*"; }
fail() { say "❌ $*"; exit 1; }

# ── 1. 环境检查 ──────────────────────────────────────────────
[ -d "$ELECTRON_DIR" ] || fail "未找到 Electron 工程：$ELECTRON_DIR（可用 CUTE_PET_REPO 指定仓库）"
[ -f "$ELECTRON_DIR/package.json" ] || fail "缺少 $ELECTRON_DIR/package.json"
[ -f "$PRIVATE_KEY" ] || fail "缺少发布签名私钥：$PRIVATE_KEY"
if [ ! -x "$KEY_DIR/scp_put.exp" ]; then
  say "ℹ️ 无 expect 上传助手，将使用 paramiko（python3 + ~/.catpaw/pylibs）"
fi
if [ "$MODE" = "deploy" ] && [ "$SKIP_BUILD" != "1" ]; then
  command -v npm >/dev/null || fail "未找到 npm（打包 Electron 需要 Node 环境）"
  [ -d "$ELECTRON_DIR/node_modules" ] || fail "缺少 $ELECTRON_DIR/node_modules，先在该目录执行 npm install"
fi
curl -sf --max-time 8 "$SERVER/api/ping" >/dev/null || fail "服务器不可达：$SERVER/api/ping"

read_manifest_field() {
  curl -sf --max-time 8 "$SERVER/api/app/latest" | python3 -c "
import sys, json
field = sys.argv[1]
try:
    print(json.load(sys.stdin)['data'].get(field) or '')
except Exception:
    print('')
" "$1" 2>/dev/null || true
}

REMOTE_WIN_VER=$(read_manifest_field winVersion)
REMOTE_MAC_VER=$(read_manifest_field version)
LOCAL_PKG_VER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ELECTRON_DIR/package.json")

say "服务器 Windows 版: ${REMOTE_WIN_VER:-（尚未发布）}"
say "服务器 mac 原生版 : ${REMOTE_MAC_VER:-（尚未发布）}"
say "package.json 版本 : $LOCAL_PKG_VER"
say "打包架构          : $ARCH"
say "远端后端          : $(remote_backend)"

# ── 2. 解析版本号 ───────────────────────────────────────────
# 纯数字版本（0.0.3）；manifest 里存 electron 前缀形式，包内 package.json 只写数字
plain_version() {
  python3 - "$1" <<'PY'
import re, sys
v = sys.argv[1].strip()
v = re.sub(r'^electron', '', v, flags=re.I)
v = re.sub(r'^[vV]', '', v)
print(v)
PY
}

next_version() {
  python3 - "$1" <<'PY'
import sys
v = sys.argv[1].strip() or '0.0.0'
parts = v.split('.')[:3]
while len(parts) < 3:
    parts.append('0')
width = len(parts[2])
parts[2] = str(int(parts[2]) + 1).zfill(width) if parts[2].isdigit() else '1'
print('.'.join(parts))
PY
}

if [ -z "$VERSION" ]; then
  # 起点取「服务器已发的 Windows 版」与「本地 package.json」中较大的那个，避免版本回退
  BASE=$(python3 - "$(plain_version "${REMOTE_WIN_VER:-0.0.0}")" "$(plain_version "$LOCAL_PKG_VER")" <<'PY'
import sys
def key(v):
    try:
        return tuple(int(x) for x in v.split('.'))
    except Exception:
        return (0,)
print(max(sys.argv[1], sys.argv[2], key=key))
PY
)
  PLAIN=$(next_version "$BASE")
else
  PLAIN=$(plain_version "$VERSION")
fi

if ! printf '%s' "$PLAIN" | grep -Eq '^[0-9]+(\.[0-9]+)+$'; then
  fail "版本号格式不对：$VERSION（Windows 版只接受纯数字，如 0.0.3；不要带 v/electron 前缀与 -tag 后缀）"
fi

# --skip-build 复用旧产物时，版本必须与包内 package.json 一致，否则会发出「版本号与内容不符」的包
if [ "$SKIP_BUILD" = "1" ]; then
  PKG_PLAIN=$(plain_version "$LOCAL_PKG_VER")
  if [ -z "${VERSION:-}" ]; then
    PLAIN="$PKG_PLAIN"
  elif [ "$PLAIN" != "$PKG_PLAIN" ]; then
    fail "--skip-build 用的是 dist 里 ${PKG_PLAIN} 的包，不能声明成 $PLAIN（要发新版本请去掉 --skip-build 重新打包）"
  fi
fi
WIN_VERSION="electron$PLAIN"
if [ "$WIN_VERSION" = "$REMOTE_WIN_VER" ]; then
  fail "版本号 $WIN_VERSION 与服务器 Windows 版相同；同一版本号不要重复发布不同内容，请递增（如 $(next_version "$PLAIN")）"
fi

say "计划发布版本      : $WIN_VERSION（包内 package.json → $PLAIN）"
say "更新说明          : $NOTES"

if [ "$MODE" = "check" ]; then
  say "✅ 环境检查通过（未打包、未上传）"
  exit 0
fi

# ── 3. 写版本号 + 打包 ──────────────────────────────────────
DIST_DIR="$ELECTRON_DIR/dist"
if [ "$SKIP_BUILD" = "1" ]; then
  say ""
  say "跳过打包（--skip-build），复用 dist 现有产物…"
else
  say ""
  if [ "$DRY_RUN" = "1" ]; then
    say "--dry-run：跳过清理旧产物（不删现有 exe，便于对比）"
  else
    say "清理旧 Windows 产物…"
    bash "$SCRIPTS_DIR/clean-win-dist.sh" >/dev/null
  fi
  say "写入 package.json 版本号 → $PLAIN…"
  python3 - "$ELECTRON_DIR/package.json" "$PLAIN" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data['version'] = version
with open(path, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
  say "打包 Windows（$ARCH）…"
  cd "$ELECTRON_DIR"
  if [ "$ARCH" = "arm64" ]; then
    npm run dist:win:arm64 > /tmp/deploy_win_build.log 2>&1 \
      || { tail -30 /tmp/deploy_win_build.log; fail "electron-builder 打包失败（日志 /tmp/deploy_win_build.log）"; }
  else
    npm run dist:win > /tmp/deploy_win_build.log 2>&1 \
      || { tail -30 /tmp/deploy_win_build.log; fail "electron-builder 打包失败（日志 /tmp/deploy_win_build.log）"; }
  fi
fi

# ── 4. 选包（只认 NSIS setup，便携版不能自动更新）──
STEM="DesktopPet Setup $PLAIN"
if [ "$ARCH" = "arm64" ]; then STEM="$STEM-arm64"; fi
SRC_EXE="$DIST_DIR/$STEM.exe"
if [ ! -f "$SRC_EXE" ]; then
  # 兜底：按名字模糊找 setup，绝不匹配 "DesktopPet <ver>.exe"（portable）
  SRC_EXE=$(find "$DIST_DIR" -maxdepth 1 -name "*Setup*${PLAIN}*.exe" | head -1)
fi
[ -n "$SRC_EXE" ] && [ -f "$SRC_EXE" ] \
  || fail "未找到 NSIS 安装包（期望 $DIST_DIR/$STEM.exe）。若 dist 里只有「DesktopPet <版本>.exe」，那是便携版，不能用于自动更新"

# 上传用文件名去掉空格，避免 URL 与 shell 转义问题
SUFFIX=""
if [ "$ARCH" = "arm64" ]; then SUFFIX="-arm64"; fi
WIN_FILE="desktop-pet-win-$PLAIN$SUFFIX-setup.exe"
STAGE_DIR="$DIST_DIR/.win-release"
mkdir -p "$STAGE_DIR"
STAGED_EXE="$STAGE_DIR/$WIN_FILE"
cp -f "$SRC_EXE" "$STAGED_EXE"

EXE_SIZE=$(stat -f%z "$STAGED_EXE" 2>/dev/null || stat -c%s "$STAGED_EXE")
EXE_MB=$(python3 -c "import sys; print(f'{int(sys.argv[1])/1024/1024:.1f}')" "$EXE_SIZE")
say ""
say "安装包           : $(basename "$SRC_EXE") → $WIN_FILE（${EXE_MB} MB）"

# ── 5. sha256 + Ed25519 签名（签名对象 = sha256 hex 字符串）──
WIN_SHA=$(shasum -a 256 "$STAGED_EXE" | awk '{print $1}')
printf '%s' "$WIN_SHA" > /tmp/deploy_win_digest.txt
WIN_SIG=$(openssl pkeyutl -sign -rawin -inkey "$PRIVATE_KEY" -in /tmp/deploy_win_digest.txt | base64 | tr -d '\n')
say "sha256           : $WIN_SHA"

# 签名自检：用公钥验一遍，避免私钥损坏/公钥不匹配的包被发上线
PUB_B64_FILE="$KEY_DIR/ed25519_public.b64"
if [ -f "$PUB_B64_FILE" ]; then
  python3 - "$PUB_B64_FILE" "$STAGE_DIR/.pub.der" <<'PY'
import base64, sys
raw = base64.b64decode(open(sys.argv[1]).read().strip())
if len(raw) != 32:
    sys.exit("公钥不是 32 字节 Ed25519 raw key")
open(sys.argv[2], 'wb').write(bytes.fromhex('302a300506032b6570032100') + raw)
PY
  printf '%s' "$WIN_SIG" | base64 -d > "$STAGE_DIR/.sig.bin"
  if openssl pkeyutl -verify -pubin -inkey "$STAGE_DIR/.pub.der" -keyform DER \
       -rawin -in /tmp/deploy_win_digest.txt -sigfile "$STAGE_DIR/.sig.bin" >/dev/null 2>&1; then
    say "签名自检         : ✅ 与发布公钥匹配"
  else
    fail "签名自检失败：私钥与 ed25519_public.b64 不匹配（客户端会报验签失败）"
  fi
  rm -f "$STAGE_DIR/.pub.der" "$STAGE_DIR/.sig.bin"
fi
rm -f /tmp/deploy_win_digest.txt

# ── 6. 合并 manifest（只改 win*，保留 mac 原生 + Electron macOS 字段）──
PREV="$STAGE_DIR/.latest-prev.json"
curl -sf --max-time 8 "$SERVER/api/app/latest" \
  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("data") or {}))' \
  > "$PREV" 2>/dev/null || echo '{}' > "$PREV"

python3 - "$STAGE_DIR/latest.json" "$PREV" "$WIN_VERSION" "$WIN_FILE" "$WIN_SHA" "$WIN_SIG" "$NOTES" "$EXE_SIZE" <<'PY'
import json, sys
(path, prev_path, version, filename, sha, sig, notes, size) = sys.argv[1:9]
try:
    merged = json.load(open(prev_path))
    if not isinstance(merged, dict):
        merged = {}
except Exception:
    merged = {}
merged.update({
    "winVersion": version,
    "winFile": filename,
    "winSHA256": sha,
    "winSignature": sig,
    "winNotes": notes,
    "winSize": int(size),
})
json.dump(merged, open(path, 'w'), ensure_ascii=False, indent=2)
kept = [k for k in ("version", "dmgFile", "macVersion") if merged.get(k)]
print("   保留的其它通道: " + (", ".join(f"{k}={merged[k]}" for k in kept) or "（无）"))
PY

# ── 7. 上传（先传包，最后换 manifest，避免出现指向不存在文件的清单）──
if [ "$DRY_RUN" = "1" ]; then
  say ""
  say "── --dry-run 生成的 latest.json（未上传）──"
  python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])), ensure_ascii=False, indent=2))" "$STAGE_DIR/latest.json"
  say ""
  say "✅ --dry-run 完成：安装包已签名并通过自检，未上传任何文件"
  say "   去掉 --dry-run 正式发布：./skills/deploy-cute-pet/scripts/deploy-win.sh \"$PLAIN\" \"$NOTES\""
  rm -f "$PREV" "$STAGE_DIR/latest.json"
  exit 0
fi

say ""
say "上传到服务器…"
remote_exec "mkdir -p $REMOTE_DIR" >/dev/null 2>&1 || fail "远端创建 $REMOTE_DIR 失败"
remote_put "$STAGED_EXE" "$REMOTE_DIR/$WIN_FILE" || fail "上传安装包失败"
remote_put "$STAGE_DIR/latest.json" "$REMOTE_DIR/latest.json" || fail "上传 manifest 失败"

# ── 8. 验证 ────────────────────────────────────────────────
say ""
say "验证服务器发布结果…"
python3 - "$SERVER" "$WIN_VERSION" "$WIN_FILE" "$WIN_SHA" "$STAGED_EXE" <<'PY'
import hashlib, json, sys, urllib.request

server, version, filename, sha, local_exe = sys.argv[1:6]
with urllib.request.urlopen(server + "/api/app/latest", timeout=10) as r:
    data = json.load(r)["data"]

if data.get("winVersion") != version:
    sys.exit(f"❌ winVersion={data.get('winVersion')} != 期望 {version}")
if data.get("winFile") != filename:
    sys.exit(f"❌ winFile={data.get('winFile')} != 期望 {filename}")
if data.get("winSHA256") != sha:
    sys.exit("❌ winSHA256 与本地构建不一致（上传可能被截断）")
if not data.get("winSignature"):
    sys.exit("❌ winSignature 缺失")
if not data.get("file") or not data.get("version"):
    sys.exit("❌ mac 原生版字段丢失（manifest 被覆盖），Windows 发布挤掉了 mac 更新通道")

h = hashlib.sha256()
with open(local_exe, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
if h.hexdigest() != sha:
    sys.exit("❌ 本地安装包 sha256 与已签名摘要不一致")

# 远端可下载性（只取 2 字节，避免拉 80MB）
req = urllib.request.Request(server + "/download/" + filename, headers={"Range": "bytes=0-1"})
with urllib.request.urlopen(req, timeout=15) as r:
    if r.status not in (200, 206):
        sys.exit(f"❌ 安装包不可下载：HTTP {r.status}")

print(f"✅ 远程 Windows 版发布通过：{data['winVersion']} | {filename} | {sha[:16]}…")
print(f"   mac 原生通道保留：{data['version']} | {data['file']}")
if data.get("macVersion"):
    print(f"   Electron macOS 通道保留：{data['macVersion']}")
print("   Windows 客户端将在 启动 30 秒 / 每 24 小时 / 托盘「检查更新」时自动升级")
print(f"   官网下载：{server}/ （页面读取 winFile 生成 Windows 下载按钮）")
PY

rm -f "$PREV" "$STAGE_DIR/latest.json"
say ""
say "🎉 发布完成：$WIN_VERSION"
