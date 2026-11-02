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
    // 底板交给渲染层画（settings.css .panel：不透明实色卡片 + 阴影），不开系统 vibrancy：
    // 开了之后 14px 外边距会露出一圈系统材质，和 .panel 自己的描边叠成“两层边框”，
    // 且系统浅色材质上叠 CSS 底板会发灰。
    // backgroundColor 必须显式写成全透明：只给 transparent: true 时窗口仍会留一层默认底色，
    // 外边距透不出桌面，同样会形成那圈“第二层框”。
    backgroundColor: '#00000000',
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
