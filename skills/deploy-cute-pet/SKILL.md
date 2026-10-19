---
name: deploy-cute-pet
description: 发布 cute pet（桌面宠物）App 到远程服务器：编译、Ed25519 签名、上传安装包并验证，让已安装客户端自动升级。也用于查询线上最新版本。当用户说「部署/发布/发版 app 到远程」「推送 app 更新」「上线新版本」时使用。
metadata:
  short-description: Deploy cute pet app releases to the remote server
---

# 部署 cute pet App 到远程

产物是 macOS App（`cute pet.app` 的 zip），由客户端自动更新机制拉取。发布 = 编译打包 → Ed25519 签名 → 上传 `101.96.248.75:/opt/petserver/dist/` → 更新 `latest.json`。

## 一键发布

本 skill 存放在仓库 `skills/deploy-cute-pet/`，并在 `~/.codex/skills/` 建了符号链接供 Codex 自动发现（新会话可直接触发）。脚本会从自身位置推断仓库根目录，两种调用方式等价：

```bash
./skills/deploy-cute-pet/scripts/deploy.sh --check                 # 仓库内调用
~/.codex/skills/deploy-cute-pet/scripts/deploy.sh --check          # 通过符号链接调用
~/.codex/skills/deploy-cute-pet/scripts/deploy.sh                  # 自动递增补丁版本并发布
~/.codex/skills/deploy-cute-pet/scripts/deploy.sh v1.0.016 "给用户看的更新说明"
COMMIT=1 ~/.codex/skills/deploy-cute-pet/scripts/deploy.sh ...     # 发布后顺带 git 提交并推送
```

脚本会：校验签名私钥与上传助手 → 解析/递增版本号（保持 `015 → 016` 的补零位宽）→ 调用 `DesktopPetForMacApp/release.sh` → 校验服务器 manifest 版本与本地包 sha256 一致 → 打印结果。

仓库路径默认从脚本位置推断（`CUTE_PET_REPO` 覆盖），服务器默认 `http://101.96.248.75`（`CUTE_PET_SERVER` 覆盖）。

若仓库有未提交改动而用户还没决定是否发布，先问；发布说明必须是**用户能读懂的中文**（例：「修复了天气提醒时间看不清的问题」），技术细节留在 commit message。

## 关键约束（容易踩）

1. **版本号只能递增，同一版本号不要重复发布不同内容**。已升级到该版本的客户端不会再次下载，等于这批人永远收不到修复。
2. **发布后不要 `rebuild.sh` 本机 App**，除非用户明确要求本机立即升级 —— 本机保持在旧版本才有得测更新流程。
3. **签名私钥不可丢**：`~/.cute-pet-release/ed25519_private.pem`。丢失后无法再发布任何老客户端能接受的更新；泄露则可被伪造更新。
4. **客户端与服务端成对绑定**：App 内嵌发布验签公钥（`UpdateService.swift`）、载荷加密公钥（`PayloadCrypto.swift`）、后端地址（`ServerConfig.swift`）。换服务器或换密钥必须同时改这三处并重新发版。
5. **不要把密码/密钥写进仓库**：`scripts/check-secrets.sh` 的 pre-commit 钩子会拦截；发布私钥与上传助手只存 `~/.cute-pet-release/`。服务器密码在其 `.exp` 脚本里。
6. 上传卡住/缺少目录：`release.sh` 已处理 `mkdir -p /opt/petserver/dist`；若仍失败，检查 `~/.cute-pet-release/{scp_put,ssh_run}.exp` 可执行且密码与服务端一致。

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
| 线上版本查询 | `curl http://101.96.248.75/api/app/latest` |

## 排障

| 现象 | 处理 |
| --- | --- |
| 提示版本号与服务器相同 | 递增版本号（脚本会给出建议值） |
| 客户端收不到更新 | 先 `curl /api/app/latest` 确认线上版本；客户端也可能尚未到检查时机（6h），让用户在设置里手动点「检查更新」 |
| 客户端「验签失败」 | 发布私钥与 App 内置公钥不匹配（换过密钥/在别的机器发布）—— 用同一私钥重发，或换公钥后重新打包发版 |
| 安装包 sha256 不一致 | 上传中断，重新执行发布脚本 |
| 服务器 404 `no release published` | `dist/latest.json` 不存在，先发布一次 |

## 注意区分：服务端部署是另一件事

本 skill 只管 **App 发版**。`PetServer` 的部署是：本地 `GOOS=linux GOARCH=amd64 go build` → 上传到 `/opt/petserver/petserver.new` → `mv` 覆盖 → `systemctl restart petserver`（服务监听 :80，配置在 `/opt/petserver/petserver.env`）。
