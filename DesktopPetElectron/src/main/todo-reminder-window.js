// src/main/todo-reminder-window.js
// Todo 到期提醒卡片：居中、无边框、透明的常驻小窗（点 ✕ 才消失）
// 对标 mac 版 HTMLAlertWindow.showTodoReminder：同类通知复用同一窗口，不堆叠
'use strict';

const path = require('path');
const { BrowserWindow, ipcMain } = require('electron');

let reminderWin = null;
// 当前卡片内容：渲染层加载完主动 invoke 拉取（避开「先 send 后挂监听」的时序问题）
let payload = null;
let ipcRegistered = false;

function ensureIpc() {
  if (ipcRegistered) return;
  ipcRegistered = true;
  ipcMain.handle('todo-reminder:payload', () => payload || { title: 'Todo 提醒 ⏰', text: '', subtitle: '' });
  ipcMain.on('todo-reminder:dismiss', () => closeTodoReminderWindow());
}

/**
 * 弹出一张到期提醒卡。
 * @param {{title?: string, text: string, subtitle?: string}} card 卡片内容
 * @returns {BrowserWindow}
 */
function openTodoReminderWindow(card = {}) {
  ensureIpc();
  payload = { title: 'Todo 提醒 ⏰', text: '', subtitle: '', ...card };

  if (reminderWin && !reminderWin.isDestroyed()) {
    reminderWin.show();
    reminderWin.focus();
    reminderWin.webContents.send('todo-reminder:show', payload);
    return reminderWin;
  }

  reminderWin = new BrowserWindow({
    width: 340,
    // 220 → 285：底部多了一枚「✅ 完成」按钮，再给两行待办文本留出余量，避免被卡片底边裁掉
    height: 285,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    hasShadow: false,
    center: true,
    show: false,
    title: 'Todo 提醒',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, '..', 'renderer', 'todo-reminder-preload.js'),
    },
  });

  // 与喝水提醒同层级：到期卡要压在普通窗口之上才提醒得到
  reminderWin.setAlwaysOnTop(true, 'screen-saver');
  reminderWin.loadFile(path.join(__dirname, '..', 'renderer', 'todo-reminder.html'));
  reminderWin.once('ready-to-show', () => {
    if (reminderWin && !reminderWin.isDestroyed()) reminderWin.show();
  });
  reminderWin.on('closed', () => { reminderWin = null; });
  return reminderWin;
}

function closeTodoReminderWindow() {
  if (reminderWin && !reminderWin.isDestroyed()) reminderWin.close();
  reminderWin = null;
}

function isTodoReminderOpen() {
  return Boolean(reminderWin && !reminderWin.isDestroyed());
}

module.exports = { openTodoReminderWindow, closeTodoReminderWindow, isTodoReminderOpen };
