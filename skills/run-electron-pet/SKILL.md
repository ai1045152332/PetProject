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

- **正常关闭**：直接关掉宠物窗口即退出（非 macOS 窗口全关即 `app.quit()`；macOS 目前也随主窗关闭而结束）。
- **前台常驻**：在跑 `npm start` 的终端按 `Ctrl + C` 结束。
- **残留进程强制清理**：`pkill -f "DesktopPetElectron"`（或先 `lsof`/`ps` 查到确切 PID 再 `kill`）。

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
- 小猫同步切到 **warn** 动画
- 点「知道啦」或右上角 × → 收起提醒卡 + 小猫回到 **focus**
- 提醒卡未关闭时，下一次到点不重复弹（`isShowing` 防叠加）

## 打包桌面 App（electron-builder）

已配 `electron-builder`，`package.json` 的 `build` 段声明了 appId / productName / mac+win target。产物输出到 `dist/`，图标资源在 `packaging/`（`icon.icns` + 1024² `icon.png`，Windows 的 `icon.ico` 由 electron-builder 据 png 自动生成）。

> ⚠️ 打包资源目录故意命名为 `packaging/` 而非默认的 `build/`：根 `.gitignore` 有全局 `build/` 规则（Xcode 用），会把图标一起忽略掉。

```bash
npm run dist:mac     # macOS：dist/*.dmg + *.zip（内含 DesktopPet.app）
npm run dist:win     # Windows：dist/*-setup.exe（NSIS）+ *.portable.exe
npm run dist         # 按当前系统自动打对应包
```

**macOS**：本机无开发者证书时加 `CSC_IDENTITY_AUTO_DISCOVERY=false` 跳过签名，否则构建中断。产物未签名，首次打开需在「隐私与安全性」点「仍要打开」或 `xattr -dr com.apple.quarantine DesktopPet.app`。

**Windows**：
- **推荐在 Windows 机器上** `npm run dist:win`，最稳妥。
- 在 macOS/Linux **交叉打** Windows 包：`nsis` 目标可能需要 **Wine**（`brew install --cask wine-stable`）；`portable` 目标一般无需 Wine 可直接产出。
- 只想快速验证 `--dir`：`CSC_IDENTITY_AUTO_DISCOVERY=false npx electron-builder --mac --dir`（只出解包 .app，不打 dmg，快）。

## 配置

- 提醒间隔：`drinkWaterInterval`（分钟，默认 30，范围 1~120）
- 持久化位置：Electron `userData/pet-config.json`
  - macOS：`~/Library/Application Support/desktop-pet-electron/pet-config.json`
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
│   └── config-store.js         # 极简 JSON 配置持久化（对标 UserDefaults）
├── src/renderer/
│   ├── index.html / pet.css / pet.js         # 宠物窗：帧循环 + focus↔warn 状态机
│   ├── preload.js              # petAPI（onDrinkWater / onDrinkWaterReset）
│   ├── reminder.html/.css/.js + reminder-preload.js   # 提醒卡 UI + close
└── assets/Sprites/             # 从 mac 工程拷贝的动画帧（focus/idel/warn/sleep/pet，各 8 帧 200×200）
```

## 常见排障

| 现象 | 处理 |
|------|------|
| `npm start` 后进程秒退 / 看不到小猫 | 是被父 shell 回收了，用 `npm start` 前台或持久后台终端运行 |
| 弹窗内容显示不全 | 提醒窗固定尺寸，内容超高会被裁；已调 380×300 + body 留 18px 阴影边距，改尺寸看 `reminder-window.js` |
| 透明窗出现白色方底 | body/html 背景必须 `transparent`；见 `pet.css`、`reminder.css` |
| 快捷键触发不了 | `globalShortcut` 可能与系统快捷键冲突，改用 `PET_TEST_REMINDER=1` 启动验证 |
| 首次安装卡在下载 | 设 `ELECTRON_MIRROR` 镜像后重跑 `npm install` |

## 与其他 skill / 工程的关系

- 素材来源与抠图规范 → `meijing-pet-prompts`
- macOS 原生版发版（与本 Electron 工程无关）→ `deploy-cute-pet`
- 服务端 `PetServer`（Go，跨平台无需改动）：Electron 版后续 P4 直接对接其接口

## 当前进度

已完成 **P0 悬浮窗 + 喝水提醒 + P6 electron-builder 打包（mac/win 已配）**。路线图（每阶段可独立验收）：
P1 完整动画状态机 → P2 拖拽/点击/托盘 → P3 右键菜单 → P4 新闻/天气/股票 → P5 Todo/背单词 → P6 `electron-builder` 打 Windows/macOS 安装包（✅）。
