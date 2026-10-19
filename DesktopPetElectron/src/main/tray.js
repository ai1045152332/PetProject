// src/main/tray.js
// 菜单栏托盘：提供可见图标 + 右键菜单（退出/显示隐藏），解决悬浮小猫 skipTaskbar 后无退出入口的问题
'use strict';

const path = require('path');
const { Tray, Menu, app } = require('electron');

const TRAY_ICON = path.join(__dirname, '..', '..', 'assets', 'TrayIcon.png');

let tray = null;

/**
 * 创建系统托盘。
 * @param {object} handlers
 * @param {() => void} handlers.togglePet   显示 / 隐藏宠物窗
 * @param {() => void} handlers.quit        退出应用
 */
function createTray({ togglePet, quit }) {
  if (tray) return tray;

  tray = new Tray(TRAY_ICON);
  tray.setToolTip('桌面宠物');

  const contextMenu = Menu.buildFromTemplate([
    { label: '显示 / 隐藏宠物', click: () => togglePet && togglePet() },
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

module.exports = { createTray };
