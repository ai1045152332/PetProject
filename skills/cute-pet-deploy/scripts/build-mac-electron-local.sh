#!/usr/bin/env bash
set -euo pipefail

# 本地打 Electron macOS 包（不上传、不签名、不发远程）
#
# 用途：在本机产出可双击安装的 .dmg + 自动更新用的 zip，验证窗口/托盘/设置面板在打包后是否正常。
# 只影响本机 dist/；要给 mac 用户升级走 deploy.sh（那是 Swift 原生版），Electron mac 通道目前只发 Windows。
#
# 用法:
#   build-mac-electron-local.sh                 # 清旧 mac 产物 → 按 package.json 版本**同时打 arm64 + x64**
#   build-mac-electron-local.sh --arch arm64    # 只打 Apple Silicon
#   build-mac-electron-local.sh --arch x64      # 只打 Intel
#   build-mac-electron-local.sh --arch universal # universal 单包（给 Swift 老用户迁移用，体积翻倍）
#   build-mac-electron-local.sh --version 1.1.001  # 先把 package.json 版本改成 1.1.001 再打包
#   build-mac-electron-local.sh --no-clean      # 保留旧产物（不推荐，容易拿错包）
#   build-mac-electron-local.sh --dry-run       # 只预览将清理什么、将打哪个版本，不打包
#   build-mac-electron-local.sh --open          # 打完后自动打开 dmg 挂载窗口
#
# 产物：DesktopPetElectron/dist/DesktopPet-<版本>-arm64.dmg / -x64.dmg
#       DesktopPetElectron/dist/DesktopPet-<版本>-<arch>-mac.zip（自动更新包，本地验证用不到）
# 两个架构分别出包（不是 universal 单包）：官网按访客 CPU 分流，客户端按 process.arch 取对应文件。

SCRIPT_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_REAL")
REPO="${CUTE_PET_REPO:-$(cd "$SCRIPTS_DIR/../../.." && pwd)}"
ELECTRON_DIR="$REPO/DesktopPetElectron"
DIST_DIR="$ELECTRON_DIR/dist"

DO_CLEAN=1
DRY_RUN=0
DO_OPEN=0
NEW_VERSION=""
TARGET_ARCH="both"   # both / arm64 / x64
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) shift; TARGET_ARCH="${1:-both}" ;;
    --no-clean) DO_CLEAN=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --open) DO_OPEN=1 ;;
    --version) shift; NEW_VERSION="${1:-}" ;;
    -h|--help) sed -n '3,19p' "$0"; exit 0 ;;
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
    fail "版本号格式不对：$NEW_VERSION（例：0.0.5，本机验证包可用 0.0.5-test）"
  fi
fi

CUR_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ELECTRON_DIR/package.json")
TARGET_VERSION="${NEW_VERSION:-$CUR_VERSION}"
ARCH=$(uname -m)
case "$ARCH" in
  arm64) ARCH_LABEL="arm64" ;;
  x86_64) ARCH_LABEL="x64" ;;
  *) ARCH_LABEL="$ARCH" ;;
esac
case "$TARGET_ARCH" in
  both|arm64|x64|universal) ;;
  *) fail "未知架构：$TARGET_ARCH（可选 both / arm64 / x64 / universal）" ;;
esac
say "Electron 工程     : $ELECTRON_DIR"
say "当前 package 版本 : $CUR_VERSION"
say "本次打包版本      : $TARGET_VERSION（架构：$TARGET_ARCH；本机 $ARCH_LABEL）"

if [ "$DRY_RUN" = "1" ]; then
  say ""
  say "将清理的 mac 旧产物（预览）："
  bash "$SCRIPTS_DIR/clean-mac-dist.sh" --dry-run | sed 's/^/  /'
  say ""
  say "✅ --dry-run 结束：未改版本号、未打包"
  exit 0
fi

# 1. 清旧 mac 产物（保留 Windows 的 exe/latest.yml）
if [ "$DO_CLEAN" = "1" ]; then
  say ""
  say "清理旧 mac 产物…"
  bash "$SCRIPTS_DIR/clean-mac-dist.sh" >/dev/null
  say "   已清理（只删 *.dmg / *-mac.zip / latest-mac.yml / mac-*，Windows 产物保留）"
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

