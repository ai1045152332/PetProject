# 发布 cute pet（四条通道 + PetServer）

> 本文件是 [../SKILL.md](../SKILL.md) 的发布篇：通道 A–E 细节、manifest 契约、服务端部署、数据目录与排障。
> 只想把 Electron 版跑起来调试 → 看 [run-electron.md](run-electron.md)。

## 通道 A：本地 Swift 版（只影响本机）

```bash
./skills/cute-pet-deploy/scripts/build-mac-local.sh              # 编译 → 覆盖桌面 app → 重启
./skills/cute-pet-deploy/scripts/build-mac-local.sh --no-launch  # 编译 → 覆盖桌面 app，不启动
./skills/cute-pet-deploy/scripts/build-mac-local.sh --no-desktop # 只产出仓库内 cute pet.app，桌面那份继续跑
```

- 不改版本号，不签名，不上传；等价包装 `DesktopPetForMacApp/package.sh` 与 `rebuild.sh`
- `--no-desktop` 用于「先看编译产物、稍后再换」，正在运行的旧版本不受影响
- 要改版本号或给用户升级，走通道 B

## 通道 B：远程 Swift 版（mac 原生客户端自动更新）

```bash
./skills/cute-pet-deploy/scripts/deploy.sh --check                 # 只检查环境与下一个版本号
./skills/cute-pet-deploy/scripts/deploy.sh                         # 自动递增补丁版本并发布
./skills/cute-pet-deploy/scripts/deploy.sh v1.0.034 "用户看得懂的说明"
COMMIT=1 ./skills/cute-pet-deploy/scripts/deploy.sh ...            # 发布后顺带 git 提交并推送
```

脚本：校验私钥与上传助手 → 解析/递增版本号（保持 `033 → 034` 补零位宽）→ 调 `DesktopPetForMacApp/release.sh`（产出 zip + dmg）→ **合并写 latest.json** → 校验服务器 manifest 与本地包的 sha256 一致。

产物分工：**zip 给客户端自动更新**（`file`/`sha256`/`signature`），**dmg 给官网手动安装**（`dmgFile`/`dmgSHA256`/`dmgSignature`，内带 `/Applications` 软链）。两者同源于同一次 `cute pet.app`。

发布说明必须是**用户能读懂的中文**（例：「修复了天气提醒时间看不清的问题」），技术细节留在 commit message。

## 通道 C：本地 Windows 版（Electron 交叉打包）

```bash
./skills/cute-pet-deploy/scripts/build-win-local.sh --dry-run            # 预览将清理什么、将打哪个版本
./skills/cute-pet-deploy/scripts/build-win-local.sh                      # 清旧产物 → 按 package.json 版本打包
./skills/cute-pet-deploy/scripts/build-win-local.sh --version 0.0.3      # 先改版本号再打包
./skills/cute-pet-deploy/scripts/build-win-local.sh --arm64              # ARM64（默认 x64）
```

- macOS 上交叉打包**无需 Wine**：electron-builder 25 自带 NSIS 工具链，产出安装版 `DesktopPet Setup <版本>.exe` 与便携版 `DesktopPet <版本>.exe`
- **只有安装版能自动更新**：便携版跑在临时解包目录里，无法自我替换（客户端会提示手动替换）
- `DesktopPetElectron/dist/` 是 mac 与 Windows **共用**输出目录。打新包前必须清旧 Windows 产物，否则 dist 越积越多容易发错版本；清理脚本只匹配 `*.exe` / `*.exe.blockmap` / `latest.yml` / `win-*`，mac 的 dmg/zip 天然保留
- 版本号是产物文件名与自动更新比较的唯一来源（`package.json` 的 `version`）：要打「新版本」先改版本号再打包，否则同名 exe 直接覆盖
- 产物未签名，Windows 首启弹 SmartScreen 属正常

## 通道 D：远程 Windows 版（官网可下载 + Windows 客户端自动更新）

```bash
./skills/cute-pet-deploy/scripts/deploy-win.sh --check                  # 只检查环境、打印计划版本
./skills/cute-pet-deploy/scripts/deploy-win.sh                          # 自动递增 electron 补丁版本并发布
./skills/cute-pet-deploy/scripts/deploy-win.sh electron0.0.4 "更新说明"  # 指定版本（写 0.0.4 也行）
./skills/cute-pet-deploy/scripts/deploy-win.sh --skip-build             # 复用 dist 里已打好的包
./skills/cute-pet-deploy/scripts/deploy-win.sh --dry-run --skip-build    # 预演：签名 + 出 manifest，不上传
```

