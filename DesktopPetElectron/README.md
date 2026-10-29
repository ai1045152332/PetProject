# DesktopPetElectron — 跨平台桌面宠物（Electron 版）

macOS 原生版（`DesktopPetForMacApp`）的跨平台重写，目标同时覆盖 Windows / macOS。
采用分阶段推进，当前进度：**P0 悬浮窗**。

## 阶段路线

| 阶段 | 内容 | 状态 |
|------|------|------|
| P0 | 透明、置顶、无边框悬浮窗 + focus 帧循环 | ✅ 当前 |
| P0+ | 心跳上报（`/api/heartbeat`，1 分钟一次，与 mac 版同上报体） | ✅ |
| P0+ | 自动更新（检查 / 下载 / sha256 + Ed25519 校验 / 安装）+ 托盘手动检查 | ✅ |
| P1 | 精灵图动画 + 完整状态机 | ⏳ |
| P2 | 拖拽 / 点击 / 托盘 | ⏳ |
| P3 | 右键菜单 + 喝水提醒 | ⏳ |
| P4 | 新闻 / 天气 / 股票服务 | ⏳ |
| P5 | Todo + 背单词 | ⏳ |
| P6 | electron-builder 打包 Windows / macOS 安装包 | ✅ 已配置 |

## 运行

```bash
cd DesktopPetElectron
npm install
npm start
```

## 打包桌面 App（electron-builder）

已配置 `electron-builder`，可打成可双击安装的原生 App，产物统一输出到 `dist/`。

| 命令 | 目标平台 | 产物 |
|------|----------|------|
| `npm run dist:mac` | macOS | `dist/*.dmg` + `dist/*.zip`（内含 `DesktopPet.app`） |
| `npm run dist:win` | Windows | `dist/*-setup.exe`（NSIS 安装包）+ `dist/*.portable.exe` |
| `npm run dist` | 当前系统 | 按当前 OS 自动打对应包 |

图标资源放在 `packaging/`：`icon.icns`（mac）、`icon.png`（1024×1024，electron-builder 会据此自动生成 Windows `icon.ico`）。

### macOS 打包

```bash
# 本机无开发者证书时跳过签名，避免构建中断
CSC_IDENTITY_AUTO_DISCOVERY=false npm run dist:mac
```

> 打出的 `.app` 未签名，首次打开需在「系统设置 → 隐私与安全性」里点「仍要打开」，或用 `xattr -dr com.apple.quarantine DesktopPet.app` 去隔离。

### Windows 打包

- **推荐在 Windows 机器上执行** `npm run dist:win`，最稳妥。
- 在 macOS / Linux 上交叉打 Windows 包时，`nsis` 目标可能需要安装 **Wine**（`brew install --cask wine-stable`）；`portable` 目标一般无需 Wine 可直接产出。
- Windows 安装包同样默认未做代码签名。


## 目录结构

```
DesktopPetElectron/
├── package.json
├── src/
│   ├── main/
│   │   ├── index.js            # 主进程入口 + 应用生命周期 + 各服务接线
│   │   ├── pet-window.js       # 透明置顶悬浮窗
│   │   ├── tray.js             # 托盘菜单（显隐 / 检查更新 / 退出）+ 状态提示
│   │   ├── heartbeat.js        # 心跳上报（1 分钟一次，移植自 mac 版 HeartbeatService）
│   │   ├── update-service.js   # 自动更新：检查 / 下载 / sha256 + Ed25519 校验 / 安装
│   │   ├── app-info.js         # 版本号、设备 ID（IOPlatformUUID / MachineGuid）、宠物名
│   │   ├── config-store.js     # 配置持久化（userData/pet-config.json）
│   │   ├── reminder-scheduler.js
│   │   └── reminder-window.js
│   └── renderer/
│       ├── index.html        # 宠物窗口页面
│       ├── pet.css           # 透明 + 拖动区域样式
│       ├── pet.js            # 帧循环（后续扩展为状态机）
│       ├── preload.js        # 预加载脚本占位
│       └── reminder.*        # 喝水提醒窗（html/css/js）
├── tests/
│   └── update-heartbeat.test.js # 版本比较 / 平台选包 / 验签 / 心跳上报体断言（node 直接跑）
└── assets/
    └── Sprites/              # 从 mac 工程拷贝的动画帧（focus/idel/sleep/pet，提醒已合并进专注，warn 已删除）
```

- 打包相关：`packaging/`（图标资源 icon.icns / icon.png）、`dist/`（electron-builder 产物）。

