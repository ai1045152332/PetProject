#!/usr/bin/env bash
set -euo pipefail

# 发布 cute pet App 到远程服务器（编译 → 签名 → 上传 → 验证）
# 用法:
#   deploy.sh                       # 自动递增补丁版本，说明「常规更新」
#   deploy.sh v1.0.016 "更新说明"    # 指定版本与说明
#   deploy.sh --check                # 只检查环境与下一个版本号，不发布
#   COMMIT=1 deploy.sh ...           # 发布后顺带提交并推送 git

# 仓库根目录：默认从脚本真实位置推断（skills/deploy-cute-pet/scripts → 上三级），
# 同时兼容通过 ~/.codex/skills 的符号链接调用
SCRIPT_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")
REPO_DEFAULT=$(cd "$(dirname "$SCRIPT_REAL")/../../.." && pwd)
REPO="${CUTE_PET_REPO:-$REPO_DEFAULT}"
APP_DIR="$REPO/DesktopPetForMacApp"
SERVER="${CUTE_PET_SERVER:-http://101.96.248.75}"
KEY_DIR="${CUTE_PET_KEY_DIR:-$HOME/.cute-pet-release}"
MODE="deploy"
if [ "${1:-}" = "--check" ]; then MODE="check"; shift; fi
VERSION="${1:-}"
NOTES="${2:-常规更新}"

say() { printf '%s\n' "$*"; }
fail() { say "❌ $*"; exit 1; }

# ── 1. 环境检查 ──────────────────────────────────────────────
[ -d "$APP_DIR" ] || fail "未找到 App 目录：$APP_DIR（可用 CUTE_PET_REPO 指定仓库路径）"
[ -x "$APP_DIR/release.sh" ] || fail "未找到可执行 release.sh：$APP_DIR/release.sh"
[ -f "$KEY_DIR/ed25519_private.pem" ] || fail "缺少发布签名私钥：$KEY_DIR/ed25519_private.pem"
if [ ! -x "$KEY_DIR/scp_put.exp" ] || [ ! -x "$KEY_DIR/ssh_run.exp" ]; then
  fail "缺少上传助手脚本：$KEY_DIR/{scp_put,ssh_run}.exp"
fi
curl -sf --max-time 8 "$SERVER/api/ping" >/dev/null || fail "服务器不可达：$SERVER/api/ping"

LATEST=$(curl -sf --max-time 8 "$SERVER/api/app/latest" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)['data']['version'])
except Exception:
    print('')
" || true)
CUR_SRC=$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' "$APP_DIR/DesktopPetForMacApp/App/AppVersion.swift" | head -1)

say "服务器最新版本: ${LATEST:-（尚未发布）}"
say "源码当前版本  : ${CUR_SRC:-未知}"

# ── 2. 解析/递增版本号 ───────────────────────────────────────
next_version() {
  python3 - "$1" <<'PY'
import sys
v = sys.argv[1].lstrip('vV')
parts = v.split('.')
if len(parts) >= 3 and parts[2].isdigit():
    width = len(parts[2])                 # 保持补零位宽：015 -> 016
    parts[2] = str(int(parts[2]) + 1).zfill(width)
else:
    parts.append('1')
print('v' + '.'.join(parts))
PY
}

if [ -z "$VERSION" ]; then
  VERSION=$(next_version "${LATEST:-${CUR_SRC:-v1.0.0}}")
fi
case "$VERSION" in v*) ;; *) VERSION="v$VERSION" ;; esac

if [ "$VERSION" = "$LATEST" ]; then
  fail "版本号 $VERSION 与服务器最新版本相同；同一版本号不要重复发布不同内容，请递增（如 $(next_version "$LATEST")）"
fi

say "计划发布版本  : $VERSION"
say "更新说明      : $NOTES"

if [ "$MODE" = "check" ]; then
  say "✅ 环境检查通过（未发布）"
  exit 0
fi

# ── 3. 发布 ──────────────────────────────────────────────────
cd "$APP_DIR"
say ""
say "开始发布（编译 + 打包 + 签名 + 上传）…"
./release.sh "$VERSION" "$NOTES" || fail "release.sh 执行失败"

# ── 4. 验证 ──────────────────────────────────────────────────
say ""
say "验证服务器发布结果…"
python3 - "$SERVER" "$VERSION" "$APP_DIR" <<'PY'
import hashlib, json, os, sys, urllib.request

server, version, app_dir = sys.argv[1], sys.argv[2], sys.argv[3]
with urllib.request.urlopen(server + "/api/app/latest", timeout=10) as r:
    data = json.load(r)["data"]

if data["version"] != version:
    sys.exit(f"❌ 服务器版本 {data['version']} != 期望 {version}")

zip_path = os.path.join(app_dir, "dist", data["file"])
if not os.path.exists(zip_path):
    sys.exit(f"❌ 本地未找到安装包 {zip_path}")

h = hashlib.sha256()
with open(zip_path, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
if h.hexdigest() != data["sha256"]:
    sys.exit("❌ 本地包 sha256 与服务器 manifest 不一致")

print(f"✅ 发布验证通过：{data['version']} | {data['file']} | {data['sha256'][:16]}…")
PY

# ── 5. 可选：提交并推送 git ─────────────────────────────────
if [ "${COMMIT:-0}" = "1" ]; then
  cd "$REPO"
  git add -A
  git commit -m "release: $VERSION — $NOTES" || say "（无改动可提交）"
  git pull --rebase origin main >/dev/null 2>&1 || true
  git push origin main || fail "git push 失败"
  say "✅ 代码已提交并推送"
fi

say ""
say "🎉 发布完成：$VERSION"
say "   客户端将在 启动 30 秒 / 每 6 小时 / 设置面板「检查更新」 时自动升级"
say "   注意：不要在本机 rebuild.sh，除非就是要让本机立刻升级（否则会失去更新测试机会）"