`--dry-run` 会走完选包、sha256、签名、签名自检、manifest 合并，把结果打印出来后就退出，**不清理 dist、不写 package.json、不上传**，适合第一次试跑或核对字段。

脚本流程：校验私钥/上传助手/服务器可达 → 解析版本（取「服务器已发 winVersion」与「package.json」较大者递增）→ 写 `package.json` 版本 → 清旧 Windows 产物 → `npm run dist:win`（或 `--arm64`）→ **只挑 NSIS 安装版 setup.exe** → 重命名为 `desktop-pet-win-<版本>-setup.exe` → sha256 + Ed25519 签名 → **合并写 latest.json 的 win\* 字段** → 先传包再换 manifest → 回读 `/api/app/latest` 验证。

发完自动具备两件事（无需额外操作）：
1. **官网可下载**：官网首页读 `winFile` 生成「下载 Windows 版」按钮，`winFile` 为空时按钮自动隐藏
2. **自动更新可用**：Windows 客户端启动 30 秒后 / 每 24 小时 / 托盘「检查更新」比对 `winVersion`

## 通道 E：本地 Electron macOS 版（只影响本机）

```bash
./skills/cute-pet-deploy/scripts/build-mac-electron-local.sh                 # 清旧 mac 产物 → 打包（dmg + zip）
./skills/cute-pet-deploy/scripts/build-mac-electron-local.sh --version 0.0.5 # 先改 package.json 版本再打包
./skills/cute-pet-deploy/scripts/build-mac-electron-local.sh --dry-run       # 只看将清理什么、打哪个版本
./skills/cute-pet-deploy/scripts/build-mac-electron-local.sh --open          # 打完自动挂载 dmg
```

- 产物：`DesktopPetElectron/dist/DesktopPet-<版本>-arm64.dmg` 与 `-x64.dmg`（默认两个架构都打，`--arch arm64|x64` 只打一个）+ 各自的 `-mac.zip`（自动更新包，本地用不到）
- 发布到 manifest 时用 `macFiles: { arm64: {file,sha256,signature,size}, x64: {...} }` 分流；官网按访客 CPU 选、客户端按 `process.arch` 取，老 manifest 回落到单文件 `macFile`
- 不签名（`CSC_IDENTITY_AUTO_DISCOVERY=false`，产物是 ad-hoc 签名），不上传、不改线上；只影响本机 `dist/`
- 清理逻辑与通道 C 对称：一次只删自己那半边（`clean-mac-dist.sh` 保留 `*.exe` / `latest.yml` / `win-*`，`clean-win-dist.sh` 保留 dmg / `*-mac.zip` / `mac-*`）
- **踩过的坑**：`packaging/icon.icns` 是指向 `SharedAssets/AppIcon.icns` 的软链，electron-builder 给 dmg 卷写 `.VolumeIcon.icns` 时不跟随软链，会报
  `xattr.Set /Volumes/…/.VolumeIcon.icns com.apple.FinderInfo: no such file or directory`。脚本会用 `cp -L` 把图标物化到临时目录再 `-c.dmg.icon=…` 传入；不要删掉这一步，也不要把软链改回真实副本（共享素材只存一份）。
- 归属：这是 **Electron 线**的 macOS 包。给 mac 用户升级走通道 B（Swift 原生版）；manifest 里的 `macVersion/macFile` 通道目前未启用。
- 首次打开：右键 App →「打开」，或 `xattr -dr com.apple.quarantine /Applications/DesktopPet.app`

## 通道 F：远程 Electron macOS 版（官网 + 客户端自动更新）

```bash
./skills/cute-pet-deploy/scripts/deploy-mac-electron.sh --check                 # 只检查环境与计划版本
./skills/cute-pet-deploy/scripts/deploy-mac-electron.sh --dry-run --skip-build   # 预演：签名 + 出 manifest，不上传
./skills/cute-pet-deploy/scripts/deploy-mac-electron.sh v1.1.001 "更新说明"       # 正式发：双架构
./skills/cute-pet-deploy/scripts/deploy-mac-electron.sh --arch arm64 ...          # 只发一个架构（官网会提示）
./skills/cute-pet-deploy/scripts/deploy-mac-electron.sh --takeover ...            # 同时接管 Swift 通道
```

