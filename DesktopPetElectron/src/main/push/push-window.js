// src/main/push-window.js
// 运营推送卡（文字 / 视频）：复用卡片窗工厂，单例复用；视频窗更大、文字窗矮一些。
// 内容由服务端随心跳下发（kind=text/video），这里只负责开窗与 sizing。
'use strict';

const { ipcMain, shell } = require('electron');
const { createCardWindow } = require('./card-window');

const TEXT_SIZE = { width: 460, height: 380 };
const VIDEO_SIZE = { width: 720, height: 520 };

// 视频推送伪装成 Safari 再发请求：不少 CDN / 反爬网关（media.w3.org 就在内）会把
// 带 Electron/Chrome 标识的 UA 直接判 403 返回 HTML，<video> 拿到 HTML 就报
// MEDIA_ELEMENT_ERROR: Format error，界面只剩黑块。只影响本卡片窗，不动全局 UA。
const VIDEO_USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
  + 'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';

let card = null;
let ipcRegistered = false;

function ensureCard() {
  if (!card) {
    card = createCardWindow({
      name: 'push',
      title: '通知',
      width: TEXT_SIZE.width,
      height: TEXT_SIZE.height,
      htmlFile: 'push.html',
      preloadFile: 'push-preload.js',
      updateChannel: 'push:update',
    });
  }
  return card;
}

/** 注册 IPC（幂等；index.js 启动时调一次） */
function registerPushIpc() {
  if (ipcRegistered) return;
  ipcRegistered = true;
  ipcMain.handle('push:payload', () => {
    const win = ensureCard().getWindow();
    return (win && win.__cardPayload) || null;
  });
  ipcMain.on('push:dismiss', () => ensureCard().close());
  // 视频拉不下来时给条退路：用系统浏览器播（与新闻外链同样的处理方式，只放行 http/https）
  ipcMain.on('push:open-external', (event, url) => {
    if (/^https?:\/\//i.test(String(url || ''))) shell.openExternal(url);
  });
}

/**
 * 展示一条推送卡。
 * @param {{kind: string, title?: string, text?: string, url?: string, durationMs?: number}} payload
 * @returns {import('electron').BrowserWindow|null}
 */
function showPush(payload) {
  registerPushIpc();
  const win = ensureCard().open(payload);
  if (!win || win.isDestroyed()) return null;
  const video = payload && payload.kind === 'video';
  if (video) win.webContents.setUserAgent(VIDEO_USER_AGENT);
  const size = video ? VIDEO_SIZE : TEXT_SIZE;
  win.setSize(size.width, size.height);
  win.center();
  return win;
}

function closePush() {
  if (card) card.close();
}

module.exports = { registerPushIpc, showPush, closePush };
