# DesktopPetForMacApp — macOS 桌面小猫应用

一款基于 SwiftUI + AppKit 混合开发的 macOS 桌面虚拟宠物。小猫悬浮在桌面最上层，支持鼠标互动、精灵图动画和右键菜单。

---

## 架构设计思路

### 1. 分层架构

| 层级 | 文件 | 职责 |
|------|------|------|
| **应用层** | `DesktopPetForMacAppApp.swift` | 应用生命周期、权限检测、全局事件监听启动 |
| **窗口层** | `FloatingWindow.swift` | 无边框透明 `NSPanel` 管理，始终置顶 |
| **视图层** | `ContentView.swift` | SwiftUI + 原生 `NSViewRepresentable` 桥接，渲染帧动画 |
| **状态层** | `PetViewModel.swift` | 动画状态机、行为调度、鼠标响应、菜单交互 |
| **资源层** | `SpriteSheet.swift` | 精灵图/帧序列加载、帧裁剪、占位图兜底 |
| **工具层** | `AccessibilityHelper.swift` | 辅助功能权限检测与系统设置跳转 |

### 2. 关键技术决策

- **窗口机制**：使用 `NSPanel` 替代 `NSWindow`，配合 `styleMask: [.borderless, .nonactivatingPanel]` 实现无焦点、无边框、透明背景的悬浮面板。`level = .screenSaver` 确保始终置顶。
- **鼠标监听**：全局鼠标位置通过 `NSEvent.mouseLocation` 轮询（60ms 间隔），避免直接监听全局事件带来的性能和权限开销。原生右键点击通过自定义 `NSView` 的 `rightMouseDown` 捕获。
- **动画系统**：采用 12 FPS 定时器驱动 `currentFrameIndex`，支持循环动画（idle/walk）和一次性动画（jump/eat）。精灵图同时支持「单文件横向拼接」和「独立帧序列」两种资源格式。
- **SwiftUI ↔ AppKit 桥接**：由于 SwiftUI 在 macOS 上的右键手势支持有限，小猫主体渲染使用 `NSViewRepresentable` 包装自定义 `NSView`，在 `draw(_:)` 中直接绘制 `NSImage` 并通过 `CGContext` 做水平翻转实现朝向切换。

---

## 项目结构

```
DesktopPetForMacApp/
├── Package.swift                          # SPM 项目配置
├── DesktopPetForMacApp/
│   ├── DesktopPetForMacAppApp.swift                # @main 入口
│   ├── FloatingWindow.swift               # 悬浮窗口控制器
│   ├── ContentView.swift                  # SwiftUI 视图 + NSView 桥接
│   ├── PetViewModel.swift                 # 状态管理与动画调度
│   ├── SpriteSheet.swift                  # 精灵图加载器
│   ├── AccessibilityHelper.swift          # 权限检测
│   ├── Info.plist                         # 应用配置（含 NSAccessibilityUsageDescription）
│   └── Resources/
│       └── Sprites/                       # 小猫动画帧资源
│           ├── idle_0.png ~ idle_N.png
│           ├── walk_0.png ~ walk_N.png
│           ├── jump_0.png ~ jump_N.png
│           ├── sleep_0.png ~ sleep_N.png
│           └── eat_0.png ~ eat_N.png
```

---

## 环境要求

- **macOS**: 13.0+ (Ventura)
- **Xcode**: 15.0+
- **Swift**: 5.9+

---

## 动画状态与图片资源

### 状态说明

| 状态 | 图片数 | 触发条件 | 动画类型 |
|------|--------|----------|----------|
| **idle**（待机） | 15 张 | 默认状态、唤醒、抚摸/进食结束后自动回弹 | 循环播放 |
| **pet**（抚摸） | 23 张 | 右键菜单 → 进食（feed） | 播放一次后回 idle |
| **jump**（跳跃） | 1 张 | 左键点击、每 30 分钟自动触发、喝水提醒 | 保持，不自动回 idle |
| **sleep**（睡觉） | 0 张 | 右键菜单 → 睡觉（sleep） | 保持直到唤醒 |
| **walk**（走动） | 1 张 | 已定义但未使用（预留） | — |

### 资源文件结构