- 产物：`dist/DesktopPet-<版本>-arm64.dmg` / `-x64.dmg`，每次发布写 `macFiles: { arm64: {...}, x64: {...} }`
- 官网按访客 CPU 自动选架构，客户端按 `process.arch` 取自己那条；都不跨架构回落
- `--takeover` 会把 `version/file/sha256/signature/size` 指向 **universal zip**，让老 Swift 用户升级时换成 Electron 版；
  **必须**是 universal（老用户里有 Intel Mac），脚本会拒绝单架构接管
- 发布顺序：先部署服务端（官网要认 `macFiles`）→ 再发客户端

## manifest 契约（三条通道共存，严禁整体覆盖）

`/opt/petserver/dist/latest.json` 一个文件同时承载三条发布通道，客户端**只认自己那段字段**：

| 字段 | 归属 | 用途 |
| --- | --- | --- |
| `version` / `file` / `sha256` / `signature` / `size` / `dmgFile` / `dmgSHA256` / `dmgSignature` / `dmgSize` | mac 原生 Swift 版 | 自动更新只认 zip 那四个字段，dmg 给官网 |
| `winVersion` / `winFile` / `winSHA256` / `winSignature` / `winNotes` / `winSize` | Electron Windows 版 | exe 安装包，客户端不回落无前缀字段 |
| `macVersion` / `macFile` / `macSHA256` / `macSignature` / `macNotes` / `macSize` | Electron macOS 版 | 预留通道，mac 客户端只在这里生效 |

**核心规则：任何一次发布都必须「拉现状 → 只改自己那段 → 写回」。** 用只含一个平台的 manifest 整体覆盖，会把另外两条通道的字段抹掉，对应平台的自动更新立刻断（客户端提示「服务端还没有发布该平台安装包」）。`release.sh` 与 `deploy-win.sh` 都已内置合并逻辑，手工上传时不要直接覆盖。

签名对象固定是 **sha256 的十六进制字符串**；客户端必须同时通过「摘要比对」与「Ed25519 验签」，任一不过直接拒绝安装。三条通道共用同一把私钥 `~/.cute-pet-release/ed25519_private.pem`。

## 版本号的两条规则（表见 [../SKILL.md](../SKILL.md)）

- Swift 版版本号变化会触发客户端「清除旧版本校验权限」（需重新输激活码），这是刻意设计
- Electron 版 `winVersion` 必须写成 `electron0.0.3` 形式，并与包内 `package.json` 的 `version` 对应；两者不一致会出现「装完还提示同一版本」的循环
- 比较时自动剥掉 `electron` / `v` 前缀；**同一版本号不要重复发布不同内容**，已升级到该版本的客户端不会再次下载，这批人等于永远收不到修复

## 部署服务端（PetServer）

```bash
./skills/cute-pet-deploy/scripts/deploy-server.sh --check     # 只检查 SSH/配置/连通性
./skills/cute-pet-deploy/scripts/deploy-server.sh            # 编译并部署（含验证）
```

1. `go vet` + `go test`（测试失败仅告警）
2. `GOOS=linux GOARCH=amd64` 交叉编译
3. **rsync 断点续传上传**（链路抖动可重试续传），最多 5 次
4. **校验远端 sha256 == 本地构建**；不一致放弃，绝不替换线上文件
5. 备份 `petserver.bak` → 原子替换 → `systemctl restart`
6. 重启后**在服务器内 curl `/api/ping`**，不通过自动回滚旧版
7. 本地再从公网验证 `/api/ping`、`/api/devices`、`/api/app/latest`、`/api/weather`

| 项 | 值 |
| --- | --- |
| 服务 | `systemctl {status,restart,logs} petserver`，监听 `:80` |
| 二进制 | `/opt/petserver/petserver`（备份 `.bak`） |
| 配置 | `/opt/petserver/petserver.env`（0600；后台密码、天气 Key） |
| 数据 | `/opt/petserver/data/`（会话/设备快照/激活码/心跳日志/私钥） |
| 发布包 | `/opt/petserver/dist/`（latest.json + 各平台安装包） |
| 日志 | `/var/log/petserver.log` |

