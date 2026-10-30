// src/main/pet-window.js
// 宠物悬浮窗：无边框、透明、置顶、不显示在任务栏
// 对标 mac 版 FloatingPanel：level=.popUpMenu 置顶 + collectionBehavior 跨桌面
// 尺寸按「宠物大小」（0.5x ~ 2.0x）缩放，基准 200×200（与精灵图同尺寸）
'use strict';

const path = require('path');
const { BrowserWindow, screen } = require('electron');

const BASE_SIZE = 200;   // 精灵图原始尺寸（assets/Sprites/*/frame_00.png 均为 200×200）
const EDGE_MARGIN = 40;  // 初始位置距屏幕右下角的距离

// 置顶层级：screen-saver 在 mac / Windows 上都压得住普通窗口
const ON_TOP_LEVEL = 'screen-saver';
// Windows 上重新声明置顶的间隔：其它置顶窗口、任务栏重排、全屏切换都会把
// alwaysOnTop 窗口压下去，只设一次不够，必须周期性抬一次
const ON_TOP_INTERVAL = 5000;

/** 按缩放比例换算窗口边长（取整，避免半像素导致帧图发虚） */
function scaledSize(scale) {
  const n = Number(scale);
  const value = Number.isFinite(n) ? Math.min(2, Math.max(0.5, n)) : 1;
  return Math.round(BASE_SIZE * value);
}

/**
 * 把宠物窗抬回桌面最上层（不抢焦点）。
 * Windows 的 SetWindowPos(HWND_TOPMOST) 只保证「进入置顶层」，并不断言「置顶层第一个」，
 * 所以后续任何新的置顶窗口都会盖住它，需要反复抬。
 * @param {BrowserWindow} win
 */
function raisePet(win) {
  if (!win || win.isDestroyed() || !win.isVisible()) return;
  // Windows 上加 relativeLevel，压过其它同样用 screen-saver 的置顶窗口
  if (process.platform === 'win32') win.setAlwaysOnTop(true, ON_TOP_LEVEL, 1);
  else win.setAlwaysOnTop(true, ON_TOP_LEVEL);
}

/**
 * 置顶守护：周期性重新声明置顶，并在窗口失焦 / 重新显示时立刻抬一次。
 * Windows 上其它置顶窗口、任务栏重排、全屏切换都会把窗口压下去；
 * macOS 的 NSWindow level 稳定得多，但其它 app 的浮窗（如 screen-saver 级）也可能越过去，
 * 所以两端都补，mac 拉长间隔减少系统调用。
 * 托盘菜单、设置面板等需要盖在宠物上面的原生窗口，可先 pause() 让出层级。
 * @param {BrowserWindow} win
 * @param {object} [opts]
 * @param {number} [opts.intervalMs] 轮询间隔
 * @param {number} [opts.pauseMs] 默认让出时长
 * @returns {{pause: (ms?: number) => void, resume: () => void, stop: () => void}}
 */
function startOnTopGuard(win, { intervalMs = ON_TOP_INTERVAL, pauseMs = 8000 } = {}) {
  let timer = null;
  let pausedUntil = 0;
  let stopped = false;

  const reassert = () => {
    if (stopped || Date.now() < pausedUntil) return;
    raisePet(win);
  };

  // Windows 更勤（5s），mac 稳定（10s）
  const interval = process.platform === 'win32' ? intervalMs : Math.max(intervalMs, 10000);
  timer = setInterval(reassert, interval);
  if (typeof timer.unref === 'function') timer.unref();
  win.on('show', reassert);
  win.on('blur', reassert);
  win.on('always-on-top-changed', (_event, isOnTop) => {
    if (!isOnTop) reassert();
  });

  return {
    pause(ms = pauseMs) {
      // Infinity 表示「一直让出」，由 resume() 收尾
      pausedUntil = ms === Infinity ? Number.POSITIVE_INFINITY : Date.now() + ms;
    },
    resume() {
      pausedUntil = 0;
      reassert();
    },
    stop() {
      stopped = true;
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
    },
  };
}

/**
 * 创建宠物悬浮窗
 * @param {object} [opts]
 * @param {number} [opts.scale] 宠物大小（0.5~2.0）
 */
function createPetWindow({ scale = 1 } = {}) {
  const size = scaledSize(scale);
  const { width: screenW, height: screenH } = screen.getPrimaryDisplay().workAreaSize;

  const win = new BrowserWindow({
    width: size,
    height: size,
    // 初始放在右下角，距边缘 40px
    x: screenW - size - EDGE_MARGIN,
    y: screenH - size - EDGE_MARGIN,
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
  raisePet(win);
  // 跨所有工作区 / 全屏空间可见（对标 mac collectionBehavior.canJoinAllSpaces）
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));

  // P0 调试用：需要看渲染层日志时取消注释
  // win.webContents.openDevTools({ mode: 'detach' });

  return win;
}

/**
 * 调整宠物大小：以右下角为锚点缩放，避免小猫"跳"到别处；
 * 缩放后若超出所在显示器工作区，就贴边显示（防止放大到 2x 时被挡住看不见）。
 * @param {BrowserWindow} win
 * @param {number} scale 0.5~2.0
 */
function applyPetScale(win, scale) {
  if (!win || win.isDestroyed()) return;
  const size = scaledSize(scale);
  const [x, y] = win.getPosition();
  const [w, h] = win.getSize();
  let nextX = x + w - size;
  let nextY = y + h - size;

  const area = screen.getDisplayMatching({ x: nextX, y: nextY, width: size, height: size }).workArea;
  nextX = Math.min(Math.max(nextX, area.x), area.x + area.width - size);
  nextY = Math.min(Math.max(nextY, area.y), area.y + area.height - size);

  win.setBounds({ x: nextX, y: nextY, width: size, height: size });
}

module.exports = {
  createPetWindow,
  applyPetScale,
  startOnTopGuard,
  raisePet,
  scaledSize,
  BASE_SIZE,
};
