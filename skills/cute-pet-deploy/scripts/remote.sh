#!/usr/bin/env bash
# 远端执行/上传的统一封装（source 使用，不要直接执行）。
#
# 后端自动选择：
#   CUTE_PET_REMOTE_BACKEND=auto（默认）  expect 助手可用就用它；pty 耗尽则自动切 paramiko
#   CUTE_PET_REMOTE_BACKEND=paramiko    强制无 pty（paramiko，纯 socket）
#   CUTE_PET_REMOTE_BACKEND=expect      强制 expect（需要 pty）
#
# 提供：
#   remote_exec "<远端命令>"     # 打印远端 stdout（expect 后端仍保留原 SSH_OUT_FILE 语义给调用方读）
#   remote_put <本地文件> <远端路径>  # 上传（expect=rsync，paramiko=SFTP 断点续传）
#   remote_backend               # 打印当前后端，便于排障
#
# 依赖：paramiko 装在 CUTE_PET_PARAMIKO_LIBS（默认 ~/.catpaw/pylibs），缺失时给出安装命令。

CUTE_PET_REMOTE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_DIR="${CUTE_PET_KEY_DIR:-$HOME/.cute-pet-release}"
EXPECT_SSH="$KEY_DIR/ssh_run.exp"
EXPECT_PUT="$KEY_DIR/rsync_put.exp"
PARAMIKO_LIBS="${CUTE_PET_PARAMIKO_LIBS:-$HOME/.catpaw/pylibs}"
_CUTE_PET_BACKEND=""

remote_backend() {
  [ -n "$_CUTE_PET_BACKEND" ] && { printf '%s\n' "$_CUTE_PET_BACKEND"; return 0; }
  case "${CUTE_PET_REMOTE_BACKEND:-auto}" in
    paramiko) _CUTE_PET_BACKEND=paramiko ;;
    expect)   _CUTE_PET_BACKEND=expect ;;
    *)
      if [ -x "$EXPECT_SSH" ] && expect -c 'spawn true; expect eof' >/dev/null 2>&1; then
        _CUTE_PET_BACKEND=expect
      else
        _CUTE_PET_BACKEND=paramiko
      fi
      ;;
  esac
  printf '%s\n' "$_CUTE_PET_BACKEND"
}

_remote_py() {
  local py_bin
  py_bin=$(command -v python3) || { echo "未找到 python3" >&2; return 127; }
  if [ ! -d "$PARAMIKO_LIBS" ]; then
    echo "缺少 paramiko：python3 -m pip install --target $PARAMIKO_LIBS paramiko" >&2
    return 127
  fi
  PYTHONPATH="$PARAMIKO_LIBS" "$py_bin" "$CUTE_PET_REMOTE_LIB_DIR/lib/remote.py" "$@"
}

remote_exec() {
  [ $# -ge 1 ] || { echo "remote_exec <cmd>" >&2; return 2; }
  case "$(remote_backend)" in
    expect)
      local out
      out=$(mktemp -t cute_pet_remote_XXXXXX)
      SSH_OUT_FILE="$out" "$EXPECT_SSH" "$1" >/dev/null 2>&1 || true
      cat "$out"
      rm -f "$out"
      ;;
    paramiko)
      _remote_py exec "$1"
      ;;
  esac
}

remote_put() {
  [ $# -eq 2 ] || { echo "remote_put <local> <remote>" >&2; return 2; }
  local backend; backend=$(remote_backend)
  if [ "$backend" = "expect" ] && [ -x "$EXPECT_PUT" ]; then
    if "$EXPECT_PUT" "$1" "$2" >/dev/null 2>&1; then
      return 0
    fi
  fi
  _remote_py put "$1" "$2"
}
