// src/main/friend-request-window.js
// 好友申请卡：居中、无边框、透明的常驻小卡（点「同意 / 拒绝」或 ✕ 才消失）
// 对标 mac 版 HTMLAlertWindow.showFriendRequest：同一时刻只保留一张，避免堆叠
// 服务端在用户做出选择前会持续下发同一条申请，去重由 social-service.markRequestsShown 负责。
'use strict';

const path = require('path');
const { BrowserWindow, ipcMain } = require('electron');

let win = null;
let ipcRegistered = false;
// 当前卡片内容：渲染层加载完主动 invoke 拉取（避开「先 send 后挂监听」的时序问题）
let payload = null;
// 同意 / 拒绝回调（index.js 接 social-service 后回填）
let handlers = { onAccept: null, onReject: null };

function ensureIpc() {
  if (ipcRegistered) return;
  ipcRegistered = true;
  ipcMain.handle('friend-request:payload', () => payload || { title: '好友申请 🐾', display: '' });
  // 做出选择即视为处理完毕：先关卡片再把决定交给主进程（服务端调用失败也不重弹，靠心跳重投兜底）
  ipcMain.on('friend-request:accept', () => {
    const req = payload;
    closeFriendRequestWindow();
    if (handlers.onAccept && req) handlers.onAccept(req);
  });
  ipcMain.on('friend-request:reject', () => {
    const req = payload;
    closeFriendRequestWindow();
    if (handlers.onReject && req) handlers.onReject(req);
  });
  // 只点 ✕：本次不处理，申请仍在服务端挂着，下次进设置面板还能看到
  ipcMain.on('friend-request:dismiss', () => closeFriendRequestWindow());
}

/**
 * 注入「同意 / 拒绝」处理逻辑。
 * @param {{onAccept: (req: object) => void, onReject: (req: object) => void}} deps
 */
function setFriendRequestHandlers(deps = {}) {
  handlers = { onAccept: deps.onAccept || null, onReject: deps.onReject || null };
  ensureIpc();
}

/**
 * 弹出一张好友申请卡。
 * @param {{id?: string, fromPetNo: number, display: string}} req 归一化后的申请
 * @returns {BrowserWindow}
 */
function openFriendRequestCard(req = {}) {
  ensureIpc();
  const display = String(req.display || `宠物 #${req.fromPetNo || 0}`);
  payload = { title: '好友申请 🐾', display, fromPetNo: Number(req.fromPetNo) || 0, id: String(req.id || '') };

  if (win && !win.isDestroyed()) {
    win.show();
    win.focus();
    win.webContents.send('friend-request:show', payload);
    return win;
  }

  win = new BrowserWindow({
    width: 340,
    // 与 mac 版申请卡同高：图标 + 一行申请文案 + 两个按钮 + 一句说明
    height: 250,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    hasShadow: false,
    center: true,
    show: false,
    title: '好友申请',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, '..', '..', 'renderer', 'friend-request-preload.js'),
    },
  });

  // 与到期 Todo / 喝水提醒同层级：申请要压在普通窗口之上才问得到
  win.setAlwaysOnTop(true, 'screen-saver');
  win.loadFile(path.join(__dirname, '..', '..', 'renderer', 'friend-request.html'));
  win.once('ready-to-show', () => {
    if (win && !win.isDestroyed()) win.show();
  });
  win.on('closed', () => { win = null; });
  return win;
}

function closeFriendRequestWindow() {
  if (win && !win.isDestroyed()) win.close();
  win = null;
}

function isFriendRequestOpen() {
  return Boolean(win && !win.isDestroyed());
}

module.exports = {
  setFriendRequestHandlers,
  openFriendRequestCard,
  closeFriendRequestWindow,
  isFriendRequestOpen,
};
