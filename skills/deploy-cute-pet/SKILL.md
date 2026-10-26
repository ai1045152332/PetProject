---
name: deploy-cute-pet
description: 发布 cute pet（桌面宠物）App 到远程服务器：编译、Ed25519 签名、上传安装包并验证，让已安装客户端自动升级。也用于查询线上最新版本。当用户说「部署/发布/发版 app 到远程」「推送 app 更新」「上线新版本」时使用。
metadata:
  short-description: Deploy cute pet app releases to the remote server
---

# 部署 cute pet（App + PetServer）

两个独立的发布面：

- **App 发版**：编译 macOS App → Ed25519 签名 → 上传安装包 → 客户端自动升级
- **PetServer 部署**：交叉编译 Linux 二进制 → 上传 → 原子替换 → 重启 → 健康检查（失败自动回滚）

若一次改动同时涉及接口与客户端，**先部署服务端（保持向后兼容），再发 App**。

**服务端新接口刚上线时，不要立即发 App**：先用带新功能的 App 对线上服务端完成本地测试（接口连通、鉴权、生成链路等），测稳后再走 `deploy.sh` 发客户端。原因：App 一旦发布就无法撤回，已升级到该版本的用户会立刻命中未经线上验证的功能；而本地 `rebuild.sh` 随便折腾，不影响任何线上用户。

## 一键发布

本 skill 存放在仓库 `skills/deploy-cute-pet/`，并在 `~/.codex/skills/` 建了符号链接供 Codex 自动发现（新会话可直接触发）。脚本会从自身位置推断仓库根目录，两种调用方式等价：

```bash
./skills/deploy-cute-pet/scripts/deploy.sh --check                 # 仓库内调用
~/.codex/skills/deploy-cute-pet/scripts/deploy.sh --check          # 通过符号链接调用
~/.codex/skills/deploy-cute-pet/scripts/deploy.sh                  # 自动递增补丁版本并发布
~/.codex/skills/deploy-cute-pet/scripts/deploy.sh v1.0.016 "给用户看的更新说明"
COMMIT=1 ~/.codex/skills/deploy-cute-pet/scripts/deploy.sh ...     # 发布后顺带 git 提交并推送
```

脚本会：校验签名私钥与上传助手 → 解析/递增版本号（保持 `015 → 016` 的补零位宽）→ 调用 `DesktopPetForMacApp/release.sh`（产出 zip + dmg 两个包）→ 校验服务器 manifest 版本与本地 zip/dmg 的 sha256 一致 → 打印结果。

产物分工：**zip 给客户端自动更新**（`file`/`sha256`/`signature` 字段，换包靠 `ditto -x -k`），**dmg 给官网手动安装**（`dmgFile`/`dmgSHA256`/`dmgSignature` 字段，内带 `/Applications` 软链）。两者同源于同一次 `cute pet.app`。

仓库路径默认从脚本位置推断（`CUTE_PET_REPO` 覆盖），服务器默认 `http://101.96.248.75`（`CUTE_PET_SERVER` 覆盖）。

若仓库有未提交改动而用户还没决定是否发布，先问；发布说明必须是**用户能读懂的中文**（例：「修复了天气提醒时间看不清的问题」），技术细节留在 commit message。

## 部署服务端（PetServer）

```bash
./skills/deploy-cute-pet/scripts/deploy-server.sh --check     # 只检查 SSH/配置/连通性
./skills/deploy-cute-pet/scripts/deploy-server.sh            # 编译并部署（含验证）
```

脚本流程与安全边界：

1. `go vet` + `go test`（测试失败仅告警）
2. `GOOS=linux GOARCH=amd64` 交叉编译
3. **rsync 断点续传上传**（链路抖动可重试续传），最多 5 次
4. **校验远端 sha256 == 本地构建**；不一致则放弃，绝不替换线上文件
5. 备份当前二进制为 `petserver.bak` → 原子替换 → `systemctl restart`
6. 重启后**在服务器内 curl `/api/ping` 做健康检查**，不通过则自动回滚并重启旧版
7. 本地再从公网验证 `/api/ping`、`/api/devices`、`/api/app/latest`、`/api/weather`

远端布局与运维：

| 项 | 值 |
| --- | --- |
| 服务 | `systemctl {status,restart,logs} petserver`，监听 `:80` |
| 二进制 | `/opt/petserver/petserver`（备份 `.bak`） |
| 配置 | `/opt/petserver/petserver.env`（0600；后台密码、天气 Key） |
| 数据 | `/opt/petserver/data/`（会话/设备快照/激活码/心跳日志/私钥） |
| 日志 | `/var/log/petserver.log` |

注意：`PETSERVER_LISTEN_ADDR` 默认 `:8080`，公网部署在 env 里设为 `:80`。重启不会丢数据（会话与设备列表均持久化）。

