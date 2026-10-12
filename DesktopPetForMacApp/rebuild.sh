#!/usr/bin/env bash
set -euo pipefail

# DesktopPetForMacApp 一键重建脚本
# 流程：编译 → 打包 → 杀旧进程 → 启动

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="petNoUse"
DEST_APP="$HOME/Desktop/$APP_NAME.app"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DesktopPetForMacApp 一键重建"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. 编译 ─────────────────────────────────────────────────────
echo ""
echo "🔨 [1/3] 编译 Release…"
cd "$SCRIPT_DIR"
swift build -c release --disable-sandbox

BUILD_BIN="$SCRIPT_DIR/.build/release/DesktopPetForMacApp"
if [ ! -f "$BUILD_BIN" ]; then
    echo "❌ 编译失败：未找到 $BUILD_BIN"
    exit 1
fi
echo "   ✅ 编译成功"

# ── 2. 打包 ─────────────────────────────────────────────────────
echo ""
echo "📦 [2/3] 打包…"

# 杀旧进程（打包前先杀，避免文件占用）
pkill -f "DesktopPetForMacApp" 2>/dev/null || true
pkill -f "$APP_NAME" 2>/dev/null || true
sleep 0.5

# 复用 package.sh 的打包逻辑
bash "$SCRIPT_DIR/package.sh"

# ── 3. 启动 ─────────────────────────────────────────────────────
echo ""
echo "🚀 [3/3] 启动…"
sleep 0.5
open "$DEST_APP"

echo ""
echo "✅ 全部完成！"
echo "   路径: $DEST_APP"
echo ""
