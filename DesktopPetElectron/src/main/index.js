// src/main/index.js
// DesktopPetElectron — 主进程入口
// 职责：应用生命周期 + 创建宠物窗口 + 喝水提醒调度 + 心跳上报 + 自动更新 + IPC
'use strict';

const { app, BrowserWindow, Menu, ipcMain, globalShortcut } = require('electron');
const { createPetWindow, applyPetScale, startOnTopGuard } = require('./pet-window');
const { openReminderWindow, closeReminderWindow } = require('./reminder-window');
const { openSettingsWindow, closeSettingsWindow } = require('./settings-window');
const {
  SettingsService,
  currentPetScale,
  isValidPetState,
} = require('./settings-service');
const { ReminderScheduler } = require('./reminder-scheduler');
const { createTray, setTrayStatus } = require('./tray');
const { HeartbeatService } = require('./heartbeat');
const { UpdateService } = require('./update-service');
const info = require('./app-info');
const config = require('./config-store');

let petWindow = null;
let petGuard = null;   // Windows 置顶守护（周期性抬回最上层）
let scheduler = null;
let heartbeat = null;
let updater = null;
let settings = null;

// 当前让宠物让出置顶层级的窗口数（设置窗 / 提醒窗 / 托盘菜单打开期间）
let topYieldCount = 0;

// 创建（或复用）宠物窗，并同步维护置顶守护
function ensurePetWindow() {
  if (petWindow && !petWindow.isDestroyed()) {
    if (!petGuard) petGuard = startOnTopGuard(petWindow);
    return petWindow;
  }
  petWindow = createPetWindow({ scale: currentPetScale() });
  petGuard = startOnTopGuard(petWindow);
  petWindow.on('closed', () => {
    if (petGuard) petGuard.stop();
    petGuard = null;
    petWindow = null;
  });
  return petWindow;
}

/**
 * 某个原生窗口需要盖在宠物上面（设置面板 / 提醒窗）时让出置顶，窗口关闭后自动恢复。
 * 用计数而不是布尔值，避免多个窗口同时打开时提前抢回顶层。
 */
function yieldTopTo(win) {
  if (!win || !petGuard) return;
  topYieldCount += 1;
  petGuard.pause(Infinity);
  win.once('closed', () => {
    topYieldCount = Math.max(0, topYieldCount - 1);
    if (topYieldCount === 0 && petGuard) petGuard.resume();
  });
}

// 宠物当前状态：目前只有 focus 帧循环（P1 状态机上线后由渲染层回传）
let petState = 'focus';

// 向渲染进程发送事件（窗口存在才发）
function sendToRenderer(channel, payload) {
  if (petWindow && !petWindow.isDestroyed()) {
    petWindow.webContents.send(channel, payload);
  }
}

// 开机自启当前状态（mac / Windows 都通过系统登录项实现）
function isAutoLaunchEnabled() {
  try {
    return Boolean(app.getLoginItemSettings().openAtLogin);
  } catch (e) {
    return false;
  }
}

// 触发一次喝水提醒：弹出提醒窗 + 专注动画从头播放（提醒已合并进专注，不再有独立 warn 动画）
function fireReminder() {
  yieldTopTo(openReminderWindow());
  sendToRenderer('drink-water:show');
}

// 打开设置面板（打开期间宠物让出置顶，否则宠物会盖住面板）
function openSettings() {
  yieldTopTo(openSettingsWindow());
}

// 应用菜单：mac 上用最小菜单集（保留编辑菜单，输入框才能 Cmd+C/V）
function buildAppMenu() {
  if (process.platform !== 'darwin') return;
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      label: app.name,
      submenu: [
        { role: 'about', label: `关于 ${app.name}` },
        { type: 'separator' },
        { label: '设置…', accelerator: 'CommandOrControl+,', click: () => openSettings() },
        { type: 'separator' },
        { role: 'hide', label: `隐藏 ${app.name}` },
        { role: 'hideOthers', label: '隐藏其他' },
        { role: 'unhide', label: '全部显示' },
        { type: 'separator' },
        { role: 'quit', label: `退出 ${app.name}` },
      ],
    },
    { role: 'editMenu', label: '编辑' },
    { role: 'windowMenu', label: '窗口' },
  ]));
}