## 关键约束（容易踩）

1. **版本号只能递增，同一版本号不要重复发布不同内容**。已升级到该版本的客户端不会再次下载，等于这批人永远收不到修复。
2. **发布后不要 `rebuild.sh` 本机 App**，除非用户明确要求本机立即升级 —— 本机保持在旧版本才有得测更新流程。
3. **新接口先发服务端、后发 App**：服务端部署对旧客户端无感（纯增量路由），可安全先行；App 侧必须等本地对线上环境测稳再发版（见上节）。
4. **签名私钥不可丢**：`~/.cute-pet-release/ed25519_private.pem`。丢失后无法再发布任何老客户端能接受的更新；泄露则可被伪造更新。
5. **客户端与服务端成对绑定**：App 内嵌发布验签公钥（`UpdateService.swift`）、载荷加密公钥（`PayloadCrypto.swift`）、后端地址（`ServerConfig.swift`）。换服务器或换密钥必须同时改这三处并重新发版。
6. **不要把密码/密钥写进仓库**：发布私钥与上传助手只存 `~/.cute-pet-release/`；服务器密码在其 `.exp` 脚本里，不入仓。
7. 上传卡住/缺少目录：`release.sh` 已处理 `mkdir -p /opt/petserver/dist`；若仍失败，检查 `~/.cute-pet-release/{scp_put,ssh_run}.exp` 可执行且密码与服务端一致。

## 客户端何时升级

启动 30 秒后、每 6 小时、或设置 → 通用设置 → 版本 →「检查更新」。静默检查发现新版本会弹窗，用户需两次确认（立即更新 → 立即重启）。

## 相关文件

| 用途 | 位置 |
| --- | --- |
| 发布脚本（版本号、打包、签名、上传） | `DesktopPetForMacApp/release.sh` |
| 打包脚本（`SKIP_DESKTOP_COPY=1` 发布模式） | `DesktopPetForMacApp/package.sh` |
| 版本号唯一来源 | `DesktopPetForMacApp/DesktopPetForMacApp/App/AppVersion.swift` |
| 客户端更新器 / 内置公钥 | `.../Services/UpdateService.swift` |
| 服务端下发接口 | `PetServer/internal/controller/release_controller.go` |
| 官网下载页（动态取 dmg 链接） | `PetServer/internal/web/site/index.html` |
| 服务端部署脚本 | `skills/deploy-cute-pet/scripts/deploy-server.sh` |
| 线上版本查询 | `curl http://101.96.248.75/api/app/latest` |

## 排障

| 现象 | 处理 |
| --- | --- |
| 提示版本号与服务器相同 | 递增版本号（脚本会给出建议值） |
| 客户端收不到更新 | 先 `curl /api/app/latest` 确认线上版本；客户端也可能尚未到检查时机（6h），让用户在设置里手动点「检查更新」 |
| 客户端「验签失败」 | 发布私钥与 App 内置公钥不匹配（换过密钥/在别的机器发布）—— 用同一私钥重发，或换公钥后重新打包发版 |
| 安装包 sha256 不一致 | 上传中断，重新执行发布脚本 |
| 服务端部署报「未确认远端启动结果」 | 替换/重启那条 SSH 连接中途断了。二进制已上传并校验过，单独重跑替换命令即可（脚本里那段 `cp …; mv …; systemctl restart …; if curl …; echo DEPLOYED; fi`），或再跑一次 `deploy-server.sh` |
| 服务端部署卡在「上传中断」 | 到服务器链路很差（`curl` 下 3MB 也超时）。脚本会拒绝替换线上文件；待网络恢复后重跑即可，或用 `CUTE_PET_SSH_HOST` 换出口 |
| 服务端部署后服务 SEGV/重启循环 | 通常是上传的二进制被截断。脚本的 sha 校验会拦住；若已发生：`mv petserver.bak petserver && systemctl restart petserver` |
| rsync 报 `--append` 相关错误 | 已改用 `--partial --inplace`（目的文件不存在时 `--append-verify` 会报错） |
| 服务器 404 `no release published` | `dist/latest.json` 不存在，先发布一次 |

## 注意区分：服务端部署是另一件事

本 skill 只管 **App 发版**。`PetServer` 的部署是：本地 `GOOS=linux GOARCH=amd64 go build` → 上传到 `/opt/petserver/petserver.new` → `mv` 覆盖 → `systemctl restart petserver`（服务监听 :80，配置在 `/opt/petserver/petserver.env`）。

## 深度参考

完整的更新机制、安全模型、密钥生成、更新弹窗文案规范、客户端升级时机、常见排障等细节见：

- [references/auto-update-and-release.md](references/auto-update-and-release.md) — 「自动更新与发布流程」全文（12 章节）
