# DesktopPetElectron — 跨平台桌面宠物（Electron 版）

macOS 原生版（`DesktopPetForMacApp`）的跨平台重写，目标同时覆盖 Windows / macOS。
采用分阶段推进，当前进度：**P0 悬浮窗**。

## 阶段路线

| 阶段 | 内容 | 状态 |
|------|------|------|
| P0 | 透明、置顶、无边框悬浮窗 + focus 帧循环 | ✅ 当前 |
| P0+ | 心跳上报（`/api/heartbeat`，1 分钟一次，与 mac 版同上报体） | ✅ |
| P0+ | 自动更新（检查 / 下载 / sha256 + Ed25519 校验 / 安装）+ 托盘手动检查 | ✅ |
| P0+ | 设置面板（喝水提醒间隔：预设 15/30/45/60 + 自定义 1～120 分钟） | ✅ |
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
- **架构默认 x64**：`dist:win` 已带 `--x64`。在 Apple Silicon Mac 上交叉打包时，若不带该参数会默认产出 arm64 包，绝大多数 Windows 机器（Intel/AMD）无法运行。ARM64 Windows 用 `npm run dist:win:arm64`（产物同名，与 x64 包互相覆盖，需要并存请自行加 `artifactName` 区分）。
- 在 macOS / Linux 上交叉打 Windows 包时，`nsis` 目标可能需要安装 **Wine**（`brew install --cask wine-stable`）；`portable` 目标一般无需 Wine 可直接产出。
- Windows 安装包同样默认未做代码签名。

### Windows 安装

**方式一：直接用已有安装包**（`dist/` 下已构建好，拷到 Windows 即可）

| 文件 | 用法 |
|------|------|
| `DesktopPet Setup <版本>.exe` | NSIS 安装包：双击安装，可改安装目录、自动建桌面快捷方式 |
| `DesktopPet <版本>.exe` | portable 免安装版：双击直接运行，适合放 U 盘或不想写注册表 |

未做代码签名，首次运行 Windows SmartScreen 会拦截：点「更多信息 → 仍要运行」。

**方式二：在 Windows 机器上看源码构建**

```powershell
# 1) Node.js 18+（LTS）装好，确认 node -v / npm -v 可用
# 2) 装依赖；国内网络建议给 Electron 二进制走镜像，否则容易卡在下载
npm config set registry https://registry.npmmirror.com
$env:ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"
npm install
# 3) 开发运行 / 打包
npm start
npm run dist:win
```

产物在 `dist/`：`*-setup.exe`（安装包）+ portable `.exe`。

### 悬浮窗与托盘行为

- **置顶**：窗口用 `screen-saver` 层级，并由置顶守护在失焦、重新显示、以及定时（Windows 5 秒 / macOS 10 秒）重新声明置顶——Windows 上 `alwaysOnTop` 只设一次会被后续的置顶窗口压下去。打开设置面板、提醒窗、托盘菜单时宠物会主动让出层级，关闭后自动收回。
- **托盘**：Windows 左键单击切换显示/隐藏、右键弹菜单（不再用 `setContextMenu`，否则左键单击会同时弹菜单又切换）；macOS 左键/右键都弹菜单，显隐走菜单项。菜单文案随当前状态在「显示宠物 / 隐藏宠物」之间切换。
- **快捷键**：`Ctrl/Cmd + Alt + P` 切换显示/隐藏（Win11 托盘图标会折进隐藏区时的兜底），`Ctrl/Cmd + Alt + W` 立即弹一次喝水提醒。
- **限制**：独占全屏（部分游戏）和以管理员权限运行的前台程序，普通权限进程的悬浮窗压不上去，这是 Windows 的窗口层级规则，非应用可绕过。


## 目录结构

```
DesktopPetElectron/
├── package.json
├── src/
│   ├── main/
│   │   ├── index.js            # 主进程入口 + 应用生命周期 + 各服务接线
│   │   ├── pet-window.js       # 透明置顶悬浮窗
│   │   ├── tray.js             # 托盘菜单（显隐 / 设置 / 检查更新 / 退出）+ 状态提示
│   │   ├── settings-window.js  # 设置面板窗口（无边框透明，单例）
│   │   ├── settings-service.js # 设置业务逻辑：读间隔 / 校验写入 / 立即重启计时
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
│       ├── reminder.*        # 喝水提醒窗（html/css/js）
│       └── settings.*        # 设置面板（html/css/js + preload）
├── tests/
│   ├── update-heartbeat.test.js # 版本比较 / 平台选包 / 验签 / 心跳上报体断言（node 直接跑）
│   ├── settings-panel.test.js   # 间隔区间校验 / 持久化 / 改完重启计时 / 脏数据回落
│   ├── on-top-guard.test.js     # 置顶守护：失焦补位 / 定时兜底 / 让出层级 / stop 生效
│   └── tray-interaction.test.js # 托盘：Windows 左键切换右键菜单、mac 弹菜单、文案与 tooltip 跟随状态
└── assets/
    ├── Sprites/              # 从 mac 工程拷贝的动画帧（focus/idel/sleep/pet，提醒已合并进专注，warn 已删除）
    └── tray/                 # 托盘图标（由 MenuBarIcon.png 派生）：MenuBarTemplate(@2x).png 单色模板图（mac）/ WindowsTray(@2x).png 白猫+描边（Windows）
```

- 打包相关：`packaging/`（图标资源 icon.icns / icon.png）、`dist/`（electron-builder 产物）。

## 心跳上报

