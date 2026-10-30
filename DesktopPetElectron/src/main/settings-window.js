// src/main/settings-window.js
// 设置面板窗口：无边框透明小窗（与提醒窗同风格），单例复用
// 对标 mac 版 SettingsPanel 的「提醒设置 → 喝水提醒」分区
'use strict';

const path = require('path');
const { BrowserWindow } = require('electron');

let settingsWin = null;

/**
 * 打开设置面板；已打开时仅前置，不重复创建。
 * @returns {BrowserWindow}
 */
function openSettingsWindow() {
  if (settingsWin && !settingsWin.isDestroyed()) {
    if (settingsWin.isMinimized()) settingsWin.restore();
    settingsWin.show();
    settingsWin.focus();
    return settingsWin;
  }

  settingsWin = new BrowserWindow({
    // 与 mac 版 SettingsPanel 一致：720×500（左侧 158px 一级菜单 + 右侧内容区）
    width: 720,
    height: 500,
    frame: false,
    transparent: true,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    hasShadow: false,
    center: true,
    show: false,
    title: '设置',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, '..', 'renderer', 'settings-preload.js'),
    },
  });

  settingsWin.loadFile(path.join(__dirname, '..', 'renderer', 'settings.html'));
  settingsWin.once('ready-to-show', () => settingsWin.show());
  settingsWin.on('closed', () => { settingsWin = null; });
  return settingsWin;
}

function closeSettingsWindow() {
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.close();
  settingsWin = null;
}

function isSettingsOpen() {
  return Boolean(settingsWin && !settingsWin.isDestroyed());
}

module.exports = { openSettingsWindow, closeSettingsWindow, isSettingsOpen };
