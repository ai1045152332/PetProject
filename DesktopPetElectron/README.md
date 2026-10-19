# DesktopPetElectron — 跨平台桌面宠物（Electron 版）

macOS 原生版（`DesktopPetForMacApp`）的跨平台重写，目标同时覆盖 Windows / macOS。
采用分阶段推进，当前进度：**P0 悬浮窗**。

## 阶段路线

| 阶段 | 内容 | 状态 |
|------|------|------|
| P0 | 透明、置顶、无边框悬浮窗 + focus 帧循环 | ✅ 当前 |
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
│   │   ├── index.js          # 主进程入口 + 应用生命周期
│   │   └── pet-window.js     # 透明置顶悬浮窗
│   └── renderer/
│       ├── index.html        # 宠物窗口页面
│       ├── pet.css           # 透明 + 拖动区域样式
│       ├── pet.js            # 帧循环（后续扩展为状态机）
│       └── preload.js        # 预加载脚本占位
└── assets/
    └── Sprites/              # 从 mac 工程拷贝的动画帧（focus/idel/warn/sleep/pet）
```

- 打包相关：`packaging/`（图标资源 icon.icns / icon.png）、`dist/`（electron-builder 产物）。

## 说明

- 资源（Sprites）从 `DesktopPetForMacApp` 拷贝而来，后续词库 / 题库接入方式相同。
- 服务端 `PetServer`（Go）跨平台，无需改动，P4 阶段直接对接。
