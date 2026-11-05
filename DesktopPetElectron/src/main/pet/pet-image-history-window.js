// src/main/pet-image-history-window.js
// 本机图片历史窗（移植 mac 版 UI/PetImageHistoryWindow.swift）
// 与 mac 版一致的关键点：
//   · 数据全部来自本机文件，打开面板不走网络（服务端只负责生成与存储）
//   · 顶部按状态筛选，一屏只看一个状态；右侧大图预览 + 应用目标 + 操作按钮
//   · 单击选中看大图、双击直接应用；失败记录成一张 ⚠ 卡片，选中后按钮变「重试生成 / 清除记录」
//   · 删除/重试等本机文件变化后重推清单，窗口不关可连续操作
// 业务（网络、落盘、配额）都在 pet-image-flow，本模块只管窗口与 IPC。
'use strict';

const path = require('path');
const { BrowserWindow, ipcMain, shell } = require('electron');

let win = null;
let ipcRegistered = false;
let api = null;

function snapshot() {
  return api && api.snapshot ? api.snapshot() : { states: [], stateLabels: {}, history: { items: [], failures: [] } };
}

function pushUpdate() {
  if (win && !win.isDestroyed()) win.webContents.send('pet-history:refresh', snapshot());
}

function ensureIpc() {
  if (ipcRegistered) return;
  ipcRegistered = true;
  ipcMain.handle('pet-history:payload', () => snapshot());

  // 应用某张本机图片到某状态（纯本地切清单，文件缺失时存储层会回退默认图）
  ipcMain.handle('pet-history:apply', (event, payload) => {
    const p = payload || {};
    const res = api.applyImage(p.key, p.state);
    pushUpdate();
    return res;
  });

  // 删除一张本机图片（正被选中的状态回退内置默认图）
  ipcMain.handle('pet-history:delete', (event, payload) => {
    const res = api.deleteImage((payload || {}).key);
    pushUpdate();
    return res;
  });

  // 重试某状态的失败生成（走网络，耗时；busy 由 flow 统一管，这里只回结果）
  ipcMain.handle('pet-history:retry', async (event, payload) => {
    const res = await api.retry((payload || {}).state);
    pushUpdate();
    return res;
  });

  ipcMain.handle('pet-history:clear-failure', (event, payload) => {
    const res = api.clearFailure((payload || {}).state);
    pushUpdate();
    return res;
  });

  // 「在文件夹中显示」：mac 版是 revealAction，这里用系统文件管理器选中该文件
  ipcMain.on('pet-history:reveal', (event, payload) => {
    const file = String((payload || {}).file || '');
    if (file) shell.showItemInFolder(file);
  });

  ipcMain.on('pet-history:close', () => closePetImageHistory());
}

/**
 * 注入业务能力（index.js 用 pet-image-flow 回填）。
 * @param {{snapshot: Function, applyImage: Function, deleteImage: Function, retry: Function, clearFailure: Function}} deps
 */
function setPetImageHistoryAPI(deps) {
  api = deps;
  ensureIpc();
}

/**
 * 打开（或复用）历史图片窗。
 * @param {object} [opts]
 * @param {string} [opts.state] 打开时定位的状态（缺省用宠物当前状态，对齐 mac 版 initialState）
 * @returns {BrowserWindow|null}
 */
function openPetImageHistory(opts = {}) {
  if (!api) return null;
  if (api.setHistoryVisible) api.setHistoryVisible(true);
  if (win && !win.isDestroyed()) {
    win.show();
    win.focus();
    pushUpdate();
    return win;
  }

  win = new BrowserWindow({
    // 与 mac 版历史面板同尺寸（820×580：4 列缩略图 + 右侧 232 详情栏）
    width: 820,
    height: 580,
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
    title: '图片历史',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      // 缩略图直接读本机 .img 文件（内容仍是 PNG/GIF 字节），与宠物窗同一套 CSP 放行
      preload: path.join(__dirname, '..', '..', 'renderer', 'pet-history-preload.js'),
    },
  });
  win.setAlwaysOnTop(true, 'screen-saver');
  win.loadFile(path.join(__dirname, '..', '..', 'renderer', 'pet-history.html'));
  win.once('ready-to-show', () => {
    if (win && !win.isDestroyed()) win.show();
    // 首屏带着「打开时定位的状态」下去，渲染层据此选中筛选段与应用目标
    if (win && !win.isDestroyed() && opts.state) {
      win.webContents.send('pet-history:filter', String(opts.state));
    }
  });
  win.on('closed', () => {
    win = null;
    if (api && api.setHistoryVisible) api.setHistoryVisible(false);
  });
  return win;
}

function closePetImageHistory() {
  if (win && !win.isDestroyed()) win.close();
  win = null;
  if (api && api.setHistoryVisible) api.setHistoryVisible(false);
}

function isPetImageHistoryOpen() {
  return Boolean(win && !win.isDestroyed());
}

/** 本机文件变化后把最新清单推回窗口（面板里的上传/生成动作也会用到） */
function refreshPetImageHistory() {
  if (isPetImageHistoryOpen()) pushUpdate();
}

module.exports = {
  setPetImageHistoryAPI,
  openPetImageHistory,
  closePetImageHistory,
  isPetImageHistoryOpen,
  refreshPetImageHistory,
};
