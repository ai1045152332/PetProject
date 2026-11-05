// src/main/card-window.js
// DesktopPetElectron — 无边框透明卡片窗工厂（新闻 / 天气等结果卡共用）
// 对标 mac 版 HTMLAlertWindow.show / showResizable：同类窗口单例复用，已开着只前置刷新内容
// 不逐窗复制 BrowserWindow 参数，统一在这里定义（与 todo-window 同风格层级）
'use strict';

const path = require('path');
const { BrowserWindow } = require('electron');

/**
 * 创建一个可复用的卡片窗管理器。
 * @param {object} opts
 * @param {string} opts.name        窗口名（日志用）
 * @param {string} opts.title       窗口标题
 * @param {number} opts.width       宽度
 * @param {number} opts.height      高度
 * @param {string} opts.htmlFile    renderer 下的页面文件名
 * @param {string} opts.preloadFile renderer 下的 preload 文件名
 * @param {string} opts.updateChannel 内容更新 IPC 通道（复用窗口时 send 新内容）
 * @returns {{open: (payload: any) => BrowserWindow, close: () => void, isOpen: () => boolean, getWindow: () => BrowserWindow|null}}
 */
function createCardWindow(opts) {
  const { name, title, width, height, htmlFile, preloadFile, updateChannel } = opts;
  let win = null;

  return {
    /** 打开（或复用）卡片窗；payload 存下来供渲染层加载完 invoke 拉取（避开时序问题） */
    open(payload) {
      if (win && !win.isDestroyed()) {
        win.show();
        win.focus();
        win.webContents.send(updateChannel, payload);
        return win;
      }

      win = new BrowserWindow({
        width,
        height,
        frame: false,
        transparent: true,
        // 底板交给渲染层画（.card），显式全透明：只给 transparent 会留默认底色，外边距透不出桌面
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
        title,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          preload: path.join(__dirname, '..', '..', 'renderer', preloadFile),
        },
      });
      win.__cardPayload = payload;

      // 与 Todo / 提醒窗同层级（screen-saver）：结果卡要浮在普通应用窗口之上
      win.setAlwaysOnTop(true, 'screen-saver');
      win.loadFile(path.join(__dirname, '..', '..', 'renderer', htmlFile));
      win.once('ready-to-show', () => {
        if (win && !win.isDestroyed()) win.show();
      });
      win.on('closed', () => {
        win = null;
        console.log(`[${name}] 卡片窗已关闭`);
      });
      return win;
    },

    close() {
      if (win && !win.isDestroyed()) win.close();
      win = null;
    },

    isOpen() {
      return Boolean(win && !win.isDestroyed());
    },

    /** 当前窗口句柄（index.js 的 yieldTopTo 需要在 open 之外再挂 closed 钩子时用） */
    getWindow() {
      return win && !win.isDestroyed() ? win : null;
    },
  };
}

module.exports = { createCardWindow };