```
Resources/Sprites/
├── idle/     待机帧（15 张）：idle_0_副本.png ~ idle_0_副本15.png
├── pet/      抚摸帧（23 张）：idle_0.png ~ idle_11.png + 若干副本
├── jump/     跳跃帧（1 张）：clipboard-xxx.png
├── walk/     走动帧（1 张）：clipboard-xxx.png
└── sleep/    （暂无）
```

### 动画调度逻辑

- **12 FPS** 定时器驱动帧切换
- **随机行为**：每 30 分钟自动 jump 一次
- **一次性动画**（pet）播完后自动回到 idle
- **jump / sleep** 需用户主动触发才回 idle
- **喝水提醒**：每整点/半点触发 jump + 弹窗（弹窗未关闭时不重复弹）

---

## 编译

```bash
cd DesktopPetForMacApp
swift build -c release --disable-sandbox
```

打包到桌面：

```bash
bash package.sh
```

运行：

```bash
.build/release/DesktopPetForMacApp
```

或双击桌面 `桌面小猫.app`。

> **注意**：需关闭 App Sandbox，否则窗口无法置顶。首次启动需授权辅助功能权限（`系统设置 > 隐私与安全性 > 辅助功能`）。

---

## 如何替换小猫图片资源

### 资源格式要求

1. **透明背景 PNG**（必须带 Alpha 通道）
2. **推荐尺寸**：每帧 128×128 pt 或 256×256 pt（@2x 视网膜屏）
3. **两种导入方式可选**：

#### 方式 A：独立帧序列（推荐，最灵活）

将每张动画帧单独导出为 PNG，按以下命名放入 `Resources/Sprites/`：

```
idle_0.png, idle_1.png, idle_2.png ...   # 待机动画帧
walk_0.png, walk_1.png, walk_2.png ...   # 走动动画帧
jump_0.png, jump_1.png, jump_2.png ...   # 跳跃动画帧
sleep_0.png, sleep_1.png ...             # 睡觉动画帧
eat_0.png, eat_1.png ...                 # 进食动画帧
```

- 帧数不限，`SpriteSheet` 会自动扫描连续索引直到文件不存在。
- 动画按文件名顺序播放。

#### 方式 B：单文件横向精灵图

将多帧横向拼接为一张长图，命名格式：

```
idle_sheet.png   # 所有 idle 帧横向排列
walk_sheet.png
jump_sheet.png
...
```

然后在 `SpriteSheet.init(state:)` 中修改 `frameCount` 参数（默认扫描 8 帧）。

### 美术风格建议

| 风格 | 说明 |
|------|------|
| **Q 版像素风** | 32×32 ~ 64×64 像素/帧，适合复古感 |
| **矢量扁平风** | 128×128 以上，边缘清晰，适合现代桌面 |
| **手绘萌系** | 带描边和渐变，需保证透明底干净 |

### AI 生成资源提示词（Midjourney 示例）

> A cute chibi orange cat, idle animation sprite sheet, 8 frames, transparent background, kawaii style, clean vector art, flat colors, no shadows --ar 16:9 --niji 6

导出后使用 Photoshop / Aseprite 切帧并导出 PNG 序列。

---

## 权限说明

首次启动时，应用会检测**辅助功能权限**（Accessibility）：

- **用途**：监听鼠标位置以实现"看向鼠标"效果，以及确保窗口正确置顶。
- **引导**：未授权时会弹出提示，点击「前往设置」自动跳转到系统设置面板。
- **路径**：`系统设置 > 隐私与安全性 > 辅助功能 > DesktopPetForMacApp`（勾选）

同时务必在 **Xcode > Target > Signing & Capabilities** 中**关闭 App Sandbox**，否则窗口无法设置为 `screenSaver` 级别。

---

## 功能扩展建议

- **鼠标跟随移动**：在 `PetViewModel.updateMousePosition` 中加入窗口位置插值，让小猫在屏幕上跟随鼠标游走。
- **昼夜模式**：根据 `Calendar.current.hour` 切换不同的精灵图资源（白天活跃 / 夜晚打盹）。
- **语音交互**：集成 `Speech` 框架或接入 AI API，点击时播放预录喵叫声或语音回复。
- **开机自启**：使用 `SMLoginItemSetEnabled` 注册 LaunchAgent，或引导用户添加到「系统设置 > 登录项」。

---

## License

MIT License — 可自由修改和分发。