## 心跳上报

`src/main/heartbeat.js` 移植 mac 版 `HeartbeatService`：启动立即上报一次，之后每 1 分钟一次，POST `{serverBaseURL}/api/heartbeat`。

- 上报体与 mac 版完全一致：`version / hostname / os / machine / petName / petState / deviceId`，服务端无需区分客户端类型。
- `version` 形如 `electron0.0.1`（**Electron 版专用前缀**），与 mac 原生版的 `v1.0.031` 一眼区分，后台设备列表不会认错版本。
- `deviceId` 与 mac 原生版同源（macOS 读 `IOPlatformUUID`，Windows 读注册表 `MachineGuid`），**同一台机器两版共用宠物号**。
- 响应里的 `petNo` 会写回 `pet-config.json`；失败只在「原因变化」时打一条日志，避免断网时刷屏。
- 服务端地址取 `pet-config.json` 的 `serverBaseURL`，默认 `http://101.96.248.75`。

## 自动更新 / 检查更新

`src/main/update-service.js` 移植 mac 版 `UpdateService`，服务端契约不变（`GET /api/app/latest` + `GET /download/<文件名>`）。

| 时机 | 行为 |
|------|------|
| 启动 30 秒后 | 清理历史更新残留 + 首次检查（失败静默） |
| 每 24 小时 | 自动检查（失败静默，无更新静默） |
| 托盘「检查更新」 | 用户主动检查，无更新 / 失败也会提示 |

流程：检查版本 → 有新版本弹「立即更新 / 稍后」→ 流式下载到 `userData/updates/` → 校验 sha256 → Ed25519 验签（签名对象为 sha256 十六进制串，与 mac 版同一把发布公钥）→ 按平台安装：

- **Windows**：`.exe` 用 NSIS 静默安装（`/S`）后自动退出并拉起新版本；`.msi` 走 `msiexec /i /qb`。
- **macOS**：`.dmg` 打开让用户拖进「应用程序」（不做静默换包）。
- **其他**（如 zip）：打开文件所在目录，提示手动安装。

### 跨平台发布字段（服务端 `latest.json`）

Electron 版**只认带平台前缀的字段**，避免把 mac 原生 Swift 版的 zip/dmg 当成自己的安装包：

| 字段 | 用途 |
|------|------|
| `version` / `file` / `sha256` / `signature` | mac 原生 Swift 版（自动更新，勿动语义） |
| `winVersion` / `winFile` / `winSHA256` / `winSignature` / `winNotes` | Electron 版 Windows 通道（exe/msi） |
| `macVersion` / `macFile` / `macSHA256` / `macSignature` / `macNotes` | Electron 版 macOS 通道（dmg/zip） |

平台字段缺失时客户端提示「服务端还没有发布该平台安装包」，不会回落到 `version`/`file`。服务端 `model.Release` 已同步支持这些字段（`omitempty`，旧客户端无感），**需要先部署新版 PetServer 再发 Electron 包**。

> 版本号格式：Electron 版自身版本形如 `electron0.0.1`（取自 `package.json` 的 `version` 加 `electron` 前缀），mac 原生版是 `v1.0.031`。`winVersion`/`macVersion` 必须写成同样的 `electron` 前缀形式，并与包内 `package.json` 的 `version` 对应，否则会出现「装完还提示同一版本」的循环。比较时会自动剥掉 `electron`/`v` 前缀，两种前缀视为同一版本序列。

手工发布 Windows 包（与 mac 版同一把私钥 `~/.cute-pet-release/ed25519_private.pem`）：

```bash
npm run dist:win                     # 产出 dist/*-setup.exe
SHA=$(shasum -a 256 dist/*-setup.exe | awk '{print $1}')
printf '%s' "$SHA" > digest.txt
SIG=$(openssl pkeyutl -sign -rawin -inkey ~/.cute-pet-release/ed25519_private.pem -in digest.txt | base64 | tr -d '\n')
# 把 winVersion/winFile/winSHA256/winSignature/winNotes 加进服务器 dist/latest.json，安装包放到服务器 dist/ 下
```

## 测试

```bash
npm test          # node tests/update-heartbeat.test.js：版本比较、平台选包、真实签名验签、心跳上报体
```

## 说明

- 资源（Sprites）从 `DesktopPetForMacApp` 拷贝而来，后续词库 / 题库接入方式相同。
- 服务端 `PetServer`（Go）跨平台，心跳 / 版本接口与 mac 版共用（Electron 发布字段见上文「跨平台发布字段」）。
