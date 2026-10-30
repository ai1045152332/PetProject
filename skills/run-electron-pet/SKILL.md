---
name: run-electron-pet
description: 安装并启动跨平台桌面宠物 Electron 版（DesktopPetElectron），当前含 P0 透明置顶悬浮小猫 + 喝水提醒弹窗。当用户说「跑起来/启动/运行 Electron 宠物」「安装 electron pet」「测试喝水提醒/提醒弹窗」时使用。仅涉及 Electron 工程，不影响 macOS 原生版。
metadata:
  short-description: Install & run the Electron desktop pet
---

# 安装启动 Electron 桌面宠物

`DesktopPetElectron/` 是 macOS 原生版（`DesktopPetForMacApp`）的跨平台重写，目标是同时覆盖 Windows / macOS。本 skill 只管**这个 Electron 工程的依赖安装、启动与提醒功能验证**。

## 环境要求

| 项目 | 要求 |
|------|------|
| Node.js | 18+（本机 v22 已验证） |
| npm | 随 Node 安装 |
| 网络 | 首次 `npm install` 需下载 Electron 二进制（约 100MB，耗时 1 分钟左右） |

## 安装依赖

```bash
cd DesktopPetElectron
npm install          # 装 electron（devDependency），首次较慢
```

> Electron 二进制从 GitHub Releases 下载，国内网络慢/失败时可设镜像：
> `ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/ npm install`

## 启动

```bash
npm start            # 等价于 electron .
```

启动后桌面右下角出现一只透明背景、始终置顶、可拖动的小猫（focus 帧循环）。

**关键：不要用一次性前台/`&` 后台方式拉起。** 主进程 GUI 进程会随父 shell 退出被回收。要么用 `npm start` 前台常驻，要么放进持久后台终端运行。

## 停止 / 关闭

悬浮小猫是 `skipTaskbar: true` 的无边框透明窗，**Dock 里没有图标**，靠菜单栏托盘退出：

- **推荐**：点顶部菜单栏的托盘图标 →「退出」（左键单击图标 = 显示/隐藏宠物，右键 = 弹菜单）；见 `src/main/tray.js`。
- 托盘菜单里还有「设置…」（mac 也有应用菜单 `Cmd+,`），打开喝水提醒设置面板。
- **前台常驻**：在跑 `npm start` 的终端按 `Ctrl + C`。
- **残留进程强制清理**：按名 `pkill` 不可靠，先查 PID 再精确 kill——
  `ps aux | grep -iE "DesktopPetElectron|cute pet.app" | grep -v grep` 找到主进程 PID（连外层 `node …/.bin/electron` 包装进程一起），再 `kill <pid>`；仍不退才 `kill -9`。

## 验证喝水提醒

正常按间隔（默认 30 分钟）到点才弹，测试用两种方式之一：

```bash
# 方式一：启动 2 秒后自动弹一次提醒（推荐，端到端验证）
PET_TEST_REMINDER=1 npm start

# 方式二：应用运行中按全局快捷键，立即弹一次
#   Ctrl+Alt+W（macOS 为 Cmd+Alt+W）
```

触发后的完整链路：
- 屏幕居中弹出提醒卡「该喝水啦！/ 起来倒杯水…」
- 小猫专注动画从第 0 帧重新播放唤起注意（提醒已合并进专注，不再有独立 warn 动画）
- 点「知道啦」或右上角 × → 收起提醒卡（专注动画自身持续循环，无需切换）
- 提醒卡未关闭时，下一次到点不重复弹（`isShowing` 防叠加）

## 设置面板

入口：托盘 →「设置…」；macOS 还可用应用菜单 `Cmd+,`。窗口 720×500，**左侧五项一级菜单**（对齐 mac 版 SettingsPanel），右侧内容区独立滚动：

| 一级菜单 | 本版状态 |
|----------|----------|
| 🐱 宠物信息 | 形象切换（focus/idel/sleep/pet 即时换帧）、宠物名称、宠物号；自定义图片（本期不做） |
| ⚙️ 通用设置 | 开机自启、宠物大小 0.5x～2.0x、版本 + 检查更新；权限校验码（本期不做） |
| 🔔 提醒设置 | 喝水提醒可用；天气提醒、主动搭话（本期不做） |
| 🖱️ 菜单设置 | 右键菜单（本期不做，宠物窗还没有右键菜单） |
| 👫 好友消息 | 宠物号展示；好友/消息（本期不做） |

