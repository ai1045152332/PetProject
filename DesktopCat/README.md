# DesktopCat — macOS 桌面小猫应用

一款基于 SwiftUI + AppKit 混合开发的 macOS 桌面虚拟宠物。小猫悬浮在桌面最上层，支持鼠标互动、精灵图动画和右键菜单。

---

## 架构设计思路

### 1. 分层架构

| 层级 | 文件 | 职责 |
|------|------|------|
| **应用层** | `DesktopCatApp.swift` | 应用生命周期、权限检测、全局事件监听启动 |
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
DesktopCat/
├── Package.swift                          # SPM 项目配置
├── DesktopCat/
│   ├── DesktopCatApp.swift                # @main 入口
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

## 编译与运行

### 前置条件

- macOS 13.0+ (Ventura)
- Xcode 15.0+ 或 Command Line Tools
- Swift 5.9+

```bash
# 检查 Swift 版本
swift --version
```

### 方式一：命令行编译 + 打包（推荐）

**Step 1 - 编译 Release 二进制**

```bash
cd DesktopCat
swift build -c release --disable-sandbox
```

> `--disable-sandbox`：禁用 SPM 沙盒限制，避免 `sandbox-exec: Operation not permitted` 错误

**Step 2 - 一键打包到桌面**

```bash
bash package.sh
```

> 脚本会自动完成：编译 → 组装 .app → 复制图标和资源 → 拷贝到桌面

**Step 3 - 运行**

双击桌面 `桌面小猫.app` 启动。

### 方式二：仅编译（不打包）

```bash
cd DesktopCat
swift build -c release --disable-sandbox
# 直接运行二进制
.build/release/DesktopCat
```

### 方式三：Xcode（适用于调试）

1. 打开 Xcode，选择 **File > New > Project**，创建 macOS App 项目，命名为 `DesktopCat`。
2. 将本项目的所有 `.swift` 文件拖入 Xcode 的 `DesktopCat/` 组中。
3. 将 `Resources/Sprites/` 目录拖入 Xcode，选择 **Create folder references**。
4. 在 `Info.plist` 中确认已添加 `NSAccessibilityUsageDescription`。
5. **关闭沙盒**：选中 Target → Signing & Capabilities → 删除或禁用 `App Sandbox`。纯沙盒应用无法使用 `screenSaver` 窗口级别和全局鼠标监听。
6. 按 `Cmd + R` 运行。

### 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `sandbox-exec: Operation not permitted` | SPM 沙盒限制 | 使用 `--disable-sandbox` 参数 |
| 图标显示不正确 / 没变化 | macOS 需 `.icns` 格式 | 用 `sips` + `iconutil` 将 PNG 转为 `.icns`，放入 `Resources/` |
| 图标缓存不刷新 | Finder 缓存旧图标 | 执行 `lsregister -f -R /path/to/App.app && killall Finder` |
| 窗口无法置顶到最上层 | App Sandbox 限制 | 关闭 App Sandbox，或使用非沙盒编译 |
| 鼠标跟随无效果 | 缺少辅助功能权限 | `系统设置 > 隐私与安全性 >辅助功能` 中启用 DesktopCat |

### 替换 App Icon

将 `AppIcon.png` 放入 `DesktopCat/Resources/`，然后执行：

```bash
# 1. 创建 iconset 目录
mkdir -p /tmp/AppIcon.iconset

# 2. 生成各种尺寸
sips -z 16 16 AppIcon.png --out /tmp/AppIcon.iconset/icon_16x16.png
sips -z 32 32 AppIcon.png --out /tmp/AppIcon.iconset/icon_16x16@2x.png
sips -z 32 32 AppIcon.png --out /tmp/AppIcon.iconset/icon_32x32.png
sips -z 64 64 AppIcon.png --out /tmp/AppIcon.iconset/icon_32x32@2x.png
sips -z 128 128 AppIcon.png --out /tmp/AppIcon.iconset/icon_128x128.png
sips -z 256 256 AppIcon.png --out /tmp/AppIcon.iconset/icon_128x128@2x.png
sips -z 256 256 AppIcon.png --out /tmp/AppIcon.iconset/icon_256x256.png
sips -z 512 512 AppIcon.png --out /tmp/AppIcon.iconset/icon_256x256@2x.png
sips -z 512 512 AppIcon.png --out /tmp/AppIcon.iconset/icon_512x512.png
sips -z 1024 1024 AppIcon.png --out /tmp/AppIcon.iconset/icon_512x512@2x.png

# 3. 生成 .icns
iconutil -c icns /tmp/AppIcon.iconset -o DesktopCat/Resources/AppIcon.icns

# 4. 清理
rm -rf /tmp/AppIcon.iconset

# 5. 重新打包
bash package.sh
```

> `Info.plist` 中需包含 `<key>CFBundleIconFile</key><string>AppIcon</string>`（不带扩展名）

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
- **路径**：`系统设置 > 隐私与安全性 > 辅助功能 > DesktopCat`（勾选）

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
