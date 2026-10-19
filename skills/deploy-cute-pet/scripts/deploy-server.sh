#!/usr/bin/env bash
set -euo pipefail

# 部署 PetServer 到远程服务器（编译 → 上传 → 原子替换 → 重启 → 验证，失败自动回滚）
# 用法:
#   deploy-server.sh            # 编译并部署
#   deploy-server.sh --check    # 只检查环境/连通性，不部署

SCRIPT_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")
REPO_DEFAULT=$(cd "$(dirname "$SCRIPT_REAL")/../../.." && pwd)
REPO="${CUTE_PET_REPO:-$REPO_DEFAULT}"
SERVER_DIR="$REPO/PetServer"
KEY_DIR="${CUTE_PET_KEY_DIR:-$HOME/.cute-pet-release}"
SERVER_HOST="${CUTE_PET_SSH_HOST:-root@101.96.248.75}"
SERVER_HTTP="${CUTE_PET_SERVER:-http://101.96.248.75}"
SSH="$KEY_DIR/ssh_run.exp"
SCP="$KEY_DIR/scp_put.exp"
RSYNC="$KEY_DIR/rsync_put.exp"

MODE="deploy"
if [ "${1:-}" = "--check" ]; then MODE="check"; fi

say() { printf '%s\n' "$*"; }
fail() { say "❌ $*"; exit 1; }

# ── 1. 环境检查 ──────────────────────────────────────────────
[ -d "$SERVER_DIR" ] || fail "未找到服务端目录：$SERVER_DIR"
[ -x "$SSH" ] && [ -x "$RSYNC" ] || fail "缺少上传助手：$KEY_DIR/{rsync_put,ssh_run}.exp"

say "检查 SSH 连通性…"
SSH_TMP="/tmp/cute_pet_deploy_check.log"
SSH_OUT_FILE="$SSH_TMP" "$SSH" "systemctl is-active petserver; if test -f /opt/petserver/petserver.env; then echo ENV_YES; else echo ENV_NO; fi" >/dev/null 2>&1
RAW=$(tr -d '\r' < "$SSH_TMP" 2>/dev/null || true)

grep -qx 'active' <<< "$RAW" || grep -q '^active$' <<< "$RAW" || fail "SSH 连接失败或无响应（检查 $SSH 与服务器密码/网络）"

STATE=unknown
if printf '%s\n' "$RAW" | grep -qx 'active'; then STATE=active; fi
ENVOK=unknown
if printf '%s\n' "$RAW" | grep -qx 'ENV_YES'; then ENVOK=yes; fi

say "远端服务状态：${STATE}；配置文件：${ENVOK}"
[ "$STATE" = "active" ] || say "⚠️ 远端服务当前不是 active（部署后会重启）"
[ "$ENVOK" = "yes" ] || fail "远端缺少 /opt/petserver/petserver.env（后台密码/天气 Key 等配置在其中，请先创建）"

curl -sf --max-time 8 "$SERVER_HTTP/api/ping" >/dev/null || say "⚠️ 公网 /api/ping 不通（可能安全组/端口问题，部署后仍会验证）"

if [ "$MODE" = "check" ]; then
  say "✅ 环境检查通过（未部署）"
  exit 0
fi

# ── 2. 编译 ──────────────────────────────────────────────────
cd "$SERVER_DIR"
say ""
say "静态检查与测试…"
go vet ./... || fail "go vet 未通过"
go test ./... >/dev/null 2>&1 || say "⚠️ go test 有失败（继续部署，请留意）"

say "编译 linux/amd64…"
GOOS=linux GOARCH=amd64 go build -o /tmp/petserver-deploy ./cmd/server || fail "编译失败"
LOCAL_SHA=$(shasum -a 256 /tmp/petserver-deploy | awk '{print $1}')
say "构建产物 sha256: ${LOCAL_SHA:0:16}…"