喝水提醒：预设 15/30/45/60 点击立即生效；自定义 1～120 整数，越界/非整数红字提示且不写入；改完立刻重启计时，日志形如 `[settings] drinkWaterInterval -> {"ok":true,"minutes":45}` 紧跟 `[reminder] start: interval=45min, first fire in 195s`。

其他动作的日志：`[settings] petState -> sleep` / `[settings] petName -> 汤圆` / `[settings] petScale -> {"ok":true,"scale":1.5}` / `[settings] autoLaunch -> true`。

排查：
- 面板改不动 / 没反应 → 看日志有没有 `[settings]` 行；IPC 校验失败会返回 `{ok:false,error,...}`，间隔合法区间 1～120 整数、名称 ≤20 字符、大小 0.5～2.0。
- 重启后间隔被打回 30 → `pet-config.json` 的 `drinkWaterInterval` 是脏数据（0 / 非数字），读取时会回落到默认值。
- 只想看面板不想到点等 30 分钟：`PET_TEST_SETTINGS=1 npm start`，2.5 秒后自动弹出。
- 宠物放大后跑到屏幕外 → 缩放以右下角为锚点并钳制在当前显示器工作区内，正常不会出界；若手工改了 `petScale` 超过 2.0，读取时会截到 2.0。

快速回归：`npm test` 里的 `tests/settings-panel.test.js` 覆盖五项导航的基础数据、间隔区间校验、持久化、改完重启计时、名称/大小校验与窗口尺寸换算、脏数据回落。

## 验证心跳与自动更新

心跳默认启动即报一次、之后每 60s 一次，日志为 `[heartbeat] 已启动，间隔 60s → http://…/api/heartbeat`；首报成功打 `[heartbeat] 上报成功（累计 1 次）`（之后每次成功静默，「失败→恢复」再记一条），宠物号首次分配时额外打 `[heartbeat] 宠物号已分配: #N`。断网时同一条失败原因只记一次。

想看每次收发细节：`HEARTBEAT_DEBUG=1 npm start`，会打出 `[heartbeat] → POST v=electron0.0.1 device=… state=…` 与 `[heartbeat] ← 200 137ms`。

不想看日志也行：设置面板「通用设置 → 心跳上报」直接显示 `正常 / 失败` 和「最近一次 N 秒前」，面板开着时每 5s 刷新。

检查更新正常是「启动 30s 后首检 + 每 24h 一次」，测试用：

```bash
PET_TEST_UPDATE=1 npm start      # 启动 3 秒后立即走一遍检查更新（跳过 30s 等待）
```

也可点菜单栏托盘 →「检查更新（当前 electron0.0.1）」手动触发（无更新/失败都会弹提示，自动检查则静默）。

判定要点：
- 服务端 `latest.json` 里没有 `winVersion/winFile/winSHA256/winSignature`（Windows）或 `macVersion/...`（macOS）时，提示「服务端还没有发布 XX 版安装包」——**这是预期行为**，说明平台字段没配或服务端不是新版。
- 客户端只认平台前缀字段，**不会**拿 mac 原生版的 `version/file` 更新自己；版本比较用本机 `package.json` 的 `version`。
- 客户端自身版本形如 `electron0.0.1`（`electron` 前缀专用于区分 mac 原生版的 `v1.0.031`）；`winVersion`/`macVersion` 必须写成同样的 `electron` 形式，比较时会自动剥前缀。
- 下载走 `GET /download/<文件名>`，落盘在 `userData/updates/`，先比 sha256 再验 Ed25519 签名，任一不过就删包并提示失败。

快速回归（不启 GUI）：`npm test`（update-heartbeat 32 项 + settings-panel 若干项，均 mock 掉 electron）。

## 打包桌面 App（electron-builder）

