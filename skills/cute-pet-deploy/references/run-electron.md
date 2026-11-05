# 运行与调试 Electron 版

> 本文件是 [../SKILL.md](../SKILL.md) 的运行篇：依赖安装、启动、设置面板、状态机、右键菜单、心跳/更新自测与排障。
> 要**打包给别人装**或**发版上线** → 看 [release.md](release.md) 的通道 C/D，不要照本文档手工发。

`DesktopPetElectron/` 是 macOS 原生版（`DesktopPetForMacApp`）的跨平台重写，目标是同时覆盖 Windows / macOS。本文只讲**这个 Electron 工程的依赖安装、启动、功能验收与调试**。

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
| 🐱 宠物信息 | 形象网格 5 格（focus/idel/sleep/pet 即时换帧 + hide 只读展示）、每格可上传自定义图（存 userData）、宠物名称、宠物号 |
| ⚙️ 通用设置 | 开机自启、宠物大小 0.5x～2.0x、版本 + 检查更新、权限校验码解锁（天气等按量付费能力需解锁） |
| 🔔 提醒设置 | 喝水提醒 + 每日天气提醒（需解锁，含时间/城市/预览）可用；主动搭话（本期不做） |
| 🖱️ 菜单设置 | 右键菜单已有抚摸/新闻/天气/Todo/躲起来/设置/关闭（同 Swift 版；显隐/检查更新只在托盘，Windows 走 trayFallback 补），展示配置过滤本期不做 |
| 👫 好友消息 | 宠物号展示；好友/消息（本期不做） |

喝水提醒：预设 15/30/45/60 点击立即生效；自定义 1～120 整数，越界/非整数红字提示且不写入；改完立刻重启计时，日志形如 `[settings] drinkWaterInterval -> {"ok":true,"minutes":45}` 紧跟 `[reminder] start: interval=45min, first fire in 195s`。

### 配色对齐 mac 版（浅色毛玻璃）

面板样式在 `settings.css`，颜色全部走 `:root` 的 CSS 变量，与 `SettingsPanel.swift` 一一对应：

| 元素 | mac 版来源 | Electron 侧 |
|------|-----------|-------------|
| 底板 | `NSVisualEffectView(material: .popover)` | 窗口 `vibrancy: 'popover'`（`settings-window.js`）+ `html.macos .panel` 透明透出系统模糊层；非 macOS 用半透明白 + `backdrop-filter` 近似 |
| 导航/内容容器 | `controlBackgroundColor` | `--control-bg` |
| 卡片 | `makeSettingRow` 的 `white 0.04` | `rgba(0,0,0,.04)` |
| 选中态 | `controlAccentColor` 0.18（导航）/ 0.14 + 2px 描边（状态格） | `--accent-18` / `--accent-14` |
| 开关 | `ToggleSwitch`：开 `systemGreen`、关 `systemGray` | `--switch-on` / `--switch-off` |
| 文字分层 | `label/secondaryLabel/tertiaryLabelColor` | `--label` / `--label-secondary` / `--label-tertiary` |

强调色与深浅外观由 `settings-preload.js` 用 `systemPreferences.isDarkMode() / getAccentColor()` 读出来，`settings.js` 的 `applySystemTheme()` 挂到 `<html>`（`.macos` / `.dark` + 覆盖 `--accent*`），所以**不要在样式里再写死颜色**，一律加变量。深色外观样式集中在 `html.dark` 段。

验证 UI 不用手动点：`PET_TEST_SETTINGS_SHOT=/tmp/a.png npx electron .` 会打开面板、`capturePage` 落盘后自退；加 `PET_TEST_SETTINGS_SECTION=general|reminder|menu|social` 截指定分区，加 `PET_TEST_SETTINGS_DARK=1` 预置 `.dark` 验证深色分支，加 `PET_TEST_SETTINGS_CLICK_STATE=hide` 预先点某一格形象（验证躲藏格只选中不切换）。⚠️ 该截图只含网页像素，**不含系统 vibrancy 层**，要确认毛玻璃效果得用 `screencapture -x -l <windowID>` 截真实窗口（窗口 ID 用 `CGWindowListCopyWindowInfo` 查）。