# ── 3. 上传 + 原子替换（保留备份，失败回滚）──────────────────
say ""
say "上传并重启服务…"
UPLOAD_OK=0
for attempt in 1 2 3 4 5; do
  if "$RSYNC" /tmp/petserver-deploy /opt/petserver/petserver.new >/dev/null 2>&1; then
    SSH_OUT_FILE=/tmp/cute_pet_sha.log "$SSH" "sha256sum /opt/petserver/petserver.new" >/dev/null 2>&1
    REMOTE_SHA=$(tr -d '\r' < /tmp/cute_pet_sha.log 2>/dev/null | awk '{print $1}' | grep -E '^[0-9a-f]{64}$' | head -1)
    if [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
      UPLOAD_OK=1
      say "  上传校验通过（第 ${attempt} 次尝试）"
      break
    fi
    say "  ⚠️ 第 ${attempt} 次上传校验不一致（远端 ${REMOTE_SHA:0:12}…），重试…"
  else
    say "  ⚠️ 第 ${attempt} 次上传中断（可续传），重试…"
  fi
  sleep 2
done
[ "$UPLOAD_OK" = "1" ] || fail "上传校验失败；未改动线上服务（请检查网络后重试）"

# 注意：expect 下 "&& if" 组合会挂起，统一用分号分隔；输出走文件读取
SSH_OUT_FILE="/tmp/cute_pet_deploy_restart.log" "$SSH" "cp -f /opt/petserver/petserver /opt/petserver/petserver.bak; mv /opt/petserver/petserver.new /opt/petserver/petserver; chmod +x /opt/petserver/petserver; systemctl restart petserver; sleep 4; if curl -sf -m 5 http://127.0.0.1/api/ping >/dev/null; then echo DEPLOYED; else echo ROLLBACK; mv -f /opt/petserver/petserver.bak /opt/petserver/petserver; systemctl restart petserver; fi" >/dev/null 2>&1
REMOTE_OUT=$(tr -d '\r' < /tmp/cute_pet_deploy_restart.log 2>/dev/null || true)

if printf '%s' "$REMOTE_OUT" | grep -q ROLLBACK; then
  fail "新版本健康检查失败，已自动回滚到上一版本（检查 systemctl status petserver）"
fi
printf '%s' "$REMOTE_OUT" | grep -q DEPLOYED || fail "未确认远端启动结果，请手动检查服务状态"

if ! curl -sf --max-time 10 "$SERVER_HTTP/api/ping" >/dev/null; then
  fail "部署后 /api/ping 不可用（服务已回滚或网络异常）"
fi

# ── 4. 部署后验证 ────────────────────────────────────────────
say ""
say "部署后接口验证…"
curl -sf --max-time 10 "$SERVER_HTTP/api/devices" >/dev/null || fail "/api/devices 不可用"
curl -sf --max-time 10 "$SERVER_HTTP/api/app/latest" >/dev/null \
  && say "  ✅ /api/app/latest 正常" || say "  ⚠️ /api/app/latest 异常（可能尚未发布过版本）"

WEATHER_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "$SERVER_HTTP/api/weather?lat=39.9042&lon=116.4074&city=Beijing&deviceId=deploy-check")
if [ "$WEATHER_CODE" = "200" ]; then
  say "  ✅ /api/weather 正常"
elif [ "$WEATHER_CODE" = "503" ]; then
  say "  ⚠️ /api/weather 未配置 PETSERVER_QWEATHER_KEY"
elif [ "$WEATHER_CODE" = "429" ]; then
  say "  ⚠️ /api/weather 触发限流（部署检查占用了一次额度）"
else
  say "  ⚠️ /api/weather 返回 $WEATHER_CODE"
fi

say ""
say "🎉 PetServer 部署完成"
say "   备份：/opt/petserver/petserver.bak（回滚：mv 覆盖后 systemctl restart petserver）"
say "   日志：ssh $SERVER_HOST 'tail -f /var/log/petserver.log'"
