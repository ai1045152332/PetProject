// src/main/context-menu-prefs.js
// 右键菜单项展示开关（对齐 mac 版 ContextMenuPrefs，FloatingWindow.swift）
// 菜单项文案统一在这里维护，宠物右键菜单与设置面板「菜单设置」区共用同一份定义，
// 不会出现两边标题不一致的情况。
// 与 mac 版的差异：mac 版 items 里的「喂猫条 🍡 / 背单词 📚 / 苦练基本功 🧩 / 输入股票代码查询 📈」
// 依赖尚未移植的服务（路线图 P4/P5），本版不收录，能力就绪后再往 ITEMS 里加即可，
// 设置面板会自动多出一行勾选项，不需要改面板代码。
// 「关闭 ❌」「解锁更多功能 🔓」「设置…」是固定项，与 mac 版一样不参与配置。
'use strict';

const config = require('../core/config-store');

// key：持久化标识；title：菜单与面板展示用文案（emoji 一并带上，与 mac 版一致）
const ITEMS = [
  { key: 'pet', title: '抚摸 🐾' },
  { key: 'news', title: '今日热点新闻 📰' },
  { key: 'weather', title: '查看天气 ☀️' },
  { key: 'todo', title: 'Todo 清单 📝' },
  { key: 'hide', title: '躲起来 👀' },
];

/** 默认展示策略：本版全部展示（mac 版仅「苦练基本功」默认关，那项本版还没有） */
function defaultVisible() {
  return true;
}

function prefsKey(key) {
  return `contextMenu.${key}`;
}

/** 某菜单项是否展示：没设置过走默认策略，设置过则读用户选择 */
function isVisible(key) {
  const stored = config.get(prefsKey(key));
  if (stored === undefined || stored === null || stored === '') return defaultVisible(key);
  return Boolean(stored);
}

/** 写入某菜单项的展示开关（即改即生效，下次弹出菜单就应用） */
function setVisible(visible, key) {
  config.set(prefsKey(key), Boolean(visible));
  return isVisible(key);
}

/** 文案查询（菜单构建用，未知 key 原样返回） */
function title(forKey) {
  const found = ITEMS.find((item) => item.key === forKey);
  return found ? found.title : forKey;
}

/** 设置面板「菜单设置」区数据：[{key, title, visible}] */
function panelItems() {
  return ITEMS.map((item) => ({ key: item.key, title: item.title, visible: isVisible(item.key) }));
}

/** 已知 key 白名单（IPC 入参校验，避免往配置里写任意键） */
function isValidKey(key) {
  return ITEMS.some((item) => item.key === key);
}

module.exports = {
  ITEMS,
  isVisible,
  setVisible,
  title,
  panelItems,
  isValidKey,
  defaultVisible,
};
