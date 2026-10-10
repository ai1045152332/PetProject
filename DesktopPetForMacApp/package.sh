#!/usr/bin/env bash
set -euo pipefail

# DesktopPetForMacApp 打包脚本
# 产出 DesktopPetForMacApp.app 到桌面

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DesktopPetForMacApp"
DESKTOP="$HOME/Desktop"

# ── 1. Release 编译 ──────────────────────────────────────────────
echo "🔨 编译 Release 二进制…"
swift build -c release --disable-sandbox

BUILD_BIN="$PROJECT_DIR/.build/release/$APP_NAME"

if [ ! -f "$BUILD_BIN" ]; then
    echo "❌ 编译失败：未找到 $BUILD_BIN"
    exit 1
fi

# ── 2. 清理旧的 .app ────────────────────────────────────────────
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
DEST_APP="$DESKTOP/$APP_NAME.app"

rm -rf "$APP_BUNDLE"
if [ -d "$DEST_APP" ]; then
    echo "🗑️   删除桌面旧版 $DEST_APP"
    rm -rf "$DEST_APP"
fi

# ── 3. 拼装 .app 目录结构 ───────────────────────────────────────
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SPRITES_SRC="$PROJECT_DIR/DesktopPetForMacApp/Resources/Sprites"

mkdir -p "$MACOS" "$RESOURCES/Sprites"

# 可执行文件
cp "$BUILD_BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# 应用图标（.icns 格式）
ICON_SRC="$PROJECT_DIR/DesktopPetForMacApp/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$RESOURCES/AppIcon.icns"
fi

# 菜单栏图标
MENU_ICON="$PROJECT_DIR/DesktopPetForMacApp/Resources/MenuBarIcon.png"
if [ -f "$MENU_ICON" ]; then
    cp "$MENU_ICON" "$RESOURCES/MenuBarIcon.png"
fi

# 资源文件（排除 README）
cd "$SPRITES_SRC"
for stateDir in */; do
    dirName="${stateDir%/}"
    [ "$dirName" = ".build" ] && continue
    mkdir -p "$RESOURCES/Sprites/$dirName"
    for png in "$dirName"/*.png; do
        [ -f "$png" ] && cp "$png" "$RESOURCES/Sprites/$png"
    done
done
cd "$PROJECT_DIR"

# ── 4. 复制 Info.plist ──────────────────────────────────────────
cp "$PROJECT_DIR/DesktopPetForMacApp/Info.plist" "$CONTENTS/Info.plist"

# ── 5. 拷贝到桌面 ───────────────────────────────────────────────
echo "📦 拷贝到桌面…"
cp -R "$APP_BUNDLE" "$DEST_APP"

# ── 6. 重新签名（修复 Gatekeeper 签名不匹配问题）─────────────────
echo "🔏 重新签名…"
codesign --force --deep --sign - "$DEST_APP"

# 清理来源标记（避免 quarantine 属性导致无法打开）
xattr -cr "$DEST_APP" 2>/dev/null || true

# ── 7. 清掉旧编译残留（可选） ───────────────────────────────────
# rm -rf "$APP_BUNDLE"

echo ""
echo "✅ 完成！请双击桌面「桌面小猫.app」启动"
echo "   路径: $DEST_APP"
echo ""
echo "⚠️  首次启动请到 系统设置 > 隐私与安全性 > 辅助功能 中放行"
