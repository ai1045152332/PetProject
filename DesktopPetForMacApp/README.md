# DesktopPetForMacApp — macOS 桌面小猫

> 版本发布与客户端自动更新流程见 [`docs/自动更新与发布流程.md`](../docs/自动更新与发布流程.md)。

一款纯 Swift 开发的 macOS 桌面虚拟宠物。一只小猫悬浮在桌面最上层，支持精灵图动画、鼠标拖拽、右键菜单、菜单栏设置，以及喝水提醒、热点新闻、天气、股票、Todo 等实用小功能。

技术栈：SwiftUI（应用入口）+ 纯 AppKit（窗口 / 绘制 / 弹窗），Swift Package Manager 工程，无第三方依赖。

---

## 功能特性

- **桌面悬浮**：无边框透明浮动窗口，始终置顶，可跨桌面 / 全屏显示，可拖拽移动
- **精灵图动画**：5 种状态（专注 / 休闲 / 提醒 / 睡觉 / 抚摸），12 FPS 帧循环驱动
- **鼠标交互**：左键点击触发提醒动画、双击打开 Todo 清单、右键弹出功能菜单、拖拽移动小猫
- **菜单栏**：显示 / 隐藏小猫、设置面板、退出
- **设置面板**：卡片式 UI 一键切换小猫状态（专注 / 休闲 / 睡觉 / 抚摸），屏幕居中弹出
- **喝水提醒**：每整点 / 半点自动弹窗提醒，附带提醒动画
- **热点新闻**：今日头条热榜 Top10（百度热搜兜底），可点击跳转
- **天气查询**：和风天气 API，支持定位自动查询与手动输入城市，展示当前 / 逐小时 / 未来 7 天气温条
- **股票查询**：腾讯行情接口，支持沪 / 深 / 北 / 港代码，展示涨跌、今开昨收、量额等，带最近查询历史
- **Todo 清单**：本地持久化（UserDefaults），支持增删
- **本地日志**：运行时关键事件写入 `~/Desktop/DesktopPetForMacApp_log.txt`，便于排查问题

---

## 环境要求

| 项目 | 要求 |
|------|------|
| macOS | 13.0+（Ventura） |
| Swift | 5.9+ |
| Xcode | 15.0+（也可仅用 CommandLineTools + swiftc） |
| 网络 | 天气 / 新闻 / 股票功能需要联网 |

---

## 编译与打包

### 方式一：SPM 标准编译

```bash
cd DesktopPetForMacApp
swift build -c release --disable-sandbox
```

### 方式二：swiftc 直接编译（本机沙盒限制时使用）

某些环境 `swift build` 会被 sandbox 阻止，可用 swiftc 直接编译所有源文件：

```bash
cd DesktopPetForMacApp/DesktopPetForMacApp
swiftc -O -o /tmp/DesktopPetForMacApp \
  AccessibilityHelper.swift \
  DesktopPetForMacAppApp.swift \
  FileLogger.swift \
  FloatingWindow.swift \
  HTMLAlertWindow.swift \
  NetworkClient.swift \
  NewsFetcher.swift \
  PetViewModel.swift \
  SettingsPanel.swift \
  SpriteSheet.swift \
  StockHistoryManager.swift \
  StockService.swift \
  TodoManager.swift \
  WeatherService.swift \
  -framework AppKit -framework Foundation -framework SwiftUI -framework WebKit -framework Cocoa
```

### 打包成 .app（生成桌面 `cute pet.app`）

```bash
bash package.sh
```

> 一键「编译 → 打包 → 重启应用」可直接运行 `bash rebuild.sh`。

`package.sh` 会依次：Release 编译 → 拼装 `.app` 目录结构（可执行文件 + Info.plist + AppIcon + MenuBarIcon + Sprites 资源）→ 拷贝到桌面 → 重新签名（`codesign --force --deep --sign -`）→ 移除隔离属性（`xattr -cr`）。

> **注意**：需关闭 App Sandbox，否则窗口无法置顶；请勿在受限沙盒中运行编译。

---

## 项目结构