其他动作的日志：`[settings] petState -> sleep` / `[settings] petName -> 汤圆` / `[settings] petScale -> {"ok":true,"scale":1.5}` / `[settings] autoLaunch -> true`。

排查：
- 面板改不动 / 没反应 → 看日志有没有 `[settings]` 行；IPC 校验失败会返回 `{ok:false,error,...}`，间隔合法区间 1～120 整数、名称 ≤20 字符、大小 0.5～2.0。
- 重启后间隔被打回 30 → `pet-config.json` 的 `drinkWaterInterval` 是脏数据（0 / 非数字），读取时会回落到默认值。
- 只想看面板不想到点等 30 分钟：`PET_TEST_SETTINGS=1 npm start`，2.5 秒后自动弹出。
- 宠物放大后跑到屏幕外 → 缩放以右下角为锚点并钳制在当前显示器工作区内，正常不会出界；若手工改了 `petScale` 超过 2.0，读取时会截到 2.0。

快速回归：`npm test` 里的 `tests/settings-panel.test.js` 覆盖五项导航的基础数据、间隔区间校验、持久化、改完重启计时、名称/大小校验与窗口尺寸换算、形象列表（含 hide 只读格）与脏数据回落。

## 宠物专注跟随与贴边躲藏（P1 状态机首批能力）

**专注跟随**（`src/main/focus-mode-monitor.js`，对标 mac 版 `FocusModeMonitor.swift`）：只读检测系统勿扰/专注，开勿扰→宠物走 focus，关掉→idel，绝不写系统状态。

- macOS：读 `~/Library/DoNotDisturb/DB/Assertions.json`，`data[].storeAssertionRecords` 非空即视为开启；目录监听 + 1s 兜底轮询。本机从没用过勿扰时该目录可能不存在，读不到一律判为未开启（预期）。
- Windows：`reg query HKCU\...\ContentDeliveryManager` 读 `Windows.System.FocusAssistAppStateEnabled` / `QuietHours`；Win11 已把状态挪进 CloudStore 加密 blob，读不到就判未开启（宠物保持休闲），不影响其它功能。
- 只施加在 focus/idel 两态上：睡觉 / 抚摸 / 躲藏中不会被专注跟随打断。
- 验证：`PET_TEST_FOCUS=1 npm start`（2s 强制切专注、5s 切回休闲，不依赖真开勿扰），日志 `[focus-mode] 系统勿扰/专注状态变化 → 已开启(专注)` + `[settings] petState -> focus`。

**贴边躲藏**（`src/main/edge-snap.js` 纯几何 + `index.js` 接线，对标 mac 版 `snapToEdgeForHiding` / `revealFromEdge`）：

- 拖到屏幕**左/右**侧边 60px 内松手 → 窗口整边对齐显示器 workArea 边缘并进入 `hide`（素材只画一侧探头，所以不支持上/下边）。日志 `[pet] 贴边躲藏: edge=right, 边距=30px, 吸附到 x,y`。
- 渲染层配合：`pet.css` 的 `#cat.hide-left/hide-right` 把画面钉在同一条边（贴右再镜像 `scaleX(-1)`），让素材裁切边正好落在屏幕边上。
- 解除：**拖回屏内**（拖动中即视为现身）或**单击探头猫**→ 窗口先完整收回屏内（留 4px）再回躲藏前状态；托盘/右键「显示宠物」、喝水与 Todo 到期提醒也会先现身。
- 右键菜单新增「躲起来 👀」（在 Todo 之后）：不看当前距离，直接吸到最近一侧。
- 躲藏中改宠物大小：`applyPetScale` 识别出「已整边贴边」并按新尺寸重新吸附，返回吸附结果后主进程再推一次 `{state, facing}`（对齐 mac 版 `resizeWindow` 的重新吸附）。
- 状态机 IPC 契约变更：`pet:state` 现在传 `{ state, facing }`（不是裸字符串），渲染层只执行不自行推状态；`hide` 必须等主进程确认已吸附才显示。渲染层不认识的状态（帧清单里没有）直接忽略。
- 设置面板「形象」区：`panelPetStates()` 返回五格（四态 `switchable:true` + hide `switchable:false`），躲藏格虚线框、能预览也能上传/恢复默认 `local-hide.png`，但点它不切换（主进程 `isSwitchablePetState` 也会拒，防止没吸附就切过去把半个身子留在屏外）。格子上两个圆点含义不同：左上绿点 = 此刻正在播，右上蓝点 = 已上传自定义图；选中框只表示上传/恢复默认针对哪一格。
- 面板开着时主进程会推 `settings:pet-state`，所以拖到边上躲起来、专注跟随、右键抚摸都会实时把「当前状态」刷成躲藏中（面板下次打开会自己走 `settings:load` 拉最新值）。
- 验证：`PET_TEST_HIDE=1 npm start` 2s 后模拟「贴右边缘 30px 松手」；再加 `PET_TEST_REVEAL=1` 会在 6s 注入一次原地点点击验证现身。`PET_TEST_HIDE=1 PET_TEST_SETTINGS_SHOT=/tmp/s.png` 可同时看面板的「躲藏中」与绿点位置。截图看探头效果用 `screencapture -x -R<x>,<y>,<w>,<h> /tmp/hide.png`（坐标取日志里的 bounds）。
- 快速回归：`npm test` 里的 `tests/focus-edge.test.js`（勿扰断言/注册表解析、只在状态变化时回调、吸附与现身几何、躲藏中缩放重新吸附）。

