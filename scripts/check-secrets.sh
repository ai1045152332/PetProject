#!/usr/bin/env bash
# 提交前密钥扫描：阻止密码/私钥被提交到仓库
set -uo pipefail

PATTERNS=(
  'PETSERVER_ADMIN_PASSWORD=[^<[:space:]]'
  'PETSERVER_ADMIN_TOKEN=[^<[:space:]]'
  'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
  'BEGIN PUBLIC KEY'
  'Xp123456'
  'arBrw6FjWtL6Dq2s'
)

# 排除扫描器自身（其中包含用于匹配的模式串）
DIFF=$(git diff --cached -U0 -- . ':(exclude)scripts/check-secrets.sh')

found=0
for pattern in "${PATTERNS[@]}"; do
  matches=$(printf '%s\n' "$DIFF" | grep -nE "^\+.*($pattern)" || true)
  if [ -n "$matches" ]; then
    echo "❌ 检测到疑似密钥/密码，已阻止提交："
    echo "$matches" | head -5
    echo "   如确属示例，请用占位符（如 <管理密码>）或改从 env 文件读取。"
    found=1
  fi
done

if [ "$found" -eq 1 ]; then
  echo ""
  echo "如需绕过（不推荐）：git commit --no-verify"
  exit 1
fi
exit 0