```
DesktopPetForMacApp/
├── Package.swift                          # SPM 工程配置（macOS 13+ / 可执行目标）
├── package.sh                             # .app 打包脚本
├── rebuild.sh                             # 一键编译 + 打包 + 重启
├── gen_wordbanks.py                       # 词库生成脚本（四级 / 六级 / 雅思 / 旅行，自动去重）
├── cute pet.app                           # 打包产物（可由脚本重新生成）
└── DesktopPetForMacApp/                   # 源码
    ├── DesktopPetForMacAppApp.swift       # @main 入口 + AppDelegate + 菜单栏
    ├── FloatingWindow.swift               # 浮动窗口 + CatView 绘制 + 右键菜单 + 各弹窗入口
    ├── PetViewModel.swift                 # 动画状态机 + 帧循环 + 行为调度 + 喝水提醒
    ├── SpriteSheet.swift                  # 精灵图帧加载（子文件夹 / 扁平前缀两种模式）
    ├── SettingsPanel.swift                # 菜单栏设置面板（卡片式状态切换）
    ├── HTMLAlertWindow.swift              # WKWebView 弹窗（展示 / 输入 / Todo 三种模式）
    ├── StockService.swift                 # 股票查询（腾讯行情接口）
    ├── StockHistoryManager.swift          # 股票查询历史（UserDefaults，最多 10 条）
    ├── WeatherService.swift               # 天气查询（和风天气 API，定位缓存）
    ├── NewsFetcher.swift                  # 热点新闻（头条热榜 → 百度热搜兜底）
    ├── NetworkClient.swift                # 统一网络请求层（URLSession + 同步桥接）
    ├── TodoManager.swift                  # Todo 持久化（UserDefaults + NSLock）
    ├── FileLogger.swift                   # 本地文件日志
    ├── AccessibilityHelper.swift          # 辅助功能权限检测（预留）
    ├── Info.plist                         # 应用配置（版本号 / 权限说明 / 禁用 App Nap）
    └── Resources/
        ├── AppIcon.icns / AppIcon.png     # 应用图标
        ├── MenuBarIcon.png                # 菜单栏图标
        ├── WordBank/                      # 单词词库（cet4 / cet6 / ielts / travel）
        └── Sprites/                       # 动画帧资源（按状态分目录）
            ├── focus/                     # 专注（15 帧）
            ├── idel/                      # 休闲（1 帧，预留）
            ├── warn/                      # 提醒（1 帧）
            ├── sleep/                     # 睡觉（无资源，回退占位图）
            └── pet/                       # 抚摸（23 帧）
```

---

## 架构设计

### 分层结构

| 层级 | 文件 | 职责 |
|------|------|------|
| 应用层 | `DesktopPetForMacAppApp.swift` | 应用生命周期、菜单栏、启动流程 |
| 窗口层 | `FloatingWindow.swift` | 无边框悬浮窗口管理、渲染调度 |
| 视图层 | `CatView`（FloatingWindow.swift 内） | 纯 AppKit `draw(_:)` 逐帧绘制 |
| 状态层 | `PetViewModel.swift` | 动画状态机、帧循环、随机行为、提醒调度 |
| 弹窗层 | `HTMLAlertWindow.swift` | WKWebView 弹窗（展示 / 输入 / Todo） |
| 设置层 | `SettingsPanel.swift` | 菜单栏设置面板 |
| 服务层 | `StockService` / `WeatherService` / `NewsFetcher` / `NetworkClient` | 数据查询与统一网络请求 |
| 持久化 | `StockHistoryManager` / `TodoManager` | UserDefaults 数据存取 |
| 资源层 | `SpriteSheet.swift` | 精灵图帧加载与占位图兜底 |
| 工具层 | `FileLogger.swift` / `AccessibilityHelper.swift` | 日志、权限检测 |

### 关键技术决策

- **窗口机制**：`FloatingPanel`（无边框 `NSWindow`，`canBecomeKey/canBecomeMain = false`），`level = .popUpMenu` 保证始终置顶，`collectionBehavior` 支持跨桌面与全屏共存。
- **渲染方式**：纯 AppKit `draw(_:)` 绘制。曾尝试 CALayer / NSImageView 子视图方案，均出现"鼠标悬停小猫消失"问题，最终回归最稳定的 `image.draw(in: bounds)` 逐帧绘制，通过 12 FPS Timer 驱动 `needsDisplay`。
- **朝向处理**："看向鼠标"朝向跟随（镜像翻转）是历史消失 bug 的元凶，**已移除**，小猫固定朝右显示。
- **动画调度**：`PetViewModel` 内置 12 FPS 帧循环 Timer + 行为调度 Timer；`pet`（抚摸）为一次性动画播完自动回 `focus`，`warn`（提醒）保持直到用户点击。
- **弹窗体系**：统一走 `HTMLAlertWindow`（WKWebView），支持内容自适应高度、输入模式、Todo 增删模式，避免手写复杂 NSView 布局。
- **网络层**：`NetworkClient` 基于 URLSession + Semaphore 做同步桥接，统一超时与 UA 设置，服务层在后台队列调用、主队列刷新 UI。

---

## 动画状态说明