## 宠物右键菜单（P3）

右键小猫弹原生菜单，分**三栏**：其他功能（**抚摸 🐾（切 pet 帧，一次性动画）/ 今日热点新闻 📰 / 查看天气 ☀️ / Todo 清单 📝 / 躲起来 👀（贴屏幕侧边探头）**）｜**设置…**｜**关闭 ❌**，代码在 `src/main/pet-context-menu.js`。同 Swift 版，右键宠物可直接进设置；显隐、检查更新只在菜单栏托盘（Windows 走 trayFallback 兜底补上）。未传 `hide` 回调时菜单里不会出现「躲起来」。

- 触发链路：渲染层 `pet.js` 监听 `contextmenu` → IPC `pet:context-menu` → 主进程弹原生菜单。**不能再用 `-webkit-app-region: drag`**——drag 区会在原生层吞掉真实鼠标事件（含右键），页面收不到任何事件；拖拽改为主进程手动搬窗（`createDragController` + `pet:drag-start/move/end`）。⚠️ `webContents.sendInputEvent` 注入的模拟事件会绕过 drag 区直达渲染层，用它验证右键会得到**假阳性**，必须用真实鼠标（CGEvent）确认。
- 日志：`[context-menu] 右键宠物窗，弹原生菜单`；抚摸是一次性动画（一圈 + hold 1.5s 自动回弹，对标 Swift playOneShot），日志形如 `[settings] petState -> pet` 紧跟 `[settings] petState -> focus`。
- 测试钩子：`PET_TEST_CONTEXT_MENU=1 npm start` 2.5s 自动弹菜单验证。拖窗单测：`tests/pet-drag.test.js`。
- 喂猫条、背单词、股票等仍依赖 P4/P5，尚未移植。

## 验证心跳与自动更新

心跳默认启动即报一次、之后每 60s 一次，日志为 `[heartbeat] 已启动，间隔 60s → http://…/api/heartbeat`；首报成功打 `[heartbeat] 上报成功（累计 1 次）`（之后每次成功静默，「失败→恢复」再记一条），宠物号首次分配时额外打 `[heartbeat] 宠物号已分配: #N`。断网时同一条失败原因只记一次。

想看每次收发细节：`HEARTBEAT_DEBUG=1 npm start`，会打出 `[heartbeat] → POST v=electron0.0.1 device=… state=…` 与 `[heartbeat] ← 200 137ms`。

不想看日志也行：设置面板「通用设置 → 心跳上报」直接显示 `正常 / 失败` 和「最近一次 N 秒前」，面板开着时每 5s 刷新。

检查更新正常是「启动 30s 后首检 + 每 24h 一次」，测试用：

```bash
PET_TEST_UPDATE=1 npm start      # 启动 3 秒后立即走一遍检查更新（跳过 30s 等待）
```

也可点菜单栏托盘 →「检查更新（当前 electron0.0.1）」手动触发（无更新/失败都会弹提示，自动检查则静默）。

