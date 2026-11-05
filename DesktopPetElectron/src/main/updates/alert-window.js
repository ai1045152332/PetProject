// src/main/alert-window.js
// 提示卡片窗：替换更新链路里的原生 dialog.showMessageBox
// 原生 MessageBox（尤其 Windows）尺寸写死，正文一长右侧就出滚动条，没法自适应；
// 这里复用提醒卡的透明卡片窗形态：渲染层量出内容真实高度上报，窗口高度随内容自适应
'use strict';

const path = require('path');
const { BrowserWindow, ipcMain, screen } = require('electron');

const ALERT_WIDTH = 420;
const ALERT_INITIAL_HEIGHT = 300;
const MIN_ALERT_HEIGHT = 160;
// 上限离工作区底边留 40px：文案再长也保证不顶满屏，极端超长时才需要内部滚动
const MAX_WORKAREA_GAP = 40;

let win = null;
let settle = null;   // 当前提示的 Promise resolver（用户点按钮 / 关窗时兑现）
let payload = null;  // 存下来供渲染层加载完 invoke 拉取（避开加载时序问题）
let ipcRegistered = false;
let currentCancelIndex = 0;

function ensureIpc() {
  if (ipcRegistered) return;
  ipcRegistered = true;
  ipcMain.handle('alert:payload', () => payload);
  ipcMain.handle('alert:button', (event, index) => {
    if (!win || win.isDestroyed() || event.sender !== win.webContents) return;
    dismiss(Number(index));
  });
  // 高度自适应：渲染层渲染完上报内容真实高度，这里钳在 [下限, 工作区上限] 之间调窗
  ipcMain.on('alert:resize', (event, height) => {
    if (!win || win.isDestroyed() || event.sender !== win.webContents) return;
    const n = Math.round(Number(height));
    if (!Number.isFinite(n) || n <= 0) return;
    const area = screen.getDisplayMatching(win.getBounds()).workArea;
    const target = Math.max(MIN_ALERT_HEIGHT, Math.min(area.height - MAX_WORKAREA_GAP, n));
    const [w, h] = win.getSize();
    if (h === target) return;
    win.setSize(w, target);
    // 高度变了重新居中，避免往下长时偏出视觉中心
    win.center();
  });
}

/** 收口：按 index 兑现 Promise 并关窗（重复调用只生效一次） */
function dismiss(index) {
  const done = settle;
  settle = null;
  if (win && !win.isDestroyed()) win.close();
  if (done) done(index);
}

/**
 * 弹提示卡并等待用户选择。
 * @param {object} opts
 * @param {string} opts.title      标题（眉题小标签；与 message 相同时渲染层会隐藏）
 * @param {string} opts.message    正文主句
 * @param {string} [opts.detail]   详细说明（可多行，卡片内独立说明块）
 * @param {string} [opts.icon]     头像 emoji（缺省🐾）
 * @param {string[]} [opts.buttons] 按钮文案，默认单个「好」（对应原 alert 用法）
 * @param {number} [opts.defaultIndex] 回车默认键
 * @param {number} [opts.cancelIndex]  Esc / 异常关闭视为选择该项（默认最后一个按钮）
 * @returns {Promise<number>} 被点的按钮下标
 */
function showAlert({ title = '', message = '', detail = '', icon = '', buttons = ['好'], defaultIndex = 0, cancelIndex = buttons.length - 1 } = {}) {
  ensureIpc();
  // 同一时刻只保留一张卡：旧卡还开着就来新提示，旧卡按取消收口，避免两个 Promise 悬着
  if (win && !win.isDestroyed()) dismiss(cancelIndex);

  currentCancelIndex = Number.isInteger(cancelIndex) ? cancelIndex : 0;
  payload = { title, message, detail, icon, buttons, defaultIndex, cancelIndex: currentCancelIndex };

  return new Promise((resolve) => {
    settle = resolve;
    win = new BrowserWindow({
      width: ALERT_WIDTH,
      height: ALERT_INITIAL_HEIGHT,
      frame: false,
      transparent: true,
      backgroundColor: '#00000000',
      alwaysOnTop: true,
      resizable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      skipTaskbar: true,
      hasShadow: false,
      center: true,
      show: false,
      title: title || '提示',
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        preload: path.join(__dirname, '..', '..', 'renderer', 'alert-preload.js'),
      },
    });
    win.setAlwaysOnTop(true, 'screen-saver');
    win.loadFile(path.join(__dirname, '..', '..', 'renderer', 'alert.html'));
    win.once('ready-to-show', () => {
      if (win && !win.isDestroyed()) win.show();
    });
    win.on('closed', () => {
      win = null;
      // 没走到按钮就关了（Esc 之外的异常路径）：按取消口径收口
      const done = settle;
      settle = null;
      if (done) done(currentCancelIndex);
    });
  });
}

/** 当前提示卡窗口句柄（调试截图钩子用） */
function getAlertWindow() {
  return win && !win.isDestroyed() ? win : null;
}

module.exports = { showAlert, getAlertWindow };
