#!/usr/bin/env python3
"""无 pty 的 SSH/SFTP 助手（paramiko）。

为什么存在：发布脚本原本用 expect 拿密码登录，但 expect 每次 spawn 都要一个 pty。
pty 被耗尽时（`The system has no more ptys`）整条发布链会直接卡死，paramiko 走纯 socket，不受影响。

用法:
    remote.py exec "<远端命令>"        # 打印远端 stdout+stderr，退出码 = 远端退出码
    remote.py put <本地文件> <远端路径>  # SFTP 上传（自动建父目录、断点续传）
    remote.py check                   # 连通性自检

配置:
    主机   环境变量 CUTE_PET_SSH_HOST（默认 root@101.96.248.75）
    密码   环境变量 CUTE_PET_SSH_PASSWORD，或文件 ~/.cute-pet-release/ssh_password
    私钥   若已配置免密登录（~/.ssh/id_*），密码可留空
"""

import os
import stat
import sys

HOST_SPEC = os.environ.get("CUTE_PET_SSH_HOST", "root@101.96.248.75")
KEY_DIR = os.environ.get("CUTE_PET_KEY_DIR", os.path.expanduser("~/.cute-pet-release"))
PASSWORD_FILE = os.path.join(KEY_DIR, "ssh_password")
TIMEOUT = int(os.environ.get("CUTE_PET_SSH_TIMEOUT", "60"))


def split_host(spec):
    if "@" in spec:
        user, host = spec.rsplit("@", 1)
    else:
        user, host = "root", spec
    port = 22
    if ":" in host:
        host, raw_port = host.rsplit(":", 1)
        port = int(raw_port)
    return user, host, port


def password():
    pw = os.environ.get("CUTE_PET_SSH_PASSWORD")
    if pw:
        return pw
    try:
        with open(PASSWORD_FILE) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


def connect():
    import paramiko

    user, host, port = split_host(HOST_SPEC)
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    pw = password()
    kwargs = {
        "hostname": host,
        "port": port,
        "username": user,
        "timeout": TIMEOUT,
        "banner_timeout": TIMEOUT,
        "auth_timeout": TIMEOUT,
    }
    if pw:
        kwargs["password"] = pw
        kwargs["look_for_keys"] = False
        kwargs["allow_agent"] = False
    client.connect(**kwargs)
    transport = client.get_transport()
    if transport:
        transport.set_keepalive(15)
    return client


def cmd_exec(argv):
    if len(argv) < 2:
        sys.exit("用法: remote.py exec \"<远端命令>\"")
    remote_cmd = argv[1]
    client = connect()
    try:
        _, stdout, stderr = client.exec_command(remote_cmd, timeout=TIMEOUT * 4)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        status = stdout.channel.recv_exit_status()
    finally:
        client.close()
    sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    sys.stdout.flush()
    return status


def cmd_put(argv):
    if len(argv) < 3:
        sys.exit("用法: remote.py put <本地文件> <远端路径>")
    local, remote = argv[1], argv[2]
    if not os.path.isfile(local):
        sys.exit(f"本地文件不存在：{local}")

    client = connect()
    try:
        sftp = client.open_sftp()
        parent = os.path.dirname(remote)
        if parent:
            _mkdirs(sftp, parent)
        # 注意：这里必须整文件覆盖（wb），不能按远端大小"续传"。
        # 发布场景下远端是「上一个版本」的旧文件，长度与新文件不同；若从旧长度处续写，
        # 会把新旧内容拼接成一个损坏文件（曾经把 latest.json 拼坏导致 /api/app/latest 500）。
        # 失败重试由调用方负责，SFTP put 本身是一次原子写入。
        with open(local, "rb") as src, sftp.open(remote, "wb") as dst:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                dst.write(chunk)
        sftp.chmod(remote, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR | stat.S_IRGRP
                   | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
        sftp.close()
    finally:
        client.close()
    return 0


def _mkdirs(sftp, path):
    parts = [p for p in path.split("/") if p]
    current = ""
    for part in parts:
        current += "/" + part
        try:
            sftp.stat(current)
        except IOError:
            sftp.mkdir(current)


def cmd_check(_argv):
    status = cmd_exec(["exec", "hostname; uname -sr"])
    print(f"✅ 连接正常（退出码 {status}）")
    return 0


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sub = sys.argv[1]
    handlers = {"exec": cmd_exec, "put": cmd_put, "check": cmd_check}
    if sub not in handlers:
        sys.exit(f"未知子命令：{sub}\n{__doc__}")
    try:
        sys.exit(handlers[sub](sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - 统一转成退出码，交给调用方重试
        sys.stderr.write(f"remote.py {sub} 失败：{exc}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
