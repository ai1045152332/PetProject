// src/main/todo-window.js
// Todo 清单窗口：无边框透明卡片窗（与设置面板 / 提醒窗同风格），单例复用
// 对标 mac 版 HTMLAlertWindow.showTodo：已有可见窗口时只前置刷新，不再新建（修复「连续打开两个」）
// 窗口高度按待办条数估算（空态即偏大，逐条增高，上限压在屏幕 72% 处避免遮挡）
'use strict';

const path = require('path');
const { BrowserWindow, screen } = require('electron');

const TODO_WIDTH = 440;
const EMPTY_HEIGHT = 560;   // 空态高度（对标 mac 版 todoFinalHeight 的基数）
const PER_ITEM_HEIGHT = 52; // 每多一条待办增高
const MIN_HEIGHT = 420;
const SCREEN_RATIO = 0.72;  // 最高不超过可视区的 72%

/**
 * 按待办条数算窗口高度（纯函数，便于单测）。
 * @param {number} count 待办条数
 * @param {number} [screenHeight] 可视区高度（默认取主屏工作区）
 */
function todoFinalHeight(count, screenHeight) {
  const h = Number(screenHeight)
    || screen.getPrimaryDisplay().workAreaSize.height
    || 900;
  const n = Number.isFinite(count) ? Math.max(0, count) : 0;
  return Math.round(Math.max(MIN_HEIGHT, Math.min(EMPTY_HEIGHT + n * PER_ITEM_HEIGHT, h * SCREEN_RATIO)));
}

let todoWin = null;

/**
 * 打开（或复用）Todo 清单窗口。
 * @param {Array<{id:string,text:string,due:number|null}>} [items] 当前待办（决定初始高度与列表内容）
 * @returns {BrowserWindow}
 */
function openTodoWindow(items = []) {
  if (todoWin && !todoWin.isDestroyed()) {
    todoWin.show();
    todoWin.focus();
    syncTodoWindow(items);
    return todoWin;
  }

  todoWin = new BrowserWindow({
    width: TODO_WIDTH,
    height: todoFinalHeight(items.length),
    frame: false,
    transparent: true,
    // 底板交给渲染层画（todo.css .card），并显式全透明：
    // 只给 transparent: true 时窗口会留一层默认底色，外边距透不出桌面
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
    title: 'Todo 清单',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, '..', '..', 'renderer', 'todo-preload.js'),
    },
  });

  // 与提醒窗同层级（screen-saver）：清单要像 mac 版那样浮在普通应用窗口之上，
  // 否则双击宠物后可能被 IDE / 浏览器盖住，看起来像「点了没反应」。
  // 宠物窗也是这一层，靠 index.js 的 yieldTopTo 暂停置顶守护来让位。
  todoWin.setAlwaysOnTop(true, 'screen-saver');
  todoWin.loadFile(path.join(__dirname, '..', '..', 'renderer', 'todo.html'));
  todoWin.once('ready-to-show', () => {
    // 列表内容不问时序：页面加载完自己 invoke 拉一次（todo:list-fetch），这里只负责显示
    if (todoWin && !todoWin.isDestroyed()) todoWin.show();
  });
  todoWin.on('closed', () => { todoWin = null; });
  return todoWin;
}

/** 把最新待办推给窗口并按条数调整高度（增删后由主进程统一回灌，渲染层不自己改状态） */
function syncTodoWindow(items = []) {
  if (!todoWin || todoWin.isDestroyed()) return;
  // 多屏时按窗口所在屏的可视区封顶，避免拖到小屏后高度超出
  const areaH = screen.getDisplayMatching(todoWin.getBounds()).workAreaSize.height;
  const nextH = todoFinalHeight(items.length, areaH);
  const [, currentH] = todoWin.getSize();
  if (nextH !== currentH) todoWin.setSize(TODO_WIDTH, nextH);
  todoWin.webContents.send('todo:list', items);
}

function closeTodoWindow() {
  if (todoWin && !todoWin.isDestroyed()) todoWin.close();
  todoWin = null;
}

function isTodoOpen() {
  return Boolean(todoWin && !todoWin.isDestroyed());
}

module.exports = {
  openTodoWindow,
  syncTodoWindow,
  closeTodoWindow,
  isTodoOpen,
  todoFinalHeight,
  TODO_WIDTH,
};
