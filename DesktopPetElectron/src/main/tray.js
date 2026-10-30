// src/main/tray.js
// 菜单栏 / 系统托盘：提供可见图标 + 右键菜单（显示隐藏 / 检查更新 / 退出）
// 解决悬浮小猫 skipTaskbar 后无退出入口的问题，并提供手动触发更新检查的入口
//
// 平台差异（这是「显示/隐藏不好用」的根因）：
// - Windows：setContextMenu 会让「左键单击也弹菜单」，与 click 切换显隐撞在一起，
//   所以 Windows 上不设 contextMenu，改为左键单击切换、右键 popUpContextMenu。
// - macOS：菜单栏习惯是左键直接弹菜单，所以 click / right-click 都弹菜单，
//   显隐走菜单项（避免「弹菜单 + 同时隐藏」的双触发）。
'use strict';

const path = require('path');
const { Tray, Menu, app, nativeImage } = require('electron');

// 菜单栏图标：全部由 assets/MenuBarIcon.png（与 mac 原生版同一张图）派生，见 scripts/make-tray-icons.py
// mac 用单色模板图（系统按深浅色自动反色），Windows 用白猫+描边小图
const ICON_DIR = path.join(__dirname, '..', '..', 'assets', 'tray');

let tray = null;
// 创建时的依赖快照，供 tooltip / 菜单按需读取实时状态
let deps = null;

/** 按平台挑图标：mac 走 @1x/@2x 模板图，其他平台走彩色图 */
function trayIcon() {
  const file = process.platform === 'darwin' ? 'MenuBarTemplate.png' : 'WindowsTray.png';
  const image = nativeImage.createFromPath(path.join(ICON_DIR, file));
  if (process.platform === 'darwin') {
    // 模板图：彩色信息被忽略，只用 alpha 形状，菜单栏切深色时自动变白
    image.setTemplateImage(true);
  }
  return image;
}

/** 默认 tooltip：带上版本号，宠物隐藏时额外标注，避免「宠物没了以为挂了」 */
function defaultTooltip() {
  if (!deps) return '桌面宠物';
  const version = deps.version ? ` ${deps.version}` : '';
  const hidden = deps.isPetVisible && !deps.isPetVisible() ? '（已隐藏）' : '';
  return `桌面宠物${version}${hidden}`;
}

/** 显隐菜单项文案：读实时状态，所以每次弹菜单前重建 */
function toggleLabel() {
  const visible = deps && deps.isPetVisible ? Boolean(deps.isPetVisible()) : true;
  return visible ? '隐藏宠物' : '显示宠物';
}

/** 构建菜单（每次打开时重建，文案与当前状态一致） */
function buildMenu() {
  const d = deps || {};
  const version = d.version ? `（当前 ${d.version}）` : '';
  return Menu.buildFromTemplate([
    { label: toggleLabel(), click: () => d.togglePet && d.togglePet() },
    { label: '设置…', click: () => d.openSettings && d.openSettings() },
    { type: 'separator' },
    { label: `检查更新${version}`, click: () => d.checkUpdate && d.checkUpdate() },
    { type: 'separator' },
    { label: '退出', accelerator: 'CmdOrCtrl+Q', click: () => d.quit && d.quit() },
  ]);
}

/** 弹菜单前先让置顶守护让位，避免宠物窗被抬到菜单上面 */
function popUpMenu() {
  if (deps && deps.onMenuOpen) deps.onMenuOpen();
  if (tray) tray.popUpContextMenu(buildMenu());
}

/**
 * 创建系统托盘。
 * @param {object} handlers
 * @param {() => void} handlers.togglePet     显示 / 隐藏宠物窗
 * @param {() => void} handlers.openSettings  打开设置面板
 * @param {() => void} handlers.checkUpdate   手动检查更新
 * @param {() => void} handlers.quit          退出应用
 * @param {string} [handlers.version]         当前版本号（展示在菜单里，如 v0.0.1）
 * @param {() => boolean} [handlers.isPetVisible] 宠物窗当前是否可见（决定菜单文案与 tooltip）
 * @param {() => void} [handlers.onMenuOpen]  菜单即将弹出（用于暂停置顶抢层级）
 */
function createTray(handlers = {}) {
  if (tray) return tray;

  deps = handlers;
  tray = new Tray(trayIcon());
  tray.setToolTip(defaultTooltip());

  if (process.platform === 'win32') {
    // Windows：左键单击切换显隐，右键弹菜单（setContextMenu 会让左键也弹菜单，禁用）
    tray.on('click', () => deps.togglePet && deps.togglePet());
    tray.on('right-click', popUpMenu);
  } else {
    // macOS：左键 / 右键都弹菜单，显隐走菜单项
    tray.on('click', popUpMenu);
    tray.on('right-click', popUpMenu);
  }

  // 应用退出前释放托盘
  app.on('will-quit', () => {
    if (tray) {
      tray.destroy();
      tray = null;
    }
    deps = null;
  });

  return tray;
}

/**
 * 更新托盘提示文本，用于展示检查/下载进度。
 * @param {string} [text] 传空则回到默认文案（会带当前显隐状态）
 */
function setTrayStatus(text) {
  if (!tray) return;
  tray.setToolTip(text || defaultTooltip());
}

module.exports = { createTray, setTrayStatus, defaultTooltip };
