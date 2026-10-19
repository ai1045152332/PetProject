// src/main/pet-window.js
// 宠物悬浮窗：无边框、透明、置顶、不可缩放、不显示在任务栏
// 对标 mac 版 FloatingPanel：level=.popUpMenu 置顶 + collectionBehavior 跨桌面
'use strict';

const path = require('path');
const { BrowserWindow, screen } = require('electron');

const CAT_WIDTH = 200;
const CAT_HEIGHT = 200;

function createPetWindow() {
  const { width: screenW, height: screenH } = screen.getPrimaryDisplay().workAreaSize;

  const win = new BrowserWindow({
    width: CAT_WIDTH,
    height: CAT_HEIGHT,
    // 初始放在右下角，距边缘 40px
    x: screenW - CAT_WIDTH - 40,
    y: screenH - CAT_HEIGHT - 40,
    frame: false,               // 无边框
    transparent: true,          // 透明背景，只显示小猫本身
    resizable: false,
    hasShadow: false,           // 去掉窗口阴影
    skipTaskbar: true,          // 不在任务栏 / Dock 显示
    alwaysOnTop: true,          // 始终置顶
    fullscreenable: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, '..', 'renderer', 'preload.js'),
    },
  });

  // 提升置顶层级：screen-saver 在 mac/Windows 上都能压在普通窗口之上
  win.setAlwaysOnTop(true, 'screen-saver');
  // 跨所有工作区 / 全屏空间可见（对标 mac collectionBehavior.canJoinAllSpaces）
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));

  // P0 调试用：需要看渲染层日志时取消注释
  // win.webContents.openDevTools({ mode: 'detach' });

  return win;
}

module.exports = { createPetWindow, CAT_WIDTH, CAT_HEIGHT };