`src/main/heartbeat.js` 移植 mac 版 `HeartbeatService`：启动立即上报一次，之后每 1 分钟一次，POST `{serverBaseURL}/api/heartbeat`。

- 上报体与 mac 版完全一致：`version / hostname / os / machine / petName / petState / deviceId`，服务端无需区分客户端类型。
- `version` 形如 `electron0.0.1`（**Electron 版专用前缀**），与 mac 原生版的 `v1.0.031` 一眼区分，后台设备列表不会认错版本。
- `deviceId` 与 mac 原生版同源（macOS 读 `IOPlatformUUID`，Windows 读注册表 `MachineGuid`），**同一台机器两版共用宠物号**。
- 响应里的 `petNo` 会写回 `pet-config.json`；失败只在「原因变化」时打一条日志，避免断网时刷屏。
- **可观测性**：成功默认静默，但首报成功与「失败→恢复」各打一条 `[heartbeat] 上报成功（累计 N 次）`；`HEARTBEAT_DEBUG=1 npm start` 可打印每次收发（`→ POST v=electron0.0.1 …` / `← 200 137ms`）。设置面板「通用设置 → 心跳上报」实时显示 `正常 / 失败` 与「最近一次 N 秒前」，面板打开期间每 5s 刷新。
- **卡死自愈**：若某次请求卡在网络栈上（`fetch`/`json` 挂住、abort 未触发）导致 `sending` 恒为 true，下一次 tick 发现超时超过 2 个周期会强制解锁重发并记一条 `上次上报卡住 Ns 未返回，已重置`，不会静默停摆。
- 服务端地址取 `pet-config.json` 的 `serverBaseURL`，默认 `http://101.96.248.75`。

> 排查「有没有心跳」不要只看日志（成功静默）：直接查服务端的设备列表 ——
> `curl -s http://101.96.248.75/api/devices` 里找自己的 `deviceId`，看 `version` 是 `electron0.0.1` 还是 `v1.0.031`。
> 同一台机器上两版共用 `deviceId`，**记录会被对方交替覆盖**（各自 60s 一次），采样一两次看到 `v1.0.031` 是 mac 原生版刚上报，不代表 Electron 版没报。

## 设置面板

对齐 mac 版 `SettingsPanel` 的信息架构：窗口 720×500，**左侧 158px 一级菜单**（🐱 宠物信息 / ⚙️ 通用设置 / 🔔 提醒设置 / 🖱️ 菜单设置 / 👫 好友消息），右侧内容区按菜单切换并独立滚动。

| 一级菜单 | 本版状态 | 内容 |
|----------|----------|------|
| 🐱 宠物信息 | 部分可用 | 形象切换（专注/休闲/睡觉/抚摸，点击即时切帧）✅、宠物名称 ✅、宠物号展示 ✅；自定义状态图片（本期不做） |
| ⚙️ 通用设置 | 部分可用 | 开机自启 ✅、宠物大小 0.5x～2.0x ✅、版本号 + 检查更新 ✅；权限校验码（本期不做） |
| 🔔 提醒设置 | 喝水可用 | 喝水提醒 ✅（预设 15/30/45/60 + 自定义 1～120 + 测试提醒）；天气提醒、主动搭话（本期不做） |
| 🖱️ 菜单设置 | 本期不做 | 宠物右键菜单展示项（本版还没有右键菜单，路线图 P3） |
| 👫 好友消息 | 本期不做 | 宠物号展示 ✅；添加好友 / 消息列表待接入（服务端接口已就绪） |

入口：

| 入口 | 说明 |
|------|------|
| 菜单栏托盘 →「设置…」 | 主要入口 |
| 应用菜单 →「设置…」（`Cmd+,`） | 仅 macOS |
| `Esc` / 右上角 × | 关闭面板 |

喝水提醒的行为细节：

- 持久化：`pet-config.json` 的 `drinkWaterInterval`（对标 UserDefaults `settings.drinkWaterInterval`，默认 30 分钟）。
- 预设点击**立即生效**，无需再点应用（对齐 mac 版 `intervalButtonClicked`）；自定义值越界 / 非整数给红字提示且不写入。
- 改完立即**重新对齐计时**：从下一个能被新间隔整除的分钟点开始（`.restart()` → `ReminderScheduler.start()`）。
- 配置被手工改坏（0 / 999 / 非数字）读取时自动收敛到合法值，不会因为脏数据导致提醒失效。

其他持久化字段：`petName`（心跳上报，空值回落「毛豆」）、`petScale`（0.5～2.0，窗口 = 200px × scale，以右下角为锚点缩放并钳制在屏幕工作区内）。

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
npm test          # 两个用例文件依次跑：
                  #   tests/update-heartbeat.test.js —— 版本比较、平台选包、真实签名验签、心跳上报体
                  #   tests/settings-panel.test.js  —— 间隔区间校验、持久化、改完重启计时、脏数据回落
```

界面本身用 Electron 的 `webContents.capturePage()` 截图验证（不依赖系统录屏权限）；想直接看面板可 `PET_TEST_SETTINGS=1 npm start`，启动 2.5 秒后自动弹出设置面板。

## 说明

- 资源（Sprites）从 `DesktopPetForMacApp` 拷贝而来，后续词库 / 题库接入方式相同。
- 服务端 `PetServer`（Go）跨平台，心跳 / 版本接口与 mac 版共用（Electron 发布字段见上文「跨平台发布字段」）。
- 设置面板目前只做了 mac 版「提醒设置」里的喝水提醒；天气提醒（付费解锁）、主动搭话尚未移植。
