#!/usr/bin/env bash
set -euo pipefail

# 本地打 Electron Windows 包（不上传、不签名、不发远程）
#
# 用途：在 mac 上交叉打 Windows 安装包做本机验证 —— 双击装一下看看界面/托盘/自更新入口对不对。
# 要给线上用户用（官网可下载 + 自动更新）请走同目录的 deploy-win.sh。
#
# 用法:
#   build-win-local.sh                    # 清旧 Windows 产物 → 按 package.json 版本打包（x64）
#   build-win-local.sh --version 0.0.3    # 先把 package.json 版本改成 0.0.3 再打包
#   build-win-local.sh --arm64            # 打 ARM64
#   build-win-local.sh --no-clean         # 保留旧产物（不推荐，容易发错版本）
#   build-win-local.sh --dry-run          # 只预览将清理什么、将打哪个版本，不打包
#
# 产物：DesktopPetElectron/dist/DesktopPet Setup <版本>.exe（安装版）+ DesktopPet <版本>.exe（便携版）
#       —— 只有安装版 exe 支持应用内自动更新，便携版无法自我替换。

SCRIPT_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_REAL")
REPO="${CUTE_PET_REPO:-$(cd "$SCRIPTS_DIR/../../.." && pwd)}"
ELECTRON_DIR="$REPO/DesktopPetElectron"
DIST_DIR="$ELECTRON_DIR/dist"

ARCH="x64"
DO_CLEAN=1
DRY_RUN=0
NEW_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arm64) ARCH="arm64" ;;
    --no-clean) DO_CLEAN=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --version) shift; NEW_VERSION="${1:-}" ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 查看用法）" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
fail() { say "❌ $*"; exit 1; }

[ -d "$ELECTRON_DIR" ] || fail "未找到 Electron 工程：$ELECTRON_DIR（可用 CUTE_PET_REPO 指定仓库）"
[ -f "$ELECTRON_DIR/package.json" ] || fail "缺少 $ELECTRON_DIR/package.json"

if [ -n "$NEW_VERSION" ]; then
  if ! printf '%s' "$NEW_VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)+(-[A-Za-z0-9.]+)?$'; then
    fail "版本号格式不对：$NEW_VERSION（例：0.0.3，本机验证包可用 0.0.3-test）"
  fi
fi

CUR_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ELECTRON_DIR/package.json")
TARGET_VERSION="${NEW_VERSION:-$CUR_VERSION}"
say "Electron 工程     : $ELECTRON_DIR"
say "当前 package 版本 : $CUR_VERSION"
say "本次打包版本      : $TARGET_VERSION（$ARCH）"

if [ "$DRY_RUN" = "1" ]; then
  say ""
  say "将清理的 Windows 旧产物（预览）："
  bash "$SCRIPTS_DIR/clean-win-dist.sh" --dry-run | sed 's/^/  /'
  say ""
  say "✅ --dry-run 结束：未改版本号、未打包"
  exit 0
fi

# 1. 清旧 Windows 产物（保留 mac 的 dmg/zip）
if [ "$DO_CLEAN" = "1" ]; then
  say ""
  say "清理旧 Windows 产物…"
  bash "$SCRIPTS_DIR/clean-win-dist.sh" >/dev/null
  say "   已清理（只删了 *.exe / *.exe.blockmap / latest.yml / win-*，mac 产物保留）"
fi

# 2. 写版本号（不写就沿用 package.json 现有版本）
if [ -n "$NEW_VERSION" ]; then
  python3 - "$ELECTRON_DIR/package.json" "$NEW_VERSION" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data['version'] = version
with open(path, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
  say "   已把 package.json 版本写成 $NEW_VERSION"
fi

# 3. 打包
say ""
say "调用 electron-builder 打包 Windows（$ARCH）…"
cd "$ELECTRON_DIR"
LOG=/tmp/build_win_local.log
if [ "$ARCH" = "arm64" ]; then
  npm run dist:win:arm64 > "$LOG" 2>&1 || { tail -30 "$LOG"; fail "打包失败（日志 $LOG）"; }
else
  npm run dist:win > "$LOG" 2>&1 || { tail -30 "$LOG"; fail "打包失败（日志 $LOG）"; }
fi
say "   打包完成（日志 $LOG）"

# 4. 汇总产物
say ""
say "产物清单："
find "$DIST_DIR" -maxdepth 1 -name "*.exe" -print0 | while IFS= read -r -d '' f; do
  size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
  mb=$(python3 -c "import sys; print(f'{int(sys.argv[1])/1024/1024:.1f}')" "$size")
  case "$(basename "$f")" in
    *Setup*) kind="安装版（可自动更新）" ;;
    *) kind="便携版（不能自动更新）" ;;
  esac
  say "  • $(basename "$f")  ${mb} MB  — $kind"
done

say ""
say "✅ 本地 Windows 包已就绪（未签名、未上传、未发远程）"
say "   本机试用：把 exe 拷到 Windows 机器双击安装即可"
say "   正式发布：./skills/cute-pet-deploy/scripts/deploy-win.sh \"$TARGET_VERSION\" \"用户看得懂的更新说明\""
