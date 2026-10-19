// src/main/index.js
// DesktopPetElectron — 主进程入口
// 职责：应用生命周期 + 创建宠物窗口 + 喝水提醒调度 + IPC
'use strict';

const { app, BrowserWindow, ipcMain, globalShortcut } = require('electron');
const { createPetWindow } = require('./pet-window');
const { openReminderWindow, closeReminderWindow } = require('./reminder-window');
const { ReminderScheduler } = require('./reminder-scheduler');
const { createTray } = require('./tray');
const config = require('./config-store');

let petWindow = null;
let scheduler = null;

// 向渲染进程发送事件（窗口存在才发）
function sendToRenderer(channel) {
  if (petWindow && !petWindow.isDestroyed()) {
    petWindow.webContents.send(channel);
  }
}

// 触发一次喝水提醒：弹出提醒窗 + 让宠物切到 warn 动画
function fireReminder() {
  openReminderWindow();
  sendToRenderer('drink-water:show');
}

app.whenReady().then(() => {
  petWindow = createPetWindow();

  // 喝水提醒：从持久化配置读取间隔，启动调度器
  scheduler = new ReminderScheduler({
    getIntervalMinutes: () => config.get('drinkWaterInterval'),
    send: fireReminder,
  });
  scheduler.start();

  // 提醒窗关闭按钮 → 收起提醒窗、解除"正在显示"、宠物回到 focus
  ipcMain.on('drink-water:dismiss', () => {
    closeReminderWindow();
    if (scheduler) scheduler.dismiss();
    sendToRenderer('drink-water:reset');
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

  // 菜单栏托盘：提供可见图标 + 退出入口（悬浮窗 skipTaskbar，否则无 Dock 图标无法退出）
  createTray({
    togglePet,
    quit: () => app.quit(),
  });

  // 仅测试用：PET_TEST_REMINDER=1 时启动 2 秒后自动弹一次提醒
  if (process.env.PET_TEST_REMINDER === '1') {
    setTimeout(() => scheduler && scheduler.triggerNow(), 2000);
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
});

// 非 macOS：所有窗口关闭即退出。macOS 保持常驻（后续接托盘控制）
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});