判定要点（字段契约见 [release.md](release.md) §manifest 契约）：
- 提示「服务端还没有发布 XX 版安装包」= `latest.json` 缺该平台的 `win*` / `mac*` 字段，**属预期**，不是客户端 bug。
- 客户端自身版本形如 `electron0.0.1`，只认带 `electron` 前缀的同平台字段；**不会**拿 mac 原生版的 `version/file` 更新自己。
- 下载走 `GET /download/<文件名>`，落盘在 `userData/updates/`，先比 sha256 再验 Ed25519 签名，任一不过就删包并提示失败。

快速回归（不启 GUI）：`npm test`（update-heartbeat 32 项 + settings-panel 若干项，均 mock 掉 electron）。

## 本地打包（不是发布）

想要一个能双击安装的包（dmg）就用通道 E，它会清旧 mac 产物、物化图标、跑 `electron-builder --mac`：

```bash
./skills/cute-pet-deploy/scripts/build-mac-electron-local.sh          # → dist/DesktopPet-<版本>-<arch>.dmg
./skills/cute-pet-deploy/scripts/build-mac-electron-local.sh --open   # 打完顺便挂载
```

只想确认「能打出包」、几十秒看结果，可以退一步用 `--dir`（只出解包 `.app`，不打 dmg）：

```bash
CSC_IDENTITY_AUTO_DISCOVERY=false npx electron-builder --mac --dir
```

- 产物在 `dist/mac-arm64/DesktopPet.app`（约 237 MB），本机未配证书时是 ad-hoc 签名（`codesign -dv` 显示 `Identifier=Electron`），首次打开需右键「打开」或 `xattr -dr com.apple.quarantine`。
- `packaging/` 是打包图标目录，**故意不叫 `build/`**：根 `.gitignore` 有全局 `build/` 规则（Xcode 用），会把图标一起忽略。
- **坑**：`packaging/icon.icns` 是软链（指向 `SharedAssets/AppIcon.icns`），直接 `npm run dist:mac` 会在 dmg 阶段报 `xattr.Set … .VolumeIcon.icns … no such file or directory`。通道 E 的脚本用 `cp -L` 物化图标绕开；手工打包时记得带 `-c.dmg.icon=<真实 icns 路径>`。

> 要发线上走 [release.md](release.md)：通道 B（Swift 原生，mac 自动更新）、D（Windows）。不要手工 `npm run dist:*` 后自行上传，manifest 覆盖会挤掉别的通道。

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
│   ├── pet-window.js           # 透明置顶悬浮窗（200×200）+ 躲藏中缩放重新吸附
│   ├── focus-mode-monitor.js   # 系统勿扰/专注只读检测（mac 断言文件 / Windows 注册表）+ 轮询监听
│   ├── edge-snap.js            # 贴边躲藏纯几何：吸附落点 / 现身收拢
│   ├── reminder-window.js      # 喝水提醒独立弹窗（380×300 居中）
│   ├── reminder-scheduler.js   # 提醒调度：对齐触发点 + 间隔重复 + 防叠加
│   ├── tray.js                 # 菜单栏托盘：显示/隐藏 + 设置 + 检查更新 + 退出
│   ├── pet-context-menu.js     # 宠物右键菜单（抚摸/设置/关闭）
│   ├── settings-window.js      # 设置面板窗口（无边框透明 + macOS vibrancy 毛玻璃，单例）
│   ├── settings-service.js     # 设置业务逻辑：读间隔 / 校验写入 / 重启计时
│   ├── heartbeat.js            # 心跳上报（1 分钟一次，移植 mac 版 HeartbeatService）
│   ├── update-service.js       # 自动更新：检查/下载/sha256+Ed25519 校验/按平台安装
│   ├── app-info.js             # 版本号、设备 ID（IOPlatformUUID / MachineGuid）、宠物名
│   └── config-store.js         # 极简 JSON 配置持久化（对标 UserDefaults）
├── src/renderer/
│   ├── index.html / pet.css / pet.js         # 宠物窗：帧循环 + 躲藏锚边/镜像（提醒触发时从头播放）
│   ├── preload.js              # petAPI（onDrinkWater）
│   ├── reminder.html/.css/.js + reminder-preload.js   # 提醒卡 UI + close
│   ├── settings.html/.css/.js  + settings-preload.js  # 设置面板（配色对齐 mac 版，见「设置面板」节）
└── assets/
    ├── Sprites/                # 软链 → SharedAssets/Sprites（与 mac 原生版共用同一批帧，focus/sleep 8 帧、idel/pet 24 帧、hide 1 帧，均 200×200）
    ├── MenuBarIcon.png         # 软链 → 仓库根 SharedAssets/MenuBarIcon.png（与 mac 原生版共用同一张图）
    └── WindowsTray(@2x).png    # 也是软链 → SharedAssets/WindowsTray(@2x).png：Windows 专用白猫+深灰描边（32/64，4x 超采样从同源图导出，不留脚本）
