#!/usr/bin/env bash
set -euo pipefail

# DesktopCat 打包脚本
# 产出 DesktopCat.app 到桌面

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DesktopCat"
DESKTOP="$HOME/Desktop"

# ── 1. Release 编译 ──────────────────────────────────────────────
echo "🔨 编译 Release 二进制…"
swift build -c release

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
SPRITES_SRC="$PROJECT_DIR/DesktopCat/Resources/Sprites"

mkdir -p "$MACOS" "$RESOURCES/Sprites"

# 可执行文件
cp "$BUILD_BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# 应用图标（.icns 格式）
ICON_SRC="$PROJECT_DIR/DesktopCat/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$RESOURCES/AppIcon.icns"
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

# ── 4. 生成 Info.plist ──────────────────────────────────────────
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DesktopCat</string>
    <key>CFBundleDisplayName</key>
    <string>桌面小猫</string>
    <key>CFBundleIdentifier</key>
    <string>com.desktopcat.app</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleExecutable</key>
    <string>DesktopCat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSAppNapIsDisabled</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>DesktopCat 需要辅助功能权限来监听鼠标位置，实现看向鼠标效果。</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSBackgroundOnly</key>
    <false/>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
</dict>
</plist>
PLIST

# ── 5. 拷贝到桌面 ───────────────────────────────────────────────
echo "📦 拷贝到桌面…"
cp -R "$APP_BUNDLE" "$DEST_APP"

# ── 6. 清掉旧编译残留（可选） ───────────────────────────────────
# rm -rf "$APP_BUNDLE"

echo ""
echo "✅ 完成！请双击桌面「桌面小猫.app」启动"
echo "   路径: $DEST_APP"
echo ""
echo "⚠️  首次启动请到 系统设置 > 隐私与安全性 > 辅助功能 中放行"