// 更新流程的托盘提示：检查中/下载中/安装中都有反馈，结束后恢复默认文案
function onUpdateStatus(status) {
  if (!status) return;
  if (status.phase === 'checking') setTrayStatus('正在检查更新…');
  else if (status.phase === 'downloading') setTrayStatus(`正在下载 ${status.version || '更新'} ${status.percent || 0}%`);
  else if (status.phase === 'ready') setTrayStatus(`更新已下载，准备安装 ${status.version || ''}`.trim());
  else if (status.phase === 'installing') setTrayStatus('正在安装更新，宠物马上回来…');
  // 空串让托盘回到默认文案（带版本号 + 当前显隐状态）
  else setTrayStatus();
}

app.whenReady().then(() => {
  ensurePetWindow();

  // 喝水提醒：从持久化配置读取间隔，启动调度器
  scheduler = new ReminderScheduler({
    getIntervalMinutes: () => config.get('drinkWaterInterval'),
    send: fireReminder,
  });
  scheduler.start();

  // 设置面板业务逻辑（提醒间隔 / 宠物名称 / 宠物大小），与 IPC 接线分离
  settings = new SettingsService({
    scheduler,
    providers: {
      version: () => info.currentVersion(),
      petNo: () => config.get('petNo') || 0,
      petState: () => petState,
      autoLaunch: isAutoLaunchEnabled,
      heartbeat: () => (heartbeat ? heartbeat.getStatus() : null),
    },
  });

  // 应用菜单：mac 上提供「设置…」与 Cmd+,（保留编辑菜单，设置面板的输入框才支持复制粘贴）
  buildAppMenu();

  // 心跳上报：启动即报一次，之后每 1 分钟一次（与 mac 版同节奏、同上报体）
  heartbeat = new HeartbeatService({ getState: () => petState });
  heartbeat.start();

  // 自动更新：启动 30 秒后首次检查，之后每 24 小时一次；托盘菜单可手动触发
  updater = new UpdateService({ onStatus: onUpdateStatus });
  updater.start();

  // 提醒窗关闭按钮 → 收起提醒窗、解除"正在显示"（专注动画自身持续循环，无需通知渲染层切换）
  ipcMain.on('drink-water:dismiss', () => {
    closeReminderWindow();
    if (scheduler) scheduler.dismiss();
  });

  // ── 设置面板 IPC（对应 mac 版 SettingsPanel 的喝水提醒分区）──
  // 读：当前间隔 + 预设 + 合法区间
  ipcMain.handle('settings:load', () => settings.load());

  // 写：校验 → 持久化 → 立即重启计时（与 mac 版 restartDrinkWaterReminder 行为一致）
  ipcMain.handle('settings:set-interval', (event, minutes) => {
    const result = settings.setInterval(minutes);
    console.log(`[settings] drinkWaterInterval -> ${JSON.stringify(result)}`);
    return result;
  });

  // 立即弹一次提醒（设置面板「测试提醒」）
  ipcMain.on('settings:test-reminder', () => settings.testReminder());

  ipcMain.on('settings:close', () => closeSettingsWindow());

  // ── 宠物信息：名称 / 形象 ──
  ipcMain.handle('settings:set-pet-name', (event, name) => {
    const result = settings.setPetName(name);
    if (result.ok) console.log(`[settings] petName -> ${result.name}`);
    return result;
  });

  ipcMain.handle('settings:set-pet-state', (event, state) => {
    if (!isValidPetState(state)) {
      return { ok: false, error: '不支持的形象', state: petState };
    }
    petState = state;
    sendToRenderer('pet:state', state); // 换帧目录（focus / idel / sleep / pet）
    console.log(`[settings] petState -> ${state}`);
    return { ok: true, state };
  });

  // ── 通用设置：宠物大小 / 开机自启 / 检查更新 ──
  ipcMain.handle('settings:set-pet-scale', (event, scale) => {
    const result = settings.setPetScale(scale);
    if (result.ok) applyPetScale(petWindow, result.scale);
    console.log(`[settings] petScale -> ${JSON.stringify(result)}`);
    return result;
  });

  ipcMain.handle('settings:set-auto-launch', (event, enabled) => {
    const on = Boolean(enabled);
    try {
      app.setLoginItemSettings({ openAtLogin: on });
    } catch (e) {
      return { ok: false, error: '当前系统不支持设置开机自启', enabled: isAutoLaunchEnabled() };
    }
    const actual = isAutoLaunchEnabled();
    console.log(`[settings] autoLaunch -> ${actual}`);
    return { ok: true, enabled: actual };
  });

  ipcMain.handle('settings:check-update', async () => {
    app.focus({ steal: true });
    await updater.checkForUpdate({ userInitiated: true });
    return { ok: true };
  });

  // 测试触发：Ctrl+Alt+W（Cmd+Alt+W on mac）立即弹一次，便于验证
  globalShortcut.register('CommandOrControl+Alt+W', () => {
    if (scheduler) scheduler.triggerNow();
  });

  // 切换宠物窗显示 / 隐藏（托盘 / 快捷键用）
  const togglePet = () => {
    const win = ensurePetWindow();
    if (win.isVisible()) {
      win.hide();
    } else {
      win.show();
      // 隐藏期间可能被别的新置顶窗口超过，重新显示时立刻抬回顶层
      if (petGuard) petGuard.resume();
    }
    // 刷新 tooltip（带上「已隐藏」标记）
    setTrayStatus();
  };

  // 菜单栏托盘：提供可见图标 + 检查更新 + 退出入口
  createTray({
    togglePet,
    openSettings: () => openSettings(),
    checkUpdate: () => {
      app.focus({ steal: true });
      updater.checkForUpdate({ userInitiated: true });
    },
    quit: () => app.quit(),
    version: info.currentVersion(),
    // 菜单文案 / tooltip 要反映实时显隐状态
    isPetVisible: () => Boolean(petWindow && !petWindow.isDestroyed() && petWindow.isVisible()),
    // 原生菜单弹出时先让两层，否则 Windows 上宠物会被抬到菜单上面
    onMenuOpen: () => petGuard && petGuard.pause(10000),
  });

  // 全局快捷键：宠物隐藏 / 被挡住时的兵家必争逃生口（托盘图标在 Win11 会折进隐藏区）
  globalShortcut.register('CommandOrControl+Alt+P', togglePet);

  // 仅测试用：PET_TEST_REMINDER=1 时启动 2 秒后自动弹一次提醒
  if (process.env.PET_TEST_REMINDER === '1') {
    setTimeout(() => scheduler && scheduler.triggerNow(), 2000);
  }

  // 仅测试用：PET_TEST_SETTINGS=1 时启动 2.5 秒后自动打开设置面板
  if (process.env.PET_TEST_SETTINGS === '1') {
    setTimeout(() => openSettingsWindow(), 2500);
  }

  // 仅测试用：PET_TEST_UPDATE=1 时启动 3 秒后立刻检查更新（跳过 30 秒首检等待）
  if (process.env.PET_TEST_UPDATE === '1') {
    setTimeout(() => updater && updater.checkForUpdate({ userInitiated: true }), 3000);
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      ensurePetWindow();
    }
  });
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
  if (petGuard) petGuard.stop();
  if (scheduler) scheduler.stop();
  if (heartbeat) heartbeat.stop();
  if (updater) updater.stop();
});

// 非 macOS：所有窗口关闭即退出。macOS 保持常驻（后续接托盘控制）
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});