| 状态 | 目录 | 帧数 | 触发方式 | 播放类型 |
|------|------|------|----------|----------|
| 专注 focus | `Sprites/focus/` | 15 | 默认状态；从 warn / pet / sleep 返回 | 循环 |
| 休闲 idel | `Sprites/idel/` | 1 | 设置面板切换（预留动画位） | 循环 |
| 提醒 warn | `Sprites/warn/` | 1 | 左键点击 / 每 30 分钟自动 / 喝水提醒 | 保持，点击后回 focus |
| 睡觉 sleep | `Sprites/sleep/`（缺） | 1（占位图） | 设置面板切换 | 保持直到手动切回 |
| 抚摸 pet | `Sprites/pet/` | 23 | 右键菜单 → 抚摸 | 播完自动回 focus |

---

## 交互方式

| 操作 | 行为 |
|------|------|
| 左键点击小猫 | 播放提醒（warn）动画，再次点击回到专注 |
| 双击小猫 | 打开 Todo 清单弹窗 |
| 按住拖拽 | 移动小猫位置 |
| 右键小猫 | 弹出菜单：抚摸 / 今日热点新闻 / 查询天气 / 输入地点查天气 / Todo 清单 / 输入股票代码查询 / 关闭 |
| 菜单栏图标 | 显示 / 隐藏小猫、设置、退出 |
| 设置面板 | 点击卡片切换：专注 / 休闲 / 睡觉 / 抚摸 |

---

## 内置服务说明

- **天气**：和风天气 API。首次定位成功后缓存经纬度；支持输入城市名查询。弹窗展示当前温度、天气描述、逐 6 小时温度、未来 7 天温度条（≥30°C 红色渐变）。
- **股票**：腾讯行情接口（`qt.gtimg.cn`，GB18030 编码）。代码自动规范化（`600000 → sh600000`、`000001 → sz000001` 等），支持 sh/sz/bj/hk 前缀；A 股红涨绿跌。
- **热点新闻**：今日头条热榜 Top10，接口失败自动切换百度热搜兜底；标题可点击跳转。
- **喝水提醒**：启动后等待下一个整点 / 半点触发，之后每 30 分钟一次；弹窗未关闭时不重复提醒，并播放 warn 动画。
- **Todo / 股票历史**：均持久化在 UserDefaults，Todo 支持增删，股票历史保留最近 10 条可点击回填。

---

## 精灵图资源说明

### 目录结构（子文件夹模式，推荐）

```
Resources/Sprites/
├── focus/    专注动画帧（focus_0.png ~ focus_N.png，或任意命名的 PNG）
├── idel/     休闲动画帧
├── warn/     提醒动画帧
├── sleep/    睡觉动画帧
└── pet/      抚摸动画帧
```

加载时优先扫描状态目录下所有 PNG（按文件名排序）；目录缺失时回退到扁平模式（`Resources/Sprites/focus_*.png`）；两者都无则使用橙色占位图（128×128）并记日志。

### 格式要求

1. 透明背景 PNG（带 Alpha 通道）
2. 推荐单帧 128×128 或 256×256 pt（@2x 视网膜屏）
3. 直接放入对应状态目录，无需改代码，重启应用生效

---

## 权限与常见问题

### 辅助功能权限

应用仍保留 `AccessibilityHelper` 权限检测代码（历史功能遗留）。当前版本的显示、动画、提醒均**不需要**辅助功能权限；如需使用全部能力（含窗口置顶兜底），可在 `系统设置 > 隐私与安全性 > 辅助功能` 中放行。

### App Sandbox

必须关闭 App Sandbox，否则浮动窗口无法设置为置顶层级。

### 分发给别人打不开（Gatekeeper）

macOS 会拦截从互联网下载的未签名应用，报错"无法打开"或"已损坏"。

方案一（推荐）：右键 `DesktopPetForMacApp.app` → 「打开」→ 再次右键 → 「打开」→ 点击「仍要打开」。

方案二：移除隔离属性

```bash
xattr -cr "/Applications/DesktopPetForMacApp.app"
```

### 日志

运行时日志写入 `~/Desktop/DesktopPetForMacApp_log.txt`，排查显示 / 动画问题可先看此文件。

---

## 版本记录

| 版本 | 说明 |
|------|------|
| 2026.10.10-test3 | 移除"看向鼠标"朝向跟随，修复小猫消失 bug；设置面板、状态重命名、服务层拆分 |
| 更早版本 | 菜单栏设置入口、喝水提醒、天气 / 股票 / 新闻 / Todo 功能迭代 |

---

## License

MIT License — 可自由修改和分发。
