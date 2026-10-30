// src/main/reminder-window.js
// 喝水提醒弹窗：居中、无边框、透明的独立小窗
// 对标 mac 版 HTMLAlertWindow.show(...)——提醒用单独窗口，宠物窗本身保持小尺寸
'use strict';

const path = require('path');
const { BrowserWindow } = require('electron');

let reminderWin = null;

function openReminderWindow() {
  if (reminderWin && !reminderWin.isDestroyed()) {
    reminderWin.focus();
    return reminderWin;
  }

  reminderWin = new BrowserWindow({
    width: 380,
    height: 300,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    hasShadow: false,
    center: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, '..', 'renderer', 'reminder-preload.js'),
    },
  });

  reminderWin.setAlwaysOnTop(true, 'screen-saver');
  reminderWin.loadFile(path.join(__dirname, '..', 'renderer', 'reminder.html'));
  reminderWin.on('closed', () => { reminderWin = null; });
  return reminderWin;
}

function closeReminderWindow() {
  if (reminderWin && !reminderWin.isDestroyed()) {
    reminderWin.close();
  }
  reminderWin = null;
}

module.exports = { openReminderWindow, closeReminderWindow };
