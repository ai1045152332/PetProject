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
| P2 | 拖拽 / 点击 / 托盘 | 🔄 拖拽（手动搬窗）✅、托盘 ✅；左键点击互动待做 |
| P3 | 右键菜单 + 喝水提醒 | 🔄 喝水 ✅；右键菜单（抚摸 / 新闻 / 天气 / Todo / 躲起来 / 设置）✅；喂猫条等待后续 |
| P4 | 新闻 / 天气 / 股票服务 | 🔄 热点新闻（头条主源 + 百度兜底）✅、天气（走 PetServer `/api/weather` 转发）✅；股票待做 |
| P5 | Todo + 背单词 | 🔄 Todo ✅；背单词待做 |
| P5+ | 权限校验码（解锁/定时复核）+ 每日天气提醒 | ✅（混合加密与 mac 版 / PetServer 契约互验） |
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
| `npm run dist:win` | Windows | `dist/*-setup.exe`（NSIS 安装包） |
| `npm run dist` | 当前系统 | 按当前 OS 自动打对应包 |

图标资源放在 `packaging/`：`icon.icns`（mac）、`icon.png`（1024×1024，electron-builder 会据此自动生成 Windows `icon.ico`）。

### macOS 打包

**推荐走脚本**（清旧产物 → 物化图标 → 打包，一步出 dmg）：

```bash
../skills/cute-pet-deploy/scripts/build-mac-electron-local.sh        # → dist/DesktopPet-<版本>-arm64.dmg
../skills/cute-pet-deploy/scripts/build-mac-electron-local.sh --open # 打完自动挂载
```

手工跑 `npm run dist:mac` 时要带真实图标路径，否则 dmg 阶段会报
`xattr.Set … .VolumeIcon.icns … no such file or directory`（`packaging/icon.icns` 是软链，electron-builder 不跟随）：

```bash
cp -L packaging/icon.icns /tmp/icon.icns
CSC_IDENTITY_AUTO_DISCOVERY=false npm run dist:mac -- -c.dmg.icon=/tmp/icon.icns
```

> 打出的 `.app` 未签名（ad-hoc），首次打开需在「系统设置 → 隐私与安全性」里点「仍要打开」，或用 `xattr -dr com.apple.quarantine DesktopPet.app` 去隔离。

### Windows 打包

- **推荐在 Windows 机器上执行** `npm run dist:win`，最稳妥。
- **架构默认 x64**：`dist:win` 已带 `--x64`。在 Apple Silicon Mac 上交叉打包时，若不带该参数会默认产出 arm64 包，绝大多数 Windows 机器（Intel/AMD）无法运行。ARM64 Windows 用 `npm run dist:win:arm64`（产物同名，与 x64 包互相覆盖，需要并存请自行加 `artifactName` 区分）。
- 在 macOS / Linux 上交叉打 Windows 包时，`nsis` 目标可能需要安装 **Wine**（`brew install --cask wine-stable`）。
- Windows 安装包**未做代码签名**时，浏览器下载会报「不常见、可能有害」，首次运行 SmartScreen 蓝屏拦截。要消除「非基线 / 没签名」警告，需用代码签名证书，详见下方「代码签名」。

### 代码签名（消除「非基线 / 没签名」警告）

未签名的 `.exe` 在 Windows 上会遇到两类拦截：
1. **浏览器下载拦截**（Edge/Chrome SmartScreen）：报「此文件不常见，可能下载有害软件」，发布者显示「Unknown」。
2. **首次运行拦截**（Windows SmartScreen 蓝屏）：报「Windows 已保护你的电脑」。

两者都靠 **Authenticode 代码签名**解决。证书分两类：

| 类型 | 价格（年） | SmartScreen 效果 | 适用 |
|------|-----------|------------------|------|
| OV（组织验证） | ~¥1500–3000 | 签名后仍可能短暂拦截，下载量积累数周后消除 | 内部工具、小范围分发 |
| **EV**（扩展验证） | ~¥3000–6000 | **立即信任**，显示发布者名称，无蓝屏 | 公开下载、正式分发 |

> **推荐 EV**：桌面宠物对外分发，一次到位无后续摩擦。主流颁发机构：Sectigo、DigiCert、SSL.com。购买后会得到一个 `.p12`（或 `.pfx`）证书文件和密码。

