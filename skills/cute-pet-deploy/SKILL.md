---
name: cute-pet-deploy
description: 桌面宠物 cute pet 的唯一入口，覆盖「跑起来 / 发出去 / 部署服务端」三件事：Electron 版启动调试与功能验收、四条发布通道（本地·远程 × Swift·Electron）、PetServer 部署与线上版本查询。当用户说「跑起来/启动/运行 Electron 宠物」「安装 electron pet」「本地发一版/装到我电脑上」「发版/发布/上线/推送到远程」「打 Windows 包/Windows 上线」「部署服务端」时使用。
metadata:
  short-description: 跑起来、发布、部署 cute pet（Swift + Electron）
---

# cute pet（桌面宠物）

两条产品线：**macOS 原生 Swift**（`DesktopPetForMacApp/`）与 **Electron 跨平台**（`DesktopPetElectron/`，覆盖 Windows / macOS）。
三种动作：**跑起来**、**发出去**、**部署服务端**。

## 先看要做哪件事

| 想做的事 | 去哪 | 入口 |
| --- | --- | --- |
| 跑起来 / 改 UI / 验收功能（Electron） | [references/run-electron.md](references/run-electron.md) | `cd DesktopPetElectron && npm start` |
| 本机立刻换成最新 Swift 版 | 通道 A | `scripts/build-mac-local.sh` |
| 让所有 mac 用户能升级 | 通道 B | `scripts/deploy.sh` |
| 打个 Windows 包自己试 | 通道 C | `scripts/build-win-local.sh` |
| 打个 macOS 的 Electron 包自己试 | 通道 E | `scripts/build-mac-electron-local.sh` |
| 让 Windows 用户能下载、能升级 | 通道 D | `scripts/deploy-win.sh` |
| 部署 / 回滚服务端 | [references/release.md](references/release.md) | `scripts/deploy-server.sh` |
| 查线上版本 | — | `curl http://101.96.248.75/api/app/latest` |

## 五条通道（3 本地 + 2 远程）

| 通道 | 命令 | 影响范围 | 可逆 |
| --- | --- | --- | --- |
| **A 本地 Swift** | `build-mac-local.sh` | 只有本机桌面 App | 可反复折腾 |
| **B 远程 Swift** | `deploy.sh` | 线上 mac 自动更新 + 官网 dmg | **不可撤回** |
| **C 本地 Windows** | `build-win-local.sh` | 只有本机 `dist/` | 可反复折腾 |
| **D 远程 Windows** | `deploy-win.sh` | 官网 Windows 按钮 + 线上 Windows 客户端 | **不可撤回** |
| **E 本地 Electron macOS** | `build-mac-electron-local.sh` | 只有本机 `dist/`（dmg + zip） | 可反复折腾 |

分界线只有一条：**A / C / E 不签名、不上传、不动线上；B / D 才发到 101.96.248.75，一旦发出无法撤回。**
一次改动同时涉及接口与客户端时，**先部署服务端（保持向后兼容），再发客户端**。

## 四条铁律（发布前默读）

1. **manifest 必须合并写**：`latest.json` 一个文件承载三条通道（mac `version` / `winVersion` / `macVersion`），任何一次发布都要「拉现状 → 只改自己那段 → 写回」。整体覆盖会把别的平台更新通道挤断。
2. **版本号只能递增**，同一版本号不要重复发布不同内容 —— 已升级的用户不会再下载。
3. **签名私钥不可丢**：`~/.cute-pet-release/ed25519_private.pem`；丢了老客户端再也收不到更新，泄露则可能被伪造更新。
4. **发完不要在本机 `rebuild.sh`**，除非就是要让本机立刻升级 —— 本机保持旧版才有得测更新链路。

另：Windows 必须发 **NSIS 安装版**（`DesktopPet Setup *.exe`），便携版无法自我替换。

## 版本号与升级时机

| 通道 | 形态 | 唯一来源 | 示例 |
| --- | --- | --- | --- |
| A / B Swift | `v主.次.修订`（补零位宽） | `App/AppVersion.swift` | `v1.0.035` |
| C / D Electron | 纯数字 `主.次.修订`（manifest 存 `electron` 前缀） | `DesktopPetElectron/package.json` | `electron0.0.4` |

| 端 | 自动检查时机 |
| --- | --- |
| mac 原生 | 启动 30 秒后、每 6 小时、设置里「检查更新」 |
| Electron（Win/macOS） | 启动 30 秒后、每 24 小时、托盘「检查更新」 |

签名对象固定是 **sha256 的十六进制字符串**；客户端要同时通过「摘要比对」与 Ed25519 验签，任一不过直接拒装。

## 分层导航

```
skills/cute-pet-deploy/
├── SKILL.md                            # 你正在看的：路由 + 发布矩阵 + 铁律
├── references/
│   ├── release.md                      # 发布细节：通道 A–D、manifest 契约、服务端部署、图片对象、SQLite、排障
│   ├── run-electron.md                 # Electron 运行/调试：设置面板、状态机、右键菜单、心跳、打包自测、排障
│   └── auto-update-and-release.md      # 深度参考：更新机制、安全模型、密钥生成、dmg 制作、Windows 通道
└── scripts/                            # 全部发布 / 部署脚本（路径不变，深度仍是 ../../.. 到仓库根）
```

- 只是**跑起来看看**或改 Electron 的 UI/交互 → 读 `references/run-electron.md`，不要碰发布流程。
- 要**发出去** → 先看上面四条通道，再读 `references/release.md` 对应章节。
- 脚本用法都在 `scripts/*.sh --help` 或 `references/release.md` 的「相关文件」表里。
