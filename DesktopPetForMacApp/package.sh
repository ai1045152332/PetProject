#!/usr/bin/env bash
set -euo pipefail

# DesktopPetForMacApp 打包脚本
# 产出 cute pet.app 到桌面

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_NAME="DesktopPetForMacApp"   # 编译产物/可执行文件名（保持不变，避免影响 CFBundleExecutable）
APP_NAME="cute pet"               # 固定产物名（不使用宠物名称，避免中文文件名转义问题）
DESKTOP="$HOME/Desktop"

# ── 1. Release 编译 ──────────────────────────────────────────────
echo "🔨 编译 Release 二进制…"
swift build -c release --disable-sandbox

BUILD_BIN="$PROJECT_DIR/.build/release/$SRC_NAME"

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

# 可执行文件（保持 SRC_NAME，与 Info.plist CFBundleExecutable 一致）
cp "$BUILD_BIN" "$MACOS/$SRC_NAME"
chmod +x "$MACOS/$SRC_NAME"

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

# 词库 JSON 文件（WordBank）
WORD_BANK_SRC="$PROJECT_DIR/DesktopPetForMacApp/Resources/WordBank"
if [ -d "$WORD_BANK_SRC" ]; then
    echo "📚 复制词库文件..."
    mkdir -p "$RESOURCES/WordBank"
    cp "$WORD_BANK_SRC"/*.json "$RESOURCES/WordBank/"
fi

# 刷题题库（ProblemBank：LeetCode 热题 100）
PROBLEM_BANK_SRC="$PROJECT_DIR/DesktopPetForMacApp/Resources/ProblemBank"
if [ -d "$PROBLEM_BANK_SRC" ]; then
    echo "🧩 复制题库文件..."
    mkdir -p "$RESOURCES/ProblemBank"
    cp "$PROBLEM_BANK_SRC"/*.json "$RESOURCES/ProblemBank/"
fi

# ── 4. 复制并更新 Info.plist ───────────────────────────────────
cp "$PROJECT_DIR/DesktopPetForMacApp/Info.plist" "$CONTENTS/Info.plist"
# 应用显示名改为产物名（CFBundleName 与 CFBundleDisplayName）
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$CONTENTS/Info.plist"

# ── 5. 签名 ─────────────────────────────────────────────────────
echo "🔏 重新签名…"
codesign --force --deep --sign - "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# 发布场景（SKIP_DESKTOP_COPY=1）只产出工程内 .app，不动桌面那份
if [ "${SKIP_DESKTOP_COPY:-0}" = "1" ]; then
    echo "⏭️  跳过桌面拷贝（发布模式）"
    echo ""
    echo "✅ 打包完成（仅工程内）：$APP_BUNDLE"
    exit 0
fi

# ── 6. 拷贝到桌面 ───────────────────────────────────────────────
echo "📦 拷贝到桌面…"
cp -R "$APP_BUNDLE" "$DEST_APP"
codesign --force --deep --sign - "$DEST_APP"
xattr -cr "$DEST_APP" 2>/dev/null || true

# ── 7. 清掉旧编译残留（可选） ───────────────────────────────────
# rm -rf "$APP_BUNDLE"

echo ""
echo "✅ 完成！请双击桌面「$APP_NAME.app」启动"
echo "   路径: $DEST_APP"
echo ""
echo "⚠️  首次启动请到 系统设置 > 隐私与安全性 > 辅助功能 中放行"
