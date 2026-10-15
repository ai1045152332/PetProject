#!/usr/bin/env bash
set -euo pipefail

# 发布脚本：改版本号 → 编译打包 → 压缩 → sha256 → Ed25519 签名 → 上传服务器
# 用法: ./release.sh <版本号> [更新说明]
# 示例: ./release.sh v1.0.002 "修复热点新闻关闭按钮"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# ── 3. 压缩安装包 ──
echo "3/6 生成安装包…"
mkdir -p "$DIST_LOCAL"
ZIP_NAME="cute-pet-${VERSION}.zip"
ZIP="$DIST_LOCAL/$ZIP_NAME"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"

# ── 4. 计算 sha256 并签名 ──
echo "4/6 计算摘要并签名…"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
SIZE=$(stat -f%z "$ZIP")
printf '%s' "$SHA" > /tmp/release_digest.txt
SIG=$(openssl pkeyutl -sign -rawin -inkey "$PRIVATE_KEY" -in /tmp/release_digest.txt | base64 | tr -d '\n')

# ── 5. 生成 manifest ──
echo "5/6 生成 latest.json…"
python3 - "$DIST_LOCAL/latest.json" "$VERSION" "$ZIP_NAME" "$SHA" "$SIG" "$NOTES" "$SIZE" <<'PY'
import json, sys, datetime
path, version, filename, sha, sig, notes, size = sys.argv[1:8]
json.dump({
    "version": version,
    "file": filename,
    "sha256": sha,
    "signature": sig,
    "notes": notes,
    "publishedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "size": int(size),
    "minOS": "13.0",
}, open(path, "w"), ensure_ascii=False, indent=2)
PY

# ── 6. 上传 ──
echo "6/6 上传到服务器…"
UPLOAD="$HOME/.cute-pet-release/scp_put.exp"
[ -x "$UPLOAD" ] || { echo "❌ 缺少上传助手脚本: $UPLOAD"; exit 1; }

# 确保服务器目录存在
"$HOME/.cute-pet-release/ssh_run.exp" "mkdir -p /opt/petserver/dist" > /dev/null 2>&1

"$UPLOAD" "$ZIP" "/opt/petserver/dist/$ZIP_NAME" > /dev/null 2>&1
"$UPLOAD" "$DIST_LOCAL/latest.json" "/opt/petserver/dist/latest.json" > /dev/null 2>&1

echo ""
echo "✅ 发布完成: $VERSION"
echo "   安装包: $ZIP"
echo "   sha256: $SHA"
echo "   服务器: http://101.96.248.75/api/app/latest"
