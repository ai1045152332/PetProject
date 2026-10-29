// src/main/tray.js
// 菜单栏托盘：提供可见图标 + 右键菜单（显示隐藏 / 检查更新 / 退出）
// 解决悬浮小猫 skipTaskbar 后无退出入口的问题，并提供手动触发更新检查的入口
'use strict';

const path = require('path');
const { Tray, Menu, app } = require('electron');

const TRAY_ICON = path.join(__dirname, '..', '..', 'assets', 'TrayIcon.png');

let tray = null;

/**
 * 创建系统托盘。
 * @param {object} handlers
 * @param {() => void} handlers.togglePet     显示 / 隐藏宠物窗
 * @param {() => void} handlers.checkUpdate   手动检查更新
 * @param {() => void} handlers.quit          退出应用
 * @param {string} [handlers.version]         当前版本号（展示在菜单里，如 v0.0.1）
 */
function createTray({ togglePet, checkUpdate, quit, version }) {
  if (tray) return tray;

  tray = new Tray(TRAY_ICON);
  tray.setToolTip(version ? `桌面宠物 ${version}` : '桌面宠物');

  const contextMenu = Menu.buildFromTemplate([
    { label: '显示 / 隐藏宠物', click: () => togglePet && togglePet() },
    { type: 'separator' },
    { label: `检查更新${version ? `（当前 ${version}）` : ''}`, click: () => checkUpdate && checkUpdate() },
    { type: 'separator' },
    { label: '退出', accelerator: 'CmdOrCtrl+Q', click: () => quit && quit() },
  ]);
  tray.setContextMenu(contextMenu);

  // 左键单击也切换显隐（右键仍弹菜单）
  tray.on('click', () => togglePet && togglePet());

  // 应用退出前释放托盘
  app.on('will-quit', () => {
    if (tray) {
      tray.destroy();
      tray = null;
    }
  });

  return tray;
}

/**
 * 更新托盘提示文本，用于展示检查/下载进度。
 * @param {string} [text] 传空则回到默认文案
 */
function setTrayStatus(text) {
  if (!tray) return;
  tray.setToolTip(text || '桌面宠物');
}

module.exports = { createTray, setTrayStatus };