```

> 两个工程**共用的素材只存一份**，全在仓库根 `SharedAssets/`：`MenuBarIcon.png`、`WindowsTray.png`、`WindowsTray@2x.png`、`AppIcon.icns`、`Sprites/`，
> 各工程引用位置都是软链（`DesktopPetElectron/packaging/icon.icns` → `SharedAssets/AppIcon.icns`，曾是 1.5MB 逐字节重复副本）。
> 新增共用素材一律丢 `SharedAssets/` 再在两边建软链，不要在工程里放副本。软链对 `cp`、electron-builder（含**目录级**软链，65 帧已实测进 asar）、SPM 打包都透明。
> **帧数绝不在代码里写死**：`src/main/sprite-frames.js` 按目录枚举（对标 Swift `SpriteSheet.loadFramesFromDirectory`），主进程走 `pet:frame-counts` 下发给 `pet.js`。
> 教训：素材统一到 mac 版后 idel/pet 从 8 帧变 24 帧，旧代码写死 `FRAME_COUNTS = 8` 会只播前三分之一、循环在中间卡断，「抚摸」one-shot 的一圈时长也会提前 1 秒多回弹。
> 例外：只有一边用到的（`SpeechBubble.png`、`WordBank/`、`ProblemBank/`）留在 mac 工程内。

## 常见排障

| 现象 | 处理 |
|------|------|
| `npm start` 后进程秒退 / 看不到小猫 | 是被父 shell 回收了，用 `npm start` 前台或持久后台终端运行 |
| 弹窗内容显示不全 | 提醒窗固定尺寸，内容超高会被裁；已调 380×300 + body 留 18px 阴影边距，改尺寸看 `reminder-window.js` |
| 透明窗出现白色方底 | body/html 背景必须 `transparent`；见 `pet.css`、`reminder.css` |
| 快捷键触发不了 | `globalShortcut` 可能与系统快捷键冲突，改用 `PET_TEST_REMINDER=1` 启动验证 |
| 看不到小猫但进程在跑 / 无法退出 | 悬浮窗 `skipTaskbar` 无 Dock 图标，看顶部菜单栏托盘图标→退出；无托盘则 `ps` 查 PID 后精确 `kill`（别 `pkill` 按名杀，易漏外层 npm 包装进程） |
| 菜单栏看不到图标 / 巨图 | `tray.js` 里 `nativeImage.createFromPath(...).resize({width, height})` 必须**接住返回值**：`resize()` 返回新图、不改原对象，丢返回值等于把 360×348 原图交给 Tray，会被当成 360pt 巨图直接不显示。**不要**再加派生脚本或自绘剪影 |
| 菜单栏图标与 mac 原生版长得不一样 | mac 侧两边已是同一张图（`SharedAssets/MenuBarIcon.png`，两工程软链），差异只可能来自尺寸以外的加工（剪影/描边/裁脸）。mac 侧只依赖 `resize` + `setTemplateImage(true)`，Swift 侧只依赖 `img.size = 22×22` + `isTemplate = true`，保持两边都不做像素加工 |
| 顶栏指标显示成「CPU 58% 内存 82%」文字，而 mac 原生版是图标 | `tray.setTitle()` 只收纯字符串，没有 Swift 的 `NSAttributedString` + SF Symbol attachment 能力，所以 `system-monitor.js` 的 `METRIC_ICONS` 用单色 Unicode 字形等价替代（▣ cpu / ▤ memorychip / ◉ internaldrive / ⇅ arrow.up.arrow.down）。换字形前先用 `CTFontCreateForString` 验证菜单栏字体能回退到该字形，否则上屏是豆腐块 |
| 顶栏/菜单里「网络 0K/0K」一直为零 | `netstat -ibn` 的列序是 `Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll`：第 2 列是 **Mtu**（所有接口都是 1500），拿它去重就只会统计到排在最前的零流量 `en*`；而 `cols[7]` 是 **Opkts（包数）**不是字节。正确做法见 `parseNetstatIb`：只取 `<Link#N>` 链路行、按接口名过滤 `en\d`、计数从**行尾**定位（无 Address 的行会整体左移一列） |
| 换了菜单栏图标但 Windows 没变 | Windows 用的是另一张静态图 `SharedAssets/WindowsTray.png`（+@2x，`assets/` 下是软链，仓库内不留生成脚本），改完 `SharedAssets/MenuBarIcon.png` 要手动重导这两张 |
| Windows 托盘图标描边断裂 / 猫成白面团 | 不要在小尺寸上直接跑形态学（腐蚀会把细胡须删成孤立碎块，回填又把五官抹平）。正确做法：先 4x 超采样，取原画像素作猫身（保留五官不填洞），描边用 `MaxFilter` 环带，两层各自高斯模糊后缩回目标尺寸 |
| `npm run dist:mac` 报 `xattr.Set … .VolumeIcon.icns … no such file or directory` | `packaging/icon.icns` 是软链，electron-builder 写 dmg 卷图标时不跟随。用 `./skills/cute-pet-deploy/scripts/build-mac-electron-local.sh`（内部 `cp -L` 物化后 `-c.dmg.icon=` 传入），别直接 `npm run dist:mac` |
| 首次安装卡在下载 | 设 `ELECTRON_MIRROR` 镜像后重跑 `npm install` |
| 托盘「检查更新」提示「服务端还没有发布 Windows 版安装包」 | 服务端 `dist/latest.json` 缺 `win*` 字段（或 PetServer 未部署支持平台字段的新版），属预期提示 |
| 更新一直反复提示同一版本 | `winVersion`/`macVersion` 与包内 `package.json` 的 `version` 不一致（注意带 `electron` 前缀），改到一致再发 |
| 设置面板底板发灰 / 看不到毛玻璃 | macOS 上窗口已开 `vibrancy`，`html.macos:not(.dark) .panel` 必须保持 `background: transparent`，再叠一层半透明白就会发灰；`capturePage` 截不到系统模糊层，别拿它判断毛玻璃好坏 |
| 想确认心跳是否真的上报成功 | 先看设置面板「通用设置 → 心跳上报」；或 `curl -s http://101.96.248.75/api/devices` 找自己的 `deviceId` 看 `version`。注意同一台机器上 mac 原生版与 Electron 版共用 deviceId，记录会被交替覆盖（看到 `v1.0.031` 是原生版刚报的）。本地起 PetServer 则看 `data/heartbeats.jsonl` |

## 与其他文档 / 工程的关系

- 素材来源与抠图规范 → `../../meijing-pet-prompts/SKILL.md`
- 发布（本地/远程 × Swift/Electron）与服务端部署 → [../SKILL.md](../SKILL.md) 与 [release.md](release.md)
- 服务端 `PetServer`（Go，跨平台）：心跳 `/api/heartbeat`、版本 `/api/app/latest` 与 mac 版共用；Electron 发布用 `win*` / `mac*` 平台字段（需部署支持这些字段的新版服务端）

## 当前进度

已完成 **P0 悬浮窗 + 喝水提醒 + 菜单栏托盘退出 + 心跳上报 + 自动更新/检查更新 + P3 基础右键菜单 + P6 electron-builder 打包（mac/win 已配）**，P1 状态机已上线**专注跟随**与**贴边躲藏**两个能力。路线图（每阶段可独立验收）：
P1 完整动画状态机（专注跟随 ✅ / 贴边躲藏 ✅，空闲自动睡觉、主动搭话待补）→ P2 拖拽/点击/托盘（托盘✅）→ P3 右键菜单（✅）→ P4 新闻/天气/股票 → P5 Todo/背单词 → P6 `electron-builder` 打 Windows/macOS 安装包（✅）。
