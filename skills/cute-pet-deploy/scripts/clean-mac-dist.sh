#!/usr/bin/env bash
# 清理 DesktopPetElectron/dist 里「旧的 mac 打包产物」，只删 mac 相关，
# 绝不动 Windows 的 .exe / win-* / latest.yml。
#
# 用法：
#   clean-mac-dist.sh --dry-run          # 只列出将要删除的东西，不实际删
#   clean-mac-dist.sh                     # 真正删除
#   DIST_DIR=/path/to/dist clean-mac-dist.sh --dry-run   # 覆盖 dist 路径
#
# 设计成幂等：没有旧产物时也不会报错。
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

# 从脚本自身位置推断仓库根 → Electron 工程的 dist（脚本在 skills/<skill>/scripts/ 下）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/DesktopPetElectron/dist}"

# 安全闸：目标目录必须真实存在，且末级就是 dist，避免误指向仓库根或用户传入的奇怪路径
if [[ ! -d "$DIST_DIR" ]]; then
  echo "错误：dist 目录不存在：$DIST_DIR" >&2
  echo "（可用 DIST_DIR=/绝对路径 覆盖）" >&2
  exit 1
fi
if [[ "$(basename "$DIST_DIR")" != "dist" ]]; then
  echo "错误：目标目录末级不是 dist，拒绝清理：$DIST_DIR" >&2
  exit 1
fi

echo "目标 dist：$DIST_DIR"
[[ $DRY_RUN -eq 1 ]] && echo "模式：--dry-run 预览，不实际删除" || echo "模式：将实际删除"
echo

removed=0

# 只匹配 mac 专属产物；Windows 的 .exe / latest.yml / win-* 不在这些模式内
#  - *.dmg / *.dmg.blockmap          mac 安装镜像（官网手动安装用）
#  - *-mac.zip / *.zip.blockmap      mac 自动更新包（electron-builder 命名为 <name>-<ver>-<arch>-mac.zip）
#  - latest-mac.yml                  mac 自动更新元数据
#  - mac / mac-arm64 / mac-universal 解包目录
while IFS= read -r -d '' item; do
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "将删除：${item#"$DIST_DIR"/}"
  else
    rm -rf "$item"
    echo "已删除：${item#"$DIST_DIR"/}"
  fi
  removed=$((removed + 1))
done < <(
  find "$DIST_DIR" -mindepth 1 -maxdepth 1 \
    \( -name '*.dmg' -o -name '*.dmg.blockmap' -o -name '*-mac.zip' -o -name '*.zip.blockmap' \
       -o -name 'latest-mac.yml' -o -name 'mac' -o -name 'mac-*' \) \
    -print0
)

echo
if [[ $removed -eq 0 ]]; then
  echo "没有发现旧的 mac 产物，dist 已干净。"
elif [[ $DRY_RUN -eq 1 ]]; then
  echo "预览命中 $removed 项。确认无误后去掉 --dry-run 实际删除。"
else
  echo "共清理 $removed 项 mac 旧产物。现在可以跑：npm run dist:mac"
fi