已配 `electron-builder`，`package.json` 的 `build` 段声明了 appId / productName / mac+win target。产物输出到 `dist/`，图标资源在 `packaging/`（`icon.icns` + 1024² `icon.png`，Windows 的 `icon.ico` 由 electron-builder 据 png 自动生成）。

> ⚠️ 打包资源目录故意命名为 `packaging/` 而非默认的 `build/`：根 `.gitignore` 有全局 `build/` 规则（Xcode 用），会把图标一起忽略掉。

```bash
npm run dist:mac     # macOS：dist/*.dmg + *.zip（内含 DesktopPet.app）
npm run dist:win     # Windows：dist/*-setup.exe（NSIS）+ *.portable.exe
npm run dist         # 按当前系统自动打对应包
```

实测产物（arm64，version 0.0.1）：`dist/DesktopPet-0.0.1-arm64.dmg`、`dist/DesktopPet-0.0.1-arm64-mac.zip`、解包 bundle 在 `dist/mac-arm64/DesktopPet.app`。本机未配证书时为 ad-hoc 签名（`codesign -dv` 显示 `Identifier=Electron`），故需下面的去隔离处理。

**macOS**：本机无开发者证书时加 `CSC_IDENTITY_AUTO_DISCOVERY=false` 跳过签名，否则构建中断。产物未签名，首次打开需在「隐私与安全性」点「仍要打开」或 `xattr -dr com.apple.quarantine DesktopPet.app`。

**Windows**：
- **推荐在 Windows 机器上** `npm run dist:win`，最稳妥。
- 在 macOS/Linux **交叉打** Windows 包：`nsis` 目标可能需要 **Wine**（`brew install --cask wine-stable`）；`portable` 目标一般无需 Wine 可直接产出。
- 只想快速验证 `--dir`：`CSC_IDENTITY_AUTO_DISCOVERY=false npx electron-builder --mac --dir`（只出解包 .app，不打 dmg，快）。

## 配置

- 提醒间隔：`drinkWaterInterval`（分钟，默认 30，范围 1~120）
- 服务端地址：`serverBaseURL`（默认 `http://101.96.248.75`，心跳与更新共用）
- 心跳相关：`petName`（默认「毛豆」）、`deviceId`（首次启动自动解析，mac 取 `IOPlatformUUID`、Windows 取注册表 `MachineGuid`）、`petNo`（服务端回填）、`lastUpdateCheckAt`
- 持久化位置：Electron `userData/pet-config.json`
  - macOS：`~/Library/Application Support/desktop-pet-electron/pet-config.json`
  - 测试可用 `--user-data-dir=/tmp/xxx` 换隔离配置，不污染本机配置
  - 直接改该文件后重启生效（暂无设置 UI，待 P3 右键菜单补上）

## 项目结构（速查）

```
DesktopPetElectron/
├── package.json                # main: src/main/index.js；scripts.start = electron .；build 段 = electron-builder 配置
├── packaging/                  # 打包图标资源（icon.icns / icon.png）
├── dist/                       # electron-builder 产物（.app/.dmg/.zip/exe，不入库）
├── src/main/
│   ├── index.js                # 入口 + 生命周期 + IPC + 调度器装配 + 测试快捷键
│   ├── pet-window.js           # 透明置顶悬浮窗（200×200）
│   ├── reminder-window.js      # 喝水提醒独立弹窗（380×300 居中）
│   ├── reminder-scheduler.js   # 提醒调度：对齐触发点 + 间隔重复 + 防叠加
│   ├── tray.js                 # 菜单栏托盘：显示/隐藏 + 设置 + 检查更新 + 退出
│   ├── settings-window.js      # 设置面板窗口（无边框透明，单例）
│   ├── settings-service.js     # 设置业务逻辑：读间隔 / 校验写入 / 重启计时
│   ├── heartbeat.js            # 心跳上报（1 分钟一次，移植 mac 版 HeartbeatService）
│   ├── update-service.js       # 自动更新：检查/下载/sha256+Ed25519 校验/按平台安装
│   ├── app-info.js             # 版本号、设备 ID（IOPlatformUUID / MachineGuid）、宠物名
│   └── config-store.js         # 极简 JSON 配置持久化（对标 UserDefaults）
├── src/renderer/
│   ├── index.html / pet.css / pet.js         # 宠物窗：focus 帧循环（提醒触发时从头播放）
│   ├── preload.js              # petAPI（onDrinkWater）
│   ├── reminder.html/.css/.js + reminder-preload.js   # 提醒卡 UI + close
└── assets/
    ├── Sprites/                # 从 mac 工程拷贝的动画帧（focus/idel/sleep/pet，各 8 帧 200×200；warn 已合并进 focus 删除）
    └── tray/                   # MenuBarTemplate(@2x).png = mac 单色模版图；WindowsTray(@2x).png = Windows 白猫图（均由 MenuBarIcon.png 派生）
```

