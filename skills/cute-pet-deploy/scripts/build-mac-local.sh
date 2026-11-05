#!/usr/bin/env bash
set -euo pipefail

# 本地发 Swift 版（macOS 原生 cute pet）—— 只影响本机，不上传、不签名、不发远程
#
# 三种本地发布口径：
#   默认           编译 → 覆盖桌面的 cute pet.app → 杀掉旧进程 → 启动（等价 rebuild.sh）
#   --no-launch    编译 → 覆盖桌面的 cute pet.app → 杀掉旧进程，但不启动
#   --no-desktop   编译 → 只产出仓库内 DesktopPetForMacApp/cute pet.app，不动桌面那份、不杀进程
#                  （正在跑的旧版本继续可用，适合"先看编译产物，稍后再换"）
#
# 要给全量用户升级（官网可下载 + 客户端自动更新）请走同目录的 deploy.sh（远程 Swift 版）。
#
# 用法:
#   build-mac-local.sh
#   build-mac-local.sh --no-launch
#   build-mac-local.sh --no-desktop

SCRIPT_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_REAL")
REPO="${CUTE_PET_REPO:-$(cd "$SCRIPTS_DIR/../../.." && pwd)}"
APP_DIR="$REPO/DesktopPetForMacApp"
APP_NAME="cute pet"
DEST_APP="$HOME/Desktop/$APP_NAME.app"

MODE="launch"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-launch) MODE="no-launch" ;;
    --no-desktop) MODE="no-desktop" ;;
    -h|--help) sed -n '3,18p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 查看用法）" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
fail() { say "❌ $*"; exit 1; }

[ -d "$APP_DIR" ] || fail "未找到 App 工程：$APP_DIR（可用 CUTE_PET_REPO 指定仓库）"
[ -x "$APP_DIR/package.sh" ] || fail "缺少打包脚本：$APP_DIR/package.sh"

CUR_VER=$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' \
  "$APP_DIR/DesktopPetForMacApp/App/AppVersion.swift" | head -1)
say "仓库            : $REPO"
say "源码版本号      : ${CUR_VER:-未知}（本地发布不改版本号，改版本请用 deploy.sh）"
say "模式            : $MODE"

cd "$APP_DIR"

case "$MODE" in
  launch)
    say ""
    say "编译 + 打包到桌面 + 重启…"
    bash "$APP_DIR/rebuild.sh"
    ;;
  no-launch)
    say ""
    say "编译 + 打包到桌面（不启动）…"
    pkill -f "DesktopPetForMacApp" 2>/dev/null || true
    pkill -f "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    bash "$APP_DIR/package.sh" || fail "package.sh 执行失败"
    [ -d "$DEST_APP" ] || fail "未产出 $DEST_APP"
    say ""
    say "✅ 已更新本机：$DEST_APP（未启动，双击图标即可）"
    ;;
  no-desktop)
    say ""
    say "编译 + 打包到仓库内（不动桌面那份）…"
    SKIP_DESKTOP_COPY=1 bash "$APP_DIR/package.sh" || fail "package.sh 执行失败"
    BUILT="$APP_DIR/$APP_NAME.app"
    [ -d "$BUILT" ] || fail "未产出 $BUILT"
    say ""
    say "✅ 已产出：$BUILT"
    say "   桌面上的旧版本未改动，仍在运行"
    ;;
esac