#### 配置签名

electron-builder 通过环境变量读取证书，无需修改 `package.json`：

```bash
WIN_CSC_LINK=/path/to/your-cert.p12 \
WIN_CSC_KEY_PASSWORD=your-cert-password \
npm run dist:win
```

> 在 macOS 上交叉签名 Windows 包时，electron-builder 调用 `osslsigncode`（`brew install osslsigncode`），首次使用前确认已安装。EV 证书如为 USB 硬件令牌，需额外配置 PKCS#11。
> **不要把证书路径或密码提交到 git**。

暂未购买证书时的临时方案：把 `dist/*-setup.exe` 打成 `.zip` 分发（浏览器对 zip 不拦截下载），解压后首次运行仍需点「更多信息 → 仍要运行」。SmartScreen 对未签名 PE 文件的蓝屏无法绕过。

#### 签名验证

打包产物（`dist/*-setup.exe`）签名完成后，在 Windows 上右键 → 属性 → 数字签名，应能看到签名者名称。Edge/Chrome 下载该 `.exe` 后不再拦截。

### Windows 安装

**方式一：直接用已有安装包**（`dist/` 下已构建好，拷到 Windows 即可）

| 文件 | 用法 |
|------|------|
| `DesktopPet Setup <版本>.exe` | NSIS 安装包：双击安装，可改安装目录、自动建桌面快捷方式 |

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
│   │   ├── pet-context-menu.js # 宠物右键菜单（P3：抚摸 / 新闻 / 天气 / Todo / 躲起来 / 设置 / 关闭）
│   │   ├── card-window.js      # 无边框透明卡片窗工厂（新闻 / 天气结果卡共用，单例复用）
│   │   ├── news-service.js     # 热点新闻抓取：头条主源 + 百度热搜兜底（对标 NewsFetcher.swift）
│   │   ├── weather-service.js  # 天气查询：IP 定位 / 城市地理编码 → PetServer /api/weather（对标 WeatherService.swift）
│   │   ├── settings-window.js  # 设置面板窗口（无边框透明，单例）
│   │   ├── settings-service.js # 设置业务逻辑：读间隔 / 校验写入 / 天气提醒配置 / 权限状态
│   │   ├── access-service.js   # 权限校验码：本地码直过 / 加密后走 /api/access/verify / 定时复核（对标 AccessControl.swift）
│   │   ├── crypto-envelope.js  # 载荷混合加密：AES-256-GCM + RSA-OAEP（对标 PayloadCrypto.swift / 服务端 HybridEnvelope）
│   │   ├── weather-reminder.js # 每日天气提醒调度：睡眠补偿 + 权限守卫（对标 WeatherReminderService.swift）
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
│   └── pet-context-menu.test.js # 右键菜单：项构成 / 抚摸、设置与退出回调 / 层级让位
└── assets/
    ├── Sprites/              # 软链 → 仓库根 SharedAssets/Sprites（与 mac 原生版共用同一批帧；focus/sleep 8 帧、idel/pet 24 帧、hide 1 帧，均 200×200）
    ├── MenuBarIcon.png       # 菜单栏图标 → 软链到仓库根 SharedAssets/MenuBarIcon.png（与 mac 原生版共用）
    └── WindowsTray(@2x).png  # Windows 专用：带五官的白猫 + 深灰描边（32/64，4x 超采样导出）