## 常见排障

| 现象 | 处理 |
|------|------|
| `npm start` 后进程秒退 / 看不到小猫 | 是被父 shell 回收了，用 `npm start` 前台或持久后台终端运行 |
| 弹窗内容显示不全 | 提醒窗固定尺寸，内容超高会被裁；已调 380×300 + body 留 18px 阴影边距，改尺寸看 `reminder-window.js` |
| 透明窗出现白色方底 | body/html 背景必须 `transparent`；见 `pet.css`、`reminder.css` |
| 快捷键触发不了 | `globalShortcut` 可能与系统快捷键冲突，改用 `PET_TEST_REMINDER=1` 启动验证 |
| 看不到小猫但进程在跑 / 无法退出 | 悬浮窗 `skipTaskbar` 无 Dock 图标，看顶部菜单栏托盘图标→退出；无托盘则 `ps` 查 PID 后精确 `kill`（别 `pkill` 按名杀，易漏外层 npm 包装进程） |
| 菜单栏图标模糊 / 像一坨白块 | 图标由 `assets/MenuBarIcon.png`（与 mac 原生版同一张图）派生，不要自绘也不要直接塞原图：原图 360×348 不透明，直塞会被当成 360pt 巨图、当模版图会变成实心方块，跑 `python3 scripts/make-tray-icons.py` 重新生成 22/44 单色模版图（`--full` 可换成整只猫） |
| 首次安装卡在下载 | 设 `ELECTRON_MIRROR` 镜像后重跑 `npm install` |
| 托盘「检查更新」提示「服务端还没有发布 Windows 版安装包」 | 服务端 `dist/latest.json` 缺 `win*` 字段（或 PetServer 未部署支持平台字段的新版），属预期提示 |
| 更新一直反复提示同一版本 | `winVersion`/`macVersion` 与包内 `package.json` 的 `version` 不一致（注意带 `electron` 前缀），改到一致再发 |
| 想确认心跳是否真的上报成功 | 先看设置面板「通用设置 → 心跳上报」；或 `curl -s http://101.96.248.75/api/devices` 找自己的 `deviceId` 看 `version`。注意同一台机器上 mac 原生版与 Electron 版共用 deviceId，记录会被交替覆盖（看到 `v1.0.031` 是原生版刚报的）。本地起 PetServer 则看 `data/heartbeats.jsonl` |

## 与其他 skill / 工程的关系

- 素材来源与抠图规范 → `meijing-pet-prompts`
- macOS 原生版发版（与本 Electron 工程无关）→ `deploy-cute-pet`
- 服务端 `PetServer`（Go，跨平台）：心跳 `/api/heartbeat`、版本 `/api/app/latest` 与 mac 版共用；Electron 发布用 `win*` / `mac*` 平台字段（需部署支持这些字段的新版服务端，见该工程 README）

## 当前进度

已完成 **P0 悬浮窗 + 喝水提醒 + 菜单栏托盘退出 + 心跳上报 + 自动更新/检查更新 + P6 electron-builder 打包（mac/win 已配）**。路线图（每阶段可独立验收）：
P1 完整动画状态机 → P2 拖拽/点击/托盘（托盘✅）→ P3 右键菜单 → P4 新闻/天气/股票 → P5 Todo/背单词 → P6 `electron-builder` 打 Windows/macOS 安装包（✅）。