`PETSERVER_LISTEN_ADDR` 默认 `:8080`，公网部署在 env 里设为 `:80`。重启不会丢数据（会话与设备列表均持久化）。

## 关键约束（容易踩；四条铁律见 [../SKILL.md](../SKILL.md)）

- **远端通道双后端**：expect 助手（需 pty）优先；pty 耗尽时自动切 paramiko（`scripts/remote.sh` + `scripts/lib/remote.py`，装到 `~/.catpaw/pylibs`）。强制后端用 `CUTE_PET_REMOTE_BACKEND=paramiko|expect`。**remote_put 必须整文件覆盖**，绝不能按远端大小“续传”（会把新旧内容拼接成一个损坏文件，曾把 latest.json 拼坏导致 `/api/app/latest` 500）
- **客户端与服务端成对绑定**：App 内嵌发布验签公钥（Swift `UpdateService.swift` / Electron `update-service.js`）、载荷加密公钥、后端地址（`ServerConfig.swift` / `config-store.js`）。换服务器或换密钥必须同时改这些地方并重新发版
- **不要把密码/密钥写进仓库**：发布私钥与上传助手只存 `~/.cute-pet-release/`
- 跨平台发布字段依赖服务端 `model.Release`（`omitempty`，旧客户端无感）：**先部署新版 PetServer，再发 Electron 包**

## 客户端的升级交互

时机表见 [../SKILL.md](../SKILL.md)。两端的升级交互都是**非强制**两步确认：发现新版本 → 立即更新/稍后；下载校验完成 → 重启并更新/稍后。Windows 走 NSIS 静默安装（`/S`）后自动拉起新版；Electron macOS 只打开 dmg 让用户拖进「应用程序」。

## 宠物图片对象目录

`/opt/petserver/data/pet-images/objects/` 按「设备 → 一次上传一个文件夹」组织：

```
objects/<sha256(设备ID)>/<YYYYMMDD-HHMMSS-6hex>/
    original-<文件名标签>.jpg   # 本次上传的原图
    focus-<文件名标签>.png      # 本次为该状态生成的图（idel/sleep/pet/hide 同理）
```

设备目录是硬件 ID 的 SHA-256（不把设备 ID 明文落盘），批次目录取上传时间 UTC。记录里的 `sourceId` 与 `objectId` 是相对设备目录的路径；客户端可见的 `id` 固定为 32 位小写 hex（同时是本地缓存文件名 `cloud-<id>.img`）。旧版平铺布局仍可读。若从旧备份恢复 `pet-images`，先备份再按上述布局手工重排。

## 好友与消息库（SQLite）

好友/宠物消息已从 `data/social.json` 迁到 `data/petserver.db`（驱动 `ncruces/go-sqlite3`，纯 Go 无 CGO，不影响交叉编译）：

- 首次启动自动导入：只在「库里没设备 + `social.json` 非空」时跑，宠物号、未读消息、待处理申请原样保留；旧 `social.json` **原地保留不删**
- 部署后验收：`journalctl -u petserver | grep social`，应看到 `[social] 已从 social.json 导入：…` 与 `好友与消息存储: SQLite data/petserver.db`
- 备份：`*.db` / `*-wal` / `*-shm` 三个文件必须一起；打包整个 `data/` 自然满足
- 回滚：脚本的健康回滚只换二进制，不退数据。旧版二进制读 `social.json`（切换那刻的快照），宠物号不会丢，但切库后的新消息不在里面

## 排障