# 3. 打包（本机无开发者证书：跳过签名，产物 ad-hoc 签名）
#
# ⚠️ 已知坑：packaging/icon.icns 是指向 SharedAssets/ 的软链，而 electron-builder 给 dmg 卷写
# .VolumeIcon.icns 时不跟随软链，会在 xattr.Set 阶段报
#   "xattr.Set /Volumes/…/.VolumeIcon.icns com.apple.FinderInfo: no such file or directory"
# 所以这里把图标物化成真实文件，用 -c.dmg.icon 传进去（不动仓库里的软链布局）。
say ""
say "调用 electron-builder 打包 macOS…"
cd "$ELECTRON_DIR"
LOG=/tmp/build_mac_electron_local.log
ICON_TMP_DIR=$(mktemp -d)
ICON_REAL="$ICON_TMP_DIR/icon.icns"
if [ -f "$ELECTRON_DIR/packaging/icon.icns" ]; then
  cp -L "$ELECTRON_DIR/packaging/icon.icns" "$ICON_REAL"
  say "   dmg 卷图标：物化软链 → $ICON_REAL"
fi
BUILD_ARGS=()
case "$TARGET_ARCH" in
  both) BUILD_ARGS=(--x64 --arm64) ;;
  arm64) BUILD_ARGS=(--arm64) ;;
  x64) BUILD_ARGS=(--x64) ;;
  universal) BUILD_ARGS=(--universal) ;;
esac
CSC_IDENTITY_AUTO_DISCOVERY=false npm run dist:mac -- -c.dmg.icon="$ICON_REAL" "${BUILD_ARGS[@]}" > "$LOG" 2>&1 \
  || { rm -rf "$ICON_TMP_DIR"; tail -30 "$LOG"; fail "打包失败（日志 $LOG）"; }
rm -rf "$ICON_TMP_DIR"
say "   打包完成（日志 $LOG）"

# 3.5 统一产物名：electron-builder 会把 1.1.001 规范化成 1.1.1，x64 的 dmg 还不带架构后缀。
# 这里按「架构」重命名成 DesktopPet-<原样版本>-<arch>.dmg / -<arch>-mac.zip，后续发布脚本只认这套名字。
python3 - "$DIST_DIR" "$TARGET_VERSION" <<'PY'
import os, sys
dist, ver = sys.argv[1], sys.argv[2]
for name in sorted(os.listdir(dist)):
    # productName 可能叫 "cute pet" / "DesktopPet"，统一按后缀识别，不依赖前缀
    if name.endswith('.dmg'):
        suffix = '.dmg'
    elif name.endswith('-mac.zip'):
        suffix = '-mac.zip'
    else:
        continue
    if name.startswith('DesktopPet-') and name == f'DesktopPet-{ver}-arm64{suffix}':
        continue
    if '-universal' in name:
        arch = 'universal'
    elif '-arm64' in name:
        arch = 'arm64'
    elif '-x64' in name:
        arch = 'x64'
    else:
        arch = 'x64'          # 单/双架构时 x64 的 dmg 默认不带 arch 后缀
    target = f'DesktopPet-{ver}-{arch}{suffix}'
    if name != target:
        os.replace(os.path.join(dist, name), os.path.join(dist, target))
        print(f'   renamed: {name} -> {target}')
PY

# 4. 汇总产物
say ""
say "产物清单："
find "$DIST_DIR" -maxdepth 1 \( -name "*.dmg" -o -name "*-mac.zip" \) -print0 | while IFS= read -r -d '' f; do
  size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
  mb=$(python3 -c "import sys; print(f'{int(sys.argv[1])/1024/1024:.1f}')" "$size")
  case "$(basename "$f")" in
    *.dmg) kind="安装镜像（拖进「应用程序」）" ;;
    *) kind="自动更新包（本地验证用不到）" ;;
  esac
  say "  • $(basename "$f")  ${mb} MB  — $kind"
done

say ""
say "✅ 本地 macOS 包已就绪（未签名、未上传、未发远程）"
say "   首次打开：右键 App →「打开」，或 xattr -dr com.apple.quarantine /Applications/DesktopPet.app"
say "   产品线区别：mac 原生 Swift 版发版走 deploy.sh；本包属于 Electron 线，仅本机验证"

if [ "$DO_OPEN" = "1" ]; then
  DMG=$(find "$DIST_DIR" -maxdepth 1 -name "*.dmg" | head -1)
  [ -n "$DMG" ] && open "$DMG"
fi
