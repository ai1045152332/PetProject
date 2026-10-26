#!/usr/bin/env bash
set -euo pipefail

# 发布脚本：改版本号 → 编译打包 → 生成 zip(自动更新) + dmg(官网下载) → sha256 → Ed25519 签名 → 上传服务器
# 用法: ./release.sh <版本号> [更新说明]
# 示例: ./release.sh v1.0.002 "修复热点新闻关闭按钮"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# packaging/ 在 App 工程根目录下；单独定义供 dmg 背景图与布局脚本使用
PROJECT_DIR="$SCRIPT_DIR"
APP_SRC="$SCRIPT_DIR/DesktopPetForMacApp"
VERSION="${1:-}"
NOTES="${2:-}"
KEY_DIR="$HOME/.cute-pet-release"
PRIVATE_KEY="$KEY_DIR/ed25519_private.pem"
SERVER="root@101.96.248.75"
DIST_LOCAL="$SCRIPT_DIR/dist"
APP_NAME="cute pet"

if [ -z "$VERSION" ]; then
    echo "用法: $0 <版本号> [更新说明]   例如: $0 v1.0.002 \"修复若干问题\""
    exit 1
fi
# 版本号守卫：只接受 vX.Y.Z / X.Y.Z（可带 -tag 后缀），防止把更新说明误当成版本号
if ! printf '%s' "$VERSION" | grep -Eq '^v?[0-9]+(\.[0-9]+)+(-[A-Za-z0-9]+)?$'; then
    echo "❌ 版本号格式不对：$VERSION"
    echo "   应为 v1.0.027 这种形式；更新说明请放在第二个参数"
    exit 1
fi
if [ ! -f "$PRIVATE_KEY" ]; then
    echo "❌ 未找到签名私钥: $PRIVATE_KEY"
    exit 1
fi

echo "━━━ 发布 $VERSION ━━━"

# ── 1. 写入版本号（唯一版本源：AppVersion.swift + Info.plist）──
echo "1/6 写入版本号…"
python3 - "$APP_SRC/App/AppVersion.swift" "$VERSION" <<'PY'
import re, sys
path, version = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r'static let current = "[^"]*"', f'static let current = "{version}"', s)
open(path, 'w').write(s)
PY
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP_SRC/Info.plist"

# ── 2. 编译 + 打包 ──
echo "2/6 编译打包…"
cd "$SCRIPT_DIR"
SKIP_DESKTOP_COPY=1 bash package.sh > /tmp/release_package.log 2>&1 || { tail -20 /tmp/release_package.log; exit 1; }

APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
[ -d "$APP_BUNDLE" ] || { echo "❌ 未找到打包产物 $APP_BUNDLE"; exit 1; }

# ── 3. 生成安装包（zip 给自动更新，dmg 给官网手动安装）──
echo "3/6 生成安装包…"
mkdir -p "$DIST_LOCAL"
ZIP_NAME="cute-pet-${VERSION}.zip"
ZIP="$DIST_LOCAL/$ZIP_NAME"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"

DMG_NAME="cute-pet-${VERSION}.dmg"
DMG="$DIST_LOCAL/$DMG_NAME"
DMG_RW="$DIST_LOCAL/.dmg-rw.dmg"
rm -f "$DMG" "$DMG_RW"
# dmg 内放 app + /Applications 软链，用户打开即可拖拽安装
STAGE="$DIST_LOCAL/.dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
# 标准安装窗口：背景图（箭头引导）+ 预先调好的 Finder 布局（.DS_Store 模板）
# 两者由 packaging/make_dmg_background.swift 与 packaging/dmg_window_layout.applescript 生成，缺失时退化为素窗口
DMG_BG_SRC="$PROJECT_DIR/packaging/dmg-background.png"
DMG_DSSTORE_SRC="$PROJECT_DIR/packaging/dmg.dsstore"
if [ -f "$DMG_BG_SRC" ] && [ -f "$DMG_DSSTORE_SRC" ]; then
    mkdir -p "$STAGE/.background"
    cp "$DMG_BG_SRC" "$STAGE/.background/dmg-background.png"
    cp "$DMG_DSSTORE_SRC" "$STAGE/.DS_Store"
    echo "   dmg 使用标准安装窗口（背景图 + 图标位置）"
else
    echo "   ⚠️  缺少 packaging/dmg-background.png 或 packaging/dmg.dsstore，dmg 退化为素窗口"