| 现象 | 处理 |
| --- | --- |
| 提示版本号与服务器相同 | 递增版本号（脚本会给出建议值） |
| mac 客户端收不到更新 | 先 `curl /api/app/latest` 确认 `version`；客户端也可能尚未到检查时机（6h），让用户手动点「检查更新」 |
| Windows 客户端提示「暂无可用更新」 | manifest 里 `winVersion`/`winFile` 为空 —— 被某次整体覆盖挤掉了，重跑 `deploy-win.sh --skip-build` 或手工补回字段 |
| Windows 装完还提示同一版本 | `winVersion` 与包内 `package.json` 的 `version` 不一致（前者缺 `electron` 前缀或数字不同） |
| 客户端「验签失败」 | 发布私钥与 App 内置公钥不匹配（换过密钥/在别的机器发布）—— 用同一私钥重发，或换公钥后重新打包发版 |
| 安装包 sha256 不一致 | 上传中断，重新执行发布脚本 |
| 官网没有 Windows 下载按钮 | manifest 无 `winFile`，或官网是旧二进制（静态页 embed 在服务端里，改完要 `deploy-server.sh`） |
| dmg 打开后没有背景箭头 | 终端未获控制 Finder 的权限，AppleScript 被拒；到「隐私与安全性 > 自动化」允许后重新发版 |
| `deploy-win.sh` 报找不到 NSIS 安装包 | dist 里只有便携版 `<名称> <版本>.exe`；重新 `npm run dist:win` 产出 `DesktopPet Setup <版本>.exe` |
| electron-builder 打包失败 | 看 `/tmp/deploy_win_build.log`（或 `/tmp/build_win_local.log`），常见原因是 `node_modules` 缺失或版本号写成了非法格式 |
| 服务端部署报「未确认远端启动结果」 | 替换/重启那条 SSH 连接中途断了。二进制已上传并校验，重跑一次 `deploy-server.sh` 即可 |
| 上传全部失败，报 `The system has no more ptys` | pty 被耗尽，expect 助手不可用。用 `CUTE_PET_REMOTE_BACKEND=paramiko` 重试（已内置自动回退，若未生效先跑 `python3 -m pip install --target ~/.catpaw/pylibs paramiko`） |
| `/api/app/latest` 500 | 检查服务器 `dist/latest.json` 是否为合法 JSON（曾被拼接损坏）；用本地 manifest 重传即可 |
| manifest 里 win 字段时有时无 | 某次发布用了只含单个平台的 manifest 整体覆盖；重跑对应发布脚本（已内置合并） |
| 服务端部署卡在「上传中断」 | 到服务器链路差。脚本会拒绝替换线上文件；网络恢复后重跑，或用 `CUTE_PET_SSH_HOST` 换出口 |
| 服务端部署后 SEGV/重启循环 | 通常是二进制被截断。sha 校验会拦住；已发生则 `mv petserver.bak petserver && systemctl restart petserver` |
| rsync 报 `--append` 相关错误 | 已改用 `--partial --inplace`（目的文件不存在时 `--append-verify` 会报错） |
| 服务器 404 `no release published` | `dist/latest.json` 不存在，先发布一次 |

## 相关文件

| 用途 | 位置 |
| --- | --- |
| 本地 Swift 发版 | `skills/cute-pet-deploy/scripts/build-mac-local.sh` |
| 远程 Swift 发版 | `skills/cute-pet-deploy/scripts/deploy.sh` → `DesktopPetForMacApp/release.sh` |
| 本地 Windows 打包 | `skills/cute-pet-deploy/scripts/build-win-local.sh` |
| 本地 Electron macOS 打包 | `skills/cute-pet-deploy/scripts/build-mac-electron-local.sh` |
| 远程 Electron macOS 发版 | `skills/cute-pet-deploy/scripts/deploy-mac-electron.sh` |
| 清理旧 mac 产物 | `skills/cute-pet-deploy/scripts/clean-mac-dist.sh` |
| 远程 Windows 发版 | `skills/cute-pet-deploy/scripts/deploy-win.sh` |
| 清理旧 Windows 产物 | `skills/cute-pet-deploy/scripts/clean-win-dist.sh` |
| 远端执行/上传统一后端 | `skills/cute-pet-deploy/scripts/remote.sh` + `scripts/lib/remote.py` |
| 服务端部署 | `skills/cute-pet-deploy/scripts/deploy-server.sh` |
| Swift 打包 / 版本号 / 更新器 | `DesktopPetForMacApp/{package.sh, DesktopPetForMacApp/App/AppVersion.swift, .../Services/UpdateService.swift}` |
| Electron 打包 / 版本 / 更新器 | `DesktopPetElectron/{package.json, src/main/update-service.js, src/main/app-info.js}` |
| 服务端下发接口 / 官网 | `PetServer/internal/{controller/release_controller.go, web/site/index.html}` |
| 线上版本查询 | `curl http://101.96.248.75/api/app/latest` |

## 深度参考

- [references/auto-update-and-release.md](references/auto-update-and-release.md) — 更新机制、安全模型、密钥生成、dmg 制作、Windows 通道细节与常见排障
