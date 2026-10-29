// src/main/index.js
// DesktopPetElectron — 主进程入口
// 职责：应用生命周期 + 创建宠物窗口 + 喝水提醒调度 + 心跳上报 + 自动更新 + IPC
'use strict';

const { app, BrowserWindow, ipcMain, globalShortcut } = require('electron');
const { createPetWindow } = require('./pet-window');
const { openReminderWindow, closeReminderWindow } = require('./reminder-window');
const { ReminderScheduler } = require('./reminder-scheduler');
const { createTray, setTrayStatus } = require('./tray');
const { HeartbeatService } = require('./heartbeat');
const { UpdateService } = require('./update-service');
const info = require('./app-info');
const config = require('./config-store');

let petWindow = null;
let scheduler = null;
let heartbeat = null;
let updater = null;

// 宠物当前状态：目前只有 focus 帧循环（P1 状态机上线后由渲染层回传）
let petState = 'focus';

// 向渲染进程发送事件（窗口存在才发）
function sendToRenderer(channel) {
  if (petWindow && !petWindow.isDestroyed()) {
    petWindow.webContents.send(channel);
  }
}

// 触发一次喝水提醒：弹出提醒窗 + 专注动画从头播放（提醒已合并进专注，不再有独立 warn 动画）
function fireReminder() {
  openReminderWindow();
  sendToRenderer('drink-water:show');
}

// 更新流程的托盘提示：检查中/下载中/安装中都有反馈，结束后恢复默认文案
function onUpdateStatus(status) {
  if (!status) return;
  if (status.phase === 'checking') setTrayStatus('正在检查更新…');
  else if (status.phase === 'downloading') setTrayStatus(`正在下载 ${status.version || '更新'} ${status.percent || 0}%`);
  else if (status.phase === 'ready') setTrayStatus(`更新已下载，准备安装 ${status.version || ''}`.trim());
  else if (status.phase === 'installing') setTrayStatus('正在安装更新，宠物马上回来…');
  else setTrayStatus(`桌面宠物 ${info.currentVersion()}`);
}

app.whenReady().then(() => {
  petWindow = createPetWindow();

  // 喝水提醒：从持久化配置读取间隔，启动调度器
  scheduler = new ReminderScheduler({
    getIntervalMinutes: () => config.get('drinkWaterInterval'),
    send: fireReminder,
  });
  scheduler.start();

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

  // 测试触发：Ctrl+Alt+W（Cmd+Alt+W on mac）立即弹一次，便于验证
  globalShortcut.register('CommandOrControl+Alt+W', () => {
    if (scheduler) scheduler.triggerNow();
  });

  // 切换宠物窗显示 / 隐藏（托盘用）
  const togglePet = () => {
    if (!petWindow || petWindow.isDestroyed()) {
      petWindow = createPetWindow();
      return;
    }
    if (petWindow.isVisible()) petWindow.hide();
    else petWindow.show();
  };

  // 菜单栏托盘：提供可见图标 + 检查更新 + 退出入口
  createTray({
    togglePet,
    checkUpdate: () => {
      app.focus({ steal: true });
      updater.checkForUpdate({ userInitiated: true });
    },
    quit: () => app.quit(),
    version: info.currentVersion(),
  });

  // 仅测试用：PET_TEST_REMINDER=1 时启动 2 秒后自动弹一次提醒
  if (process.env.PET_TEST_REMINDER === '1') {
    setTimeout(() => scheduler && scheduler.triggerNow(), 2000);
  }

  // 仅测试用：PET_TEST_UPDATE=1 时启动 3 秒后立刻检查更新（跳过 30 秒首检等待）
  if (process.env.PET_TEST_UPDATE === '1') {
    setTimeout(() => updater && updater.checkForUpdate({ userInitiated: true }), 3000);
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      petWindow = createPetWindow();
    }
  });
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
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