fi
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$DMG_RW"
# 实时应用一次 Finder 布局：背景图的 alias 绑定卷标识，直接复用旧 .DS_Store 会失效
LAYOUT_SCRIPT="$PROJECT_DIR/packaging/dmg_window_layout.applescript"
if [ -f "$LAYOUT_SCRIPT" ]; then
    hdiutil detach "/Volumes/$APP_NAME" >/dev/null 2>&1 || true
    if hdiutil attach "$DMG_RW" >/dev/null 2>&1; then
        sleep 1
        if osascript "$LAYOUT_SCRIPT" >/dev/null 2>&1; then
            echo "   dmg 安装窗口布局已应用（背景箭头 + 图标位置）"
        else
            echo "   ⚠️  布局脚本执行失败（终端未获控制 Finder 的权限），窗口退化为模板布局"
        fi
        sleep 1
        hdiutil detach "/Volumes/$APP_NAME" >/dev/null 2>&1 \
            || hdiutil detach "/Volumes/$APP_NAME" -force >/dev/null 2>&1 || true
    fi
fi
hdiutil convert "$DMG_RW" -quiet -format UDZO -o "$DMG"
rm -f "$DMG_RW"
rm -rf "$STAGE"
[ -f "$DMG" ] || { echo "❌ dmg 生成失败"; exit 1; }

# ── 4. 计算 sha256 并签名（zip / dmg 各一份）──
echo "4/6 计算摘要并签名…"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
SIZE=$(stat -f%z "$ZIP")
printf '%s' "$SHA" > /tmp/release_digest.txt
SIG=$(openssl pkeyutl -sign -rawin -inkey "$PRIVATE_KEY" -in /tmp/release_digest.txt | base64 | tr -d '\n')

DMG_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
DMG_SIZE=$(stat -f%z "$DMG")
printf '%s' "$DMG_SHA" > /tmp/release_digest_dmg.txt
DMG_SIG=$(openssl pkeyutl -sign -rawin -inkey "$PRIVATE_KEY" -in /tmp/release_digest_dmg.txt | base64 | tr -d '\n')

# ── 5. 生成 manifest ──
# file/sha256/signature/size 仍指向 zip：老客户端只认这几个字段，不能改语义
echo "5/6 生成 latest.json…"
python3 - "$DIST_LOCAL/latest.json" "$VERSION" "$ZIP_NAME" "$SHA" "$SIG" "$NOTES" "$SIZE" \
    "$DMG_NAME" "$DMG_SHA" "$DMG_SIG" "$DMG_SIZE" <<'PY'
import json, sys, datetime
(path, version, filename, sha, sig, notes, size,
 dmg_file, dmg_sha, dmg_sig, dmg_size) = sys.argv[1:12]
json.dump({
    "version": version,
    "file": filename,
    "sha256": sha,
    "signature": sig,
    "notes": notes,
    "publishedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "size": int(size),
    "minOS": "13.0",
    "dmgFile": dmg_file,
    "dmgSHA256": dmg_sha,
    "dmgSignature": dmg_sig,
    "dmgSize": int(dmg_size),
}, open(path, "w"), ensure_ascii=False, indent=2)
PY

# ── 6. 上传 ──
echo "6/6 上传到服务器…"
UPLOAD="$HOME/.cute-pet-release/scp_put.exp"
[ -x "$UPLOAD" ] || { echo "❌ 缺少上传助手脚本: $UPLOAD"; exit 1; }

# 确保服务器目录存在
"$HOME/.cute-pet-release/ssh_run.exp" "mkdir -p /opt/petserver/dist" > /dev/null 2>&1

"$UPLOAD" "$ZIP" "/opt/petserver/dist/$ZIP_NAME" > /dev/null 2>&1
"$UPLOAD" "$DMG" "/opt/petserver/dist/$DMG_NAME" > /dev/null 2>&1
"$UPLOAD" "$DIST_LOCAL/latest.json" "/opt/petserver/dist/latest.json" > /dev/null 2>&1

echo ""
echo "✅ 发布完成: $VERSION"
echo "   自动更新包(zip): $ZIP"
echo "   官网安装包(dmg): $DMG"
echo "   sha256: $SHA"
echo "   dmg sha256: $DMG_SHA"
echo "   服务器: http://101.96.248.75/api/app/latest"