```

- 帧数不写死：`src/main/sprite-frames.js` 按 `assets/Sprites/<state>/` 枚举帧数（对标 Swift `SpriteSheet`），经 `pet:frame-counts` 下发给 `pet.js` 循环。
  素材统一到 `SharedAssets/Sprites` 后 idel/pet 已是 24 帧，以前写死的 `FRAME_COUNTS = 8` 会只播前三分之一、循环在中间卡断。
- mac 菜单栏图标与原生版**共用同一个物理文件**（`SharedAssets/MenuBarIcon.png`），不做任何像素加工：
  `src/main/tray.js` 加载后经 `resize()` 缩到 22pt 并标为模板图，与 Swift 侧 `img.size = 22×22` + `isTemplate = true` 完全对称。
  两个坑：Electron 把位图尺寸直接当点尺寸，360×348 原图不缩放会巨到不显示；`resize()` 返回新图、不改原对象，必须接住返回值。
- Windows 无模板图反色机制，用单独一张 `WindowsTray.png`（+@2x）：保留原画五官/胡须的白猫 + 深灰描边，深浅任务栏都能看清。
  导出时做 4x 超采样再缩回，避免描边锯齿与断裂（直接在 32px 上算形态学会得到白面团 + 碎块描边）。
  这两张图从同一张源图一次性导出，仓库里不留生成脚本；**换 `SharedAssets/MenuBarIcon.png` 时记得同步重导这两张**。

- 打包相关：`packaging/`（`icon.icns` 是软链 → 仓库根 `SharedAssets/AppIcon.icns`，与 mac 原生版共用同一文件；`icon.png`）、`dist/`（electron-builder 产物）。electron-builder 会跟随软链，打包产物里已是完整图标。

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
| 🐱 宠物信息 | 可用 | 形象网格 5 格（专注/休闲/睡觉/抚摸点击即时切帧 + 躲藏只读展示）✅、每格可「直接上传」自定义小猫图（存本机，更新不丢）✅、「AI 生成所有状态图片」✅（需服务端激活码，一张照片逐状态各生成一张、整批扣 1 次配额，面板显示剩余次数）✅、「查看历史图片」窗 ✅（本机图与失败记录列表，应用/删除/重试）、宠物名称 ✅、宠物号展示 ✅ |
| ⚙️ 通用设置 | 部分可用 | 开机自启 ✅、宠物大小 0.5x～2.0x ✅、版本号 + 检查更新 ✅、权限校验码解锁 ✅ |
| 🔔 提醒设置 | 可用 | 喝水提醒 ✅（预设 15/30/45/60 + 自定义 1～120 + 测试提醒）、每日天气提醒 ✅（需解锁，含时间/城市/预览）、主动搭话 ✅（开关 + 15/30/60 分钟预设，宠物头顶冒气泡） |
| 🖱️ 菜单设置 | 可用 | 勾选宠物右键菜单要展示的功能项（抚摸 / Todo / 躲起来 / 新闻 / 天气），写盘即生效，下次弹菜单就应用 |
| 👫 好友消息 | 可用 | 宠物号展示 + 复制 ✅、按宠物号发好友申请 ✅、待处理申请同意/拒绝 ✅、好友列表（聊天 / 删除）✅、会话聊天窗 ✅；新申请与新留言由心跳下发自动弹卡 |

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

### 形象区与躲藏态

「宠物信息 → 形象」固定展示 5 格（`settings-service.panelPetStates()`）：四个可切换态 + `hide`。

- 躲藏格（虚线框）能预览、能上传/恢复默认 `local-hide.img`，但点它不会切换形象：`settings:set-pet-state` 会用 `isSwitchablePetState` 拒掉 hide，因为窗口没吸附就切过去等于把半个身子留在屏外；进入躲藏只能拖到屏幕侧边或右键「躲起来」。
- 格子上两个圆点：左上绿点 = 宠物此刻正在播这一格，右上蓝点 = 这一格已上传自定义图；选中框只表示上传/恢复默认针对哪一格（因此躲藏格上三者会不一致）。
- 面板开着时主进程会推 `settings:pet-state`，因此贴边躲藏 / 专注跟随 / 右键抚摸都会实时把「当前状态」刷成「躲藏中」。
- 躲藏中从面板切其他形象会先调 `revealFromHiding` 把窗口收回屏内，再切帧目录。

### 自定义状态图片（直接上传 / AI 生成 / 历史图片）

与 mac 版同一套三层拆法（网络 / 编排 / 窗口各一层，互不引用）：

| 文件 | 职责 |
|------|------|
| `src/main/pet-image-service.js` | 只负责 `/api/pet-images/*`：加密信封 `{code,deviceId,id,state}`、multipart 上传、生成轮询（单张 200 轮 / 整批 400 轮，间隔 3s） |
| `src/main/pet-image-flow.js` | 业务编排与内存态：busy / 配额 / 阶段文案 / 历史图片快照，落盘一律交给 `custom-sprite-store.js` |
| `src/main/pet-image-history-window.js` + `pet-history.*` | 820×580 单例历史窗：按状态筛选、左缩略图右详情，失败记录也是一张卡片 |
| `src/main/image-meta.js` | 不装第三方图像库，直接按字节魔数解析 PNG/JPEG/GIF 宽高与帧数（上传与落盘两处共用同一门槛） |

- 图片都存在 `CustomSprites` 目录（与 mac 版 App 共用，升级不丢）：`local-<state>.img` 直传图 + `cloud-<id>.img` AI 生成图，配 `local-selections.json` / `cloud-selections.json` 两份选中清单（空串 = 显式恢复默认）；优先级 local > cloud > legacy。
- 归属与选中分开存：`cloud-states.json` 记「这张图是哪个状态生成的」（只记首次），换图 / 删除后历史图片仍按状态归类；`sprite-failures.json` 记各状态最近一次失败与服务端任务 ID，历史窗据此弹重试卡。
- 直接上传、恢复默认、历史切图全部不依赖激活码；只有 AI 生成与重试需要服务端激活码（本地快捷码 456 不绑码，拿不到配额）。
- `/api/pet-images/*` 的业务失败走 HTTP 400/403/429/503 + `{code,msg}`（与 social 接口一律 200 不同），因此非 200 也要先解 `msg`，“生成次数已用完”这类服务端文案才能原样显示在面板上。

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

发布 Windows 包（与 mac 版同一把私钥 `~/.cute-pet-release/ed25519_private.pem`）。

**推荐走脚本**（自动递增版本、只挑 NSIS 安装版、签名自检、合并写 manifest、上传后回读验证）：

```bash
../skills/cute-pet-deploy/scripts/build-win-local.sh   # 只本地打包，自己试
../skills/cute-pet-deploy/scripts/deploy-win.sh        # 发线上（官网可下载 + 客户端自动更新）
```

以下是手工等价做法，仅供理解流程（**手动改 latest.json 时必须合并，不能整体覆盖**，否则会挤掉 mac 原生版的更新通道）：

```bash
npm run dist:win                     # 产出 dist/*-setup.exe
SHA=$(shasum -a 256 dist/*-setup.exe | awk '{print $1}')
printf '%s' "$SHA" > digest.txt
SIG=$(openssl pkeyutl -sign -rawin -inkey ~/.cute-pet-release/ed25519_private.pem -in digest.txt | base64 | tr -d '\n')
# 先 GET /api/app/latest 取现有 manifest，只合并 winVersion/winFile/winSHA256/winSignature/winNotes/winSize
# 再连同安装包一起上传到服务器 dist/ 下
```

## 宠物右键菜单（P3）

对标 Swift 版 `CatView.rightMouseDown`（FloatingWindow.swift），本版只收录能力已就绪的项：

| 菜单项 | 行为 | 对应 Swift 版 |
|--------|------|--------------|
| 抚摸 🐾 | 一次性动画：播完一圈 pet 帧 + hold 1.5s 自动回原状态（对标 Swift `playOneShot`），心跳 `petState` 同步上报 | `petAction` |
| 今日热点新闻 📰 | 主进程抓头条热榜（失败自动换百度热搜）取 Top10，弹单例卡片窗；点条目走系统浏览器 | `hotNewsAction` → `fetchAndShowHotNews` |
| 查看天气 ☀️ | 弹带城市输入框的天气窗，打开即按 IP 定位查本地天气，输入城市同窗刷新；请求走 PetServer `/api/weather`（上游 Key 只在服务端） | `showWeatherAction` → `showWeatherInput` |
| Todo 清单 📝 | 开本地待办窗（userData 持久化，也可双击宠物打开） | `todoAction` → `showTodoList` |
| 躲起来 👀 | 不看当前距离直接吸到最近一侧屏幕边进入 hide（贴边探头） | `hideAction` → `snapToEdgeForHiding` |
| 设置… | 打开设置面板（与托盘「设置」同一入口，任何权限下都可点） | `settingsAction` |
| 关闭 ❌ | 退出应用 | `quitAction` |

菜单分**三栏**（栏间留分隔线）：其他功能（抚摸 / Todo / 躲起来 / 新闻 / 天气）｜设置…｜关闭。与 Swift 版一致，右键宠物即可打开「设置…」；显隐、检查更新仍只在菜单栏托盘（Windows 托盘图标会被 Win11 折进通知区，因此额外走 trayFallback 补到「其他功能」栏末尾）。

未实现的项（喂猫条 🍡、背单词 📚、苦练基本功 🧩、股票 📈、菜单设置过滤）依赖 P5 剩余服务与菜单设置模块，就绪后逐步补齐。基础权限下新闻/天气菜单项置灰并尾部加「解锁更多功能 🔓」引导（对标 Swift fullOnly），入口层另有兜底：即使被其它路径调到也会转到设置面板权限区，不直接碰付费接口。

新闻 / 天气实现要点：

- 抓取与查询全部在主进程完成（`news-service.js` / `weather-service.js`），渲染页只展示 IPC 推来的内容，因此无需给这两个页面放开 CSP 连外网；上游接口改字段时也只改主进程解析。
- 两个结果卡共用 `card-window.js` 工厂：无边框透明 + `screen-saver` 层级 + 单例复用（已开着只前置并推新内容），与 Todo / 提醒窗同风格；打开期间由 `yieldTopTo` 让出宠物置顶。
- 天气不直连和风：按 mac 版同样走 PetServer `/api/weather` 转发（服务端代持 Key、按 deviceId 限流）；城市名先过 Nominatim 地理编码拿坐标，本地天气走 api.ip.sb IP 定位。
- 调试验证 UI 不烧按量付费接口：`PET_TEST_WEATHER_MOCK=1 PET_TEST_WEATHER_SHOT=/tmp/x.png npm start` 用假预报数据渲染；去掉 MOCK 才会真请求 `/api/weather`。

实现要点（`src/main/pet-context-menu.js`）：

- 触发链路：渲染层监听 `contextmenu`（拦默认菜单）→ IPC → 主进程 `Menu.popup()`。
  **不能用 `-webkit-app-region: drag` + 主进程 `webContents.on('context-menu')`**：原生拖拽区会在事件到达页面前吞掉鼠标事件，真实右键根本弹不出菜单（`webContents.sendInputEvent` 注入能绕过这条拦截，用它验证会得到假阳性，必须用真实鼠标事件验证）。
- 拖拽同步改为手动实现（对标 Swift 版 `mouseDragged → setFrameOrigin`）：渲染层 mousedown/mousemove 拿鼠标屏幕坐标，主进程 `createDragController` 按 offset 搬窗（rAF 合帧防 IPC 洪水），见 `tests/pet-drag.test.js`。
- 层级让位：弹出前 `petGuard.pause(10000)`，菜单 `menu-will-close`（含 Esc / 点外部自动收起）后 `resume()` 抢回置顶，与托盘菜单同一套规则。
- 测试钩子：`PET_TEST_CONTEXT_MENU=1 npm start` 2.5s 后自动弹菜单（菜单弹在光标处，肉眼可验）。

## 测试

```bash
npm test          # tests/ 下 14 个用例文件依次跑（node 直跑、mock 掉 electron）：
                  #   update-heartbeat / settings-panel / custom-sprite / on-top-guard
                  #   tray-interaction / sysinfo-menu / metric-bar-image / pet-context-menu
                  #   sprite-frames / pet-drag / focus-edge / todo / news-weather / access-weather-reminder
```

界面本身用 Electron 的 `webContents.capturePage()` 截图验证（不依赖系统录屏权限）；想直接看面板可 `PET_TEST_SETTINGS=1 npm start`，启动 2.5 秒后自动弹出设置面板。

## 说明

- 资源（Sprites）从 `DesktopPetForMacApp` 拷贝而来，后续词库 / 题库接入方式相同。
- 服务端 `PetServer`（Go）跨平台，心跳 / 版本接口与 mac 版共用（Electron 发布字段见上文「跨平台发布字段」）。
- 设置面板已移植：喝水提醒、主动搭话、菜单设置、每日天气提醒（需解锁）、权限（校验码解锁）、好友消息与聊天、自定义状态图片（直接上传 / AI 生成 / 历史图片）。
