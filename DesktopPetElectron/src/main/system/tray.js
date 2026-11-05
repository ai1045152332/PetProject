// src/main/tray.js
// 菜单栏 / 系统托盘：提供可见图标 + 右键菜单（显示隐藏 / 检查更新 / 退出）
// 解决悬浮小猫 skipTaskbar 后无退出入口的问题，并提供手动触发更新检查的入口
//
// 平台差异：
// - 统一行为：click / right-click 都弹菜单，显隐走菜单项「隐藏宠物/显示宠物」。
//   （Windows 曾是左键单击直接切换显隐，容易误点「猫没了」，已改为与 mac 一致的弹菜单。）
// - Windows 不预设 setContextMenu：显式走 popUpContextMenu，单击/右键都先经过
//   onMenuOpen 让置顶守护让位，避免宠物窗压在菜单上面。
'use strict';

const path = require('path');
const { Tray, Menu, app, nativeImage } = require('electron');
const { MetricBarImage } = require('./metric-bar-image');

// 菜单栏图标：所有托盘/菜单栏素材只存一份，统一放仓库根的 SharedAssets/
// （DesktopPetElectron/assets/ 与 DesktopPetForMacApp/.../Resources/ 下全部是指向它的软链）
// 必须缩放：Electron 把位图尺寸直接当作点尺寸，360×348 原图不缩放会被当成巨图而不显示；
// 注意 resize() 是返回新图、不改原对象，必须接住返回值。
// Windows 例外：系统没有模板图反色机制，用预先描好边的白猫静态图 SharedAssets/WindowsTray.png
// （同源图一次性导出，尺寸已是托盘所需的 32/64，运行时不再缩放；换源图时需重新导出这两张）。
const ICON_PATH = path.join(__dirname, '..', '..', '..', 'assets', 'MenuBarIcon.png');
const WIN_ICON_PATH = path.join(__dirname, '..', '..', '..', 'assets', 'WindowsTray.png');
const MAC_ICON_SIZE = 22;

let tray = null;
// 创建时的依赖快照，供 tooltip / 菜单按需读取实时状态
let deps = null;
// 菜单打开期间的实时刷新定时器（Windows 菜单内数值；mac 仅吃顶栏标题回调）
let menuRefreshTimer = null;

function startMenuRefreshTimer() {
  stopMenuRefreshTimer();
  menuRefreshTimer = setInterval(refreshOpenMenu, 1000);
}

function stopMenuRefreshTimer() {
  if (menuRefreshTimer) {
    clearInterval(menuRefreshTimer);
    menuRefreshTimer = null;
  }
}

/** 菜单栏 / 托盘图标：mac 用共享原图缩到 22pt + 模板图，Windows 用预描边静态图 */
function trayIcon() {
  if (process.platform !== 'darwin') {
    // Windows：createFromPath 会自动拾同名 @2x 高分屏版
    return nativeImage.createFromPath(WIN_ICON_PATH);
  }
  const image = nativeImage.createFromPath(ICON_PATH)
    .resize({ width: MAC_ICON_SIZE, height: MAC_ICON_SIZE });
  // 模板图：系统按菜单栏深浅色自动反色，与 Swift 版同一条渲染路径
  image.setTemplateImage(true);
  return image;
}

// mac 顶栏合成图（猫 + SF Symbol 瓦片 + 数字）：懒建，素材缺失/校验不过时 imageFor 返回 null
let barImage = null;
let barImageTried = false;
let usingComposed = false; // 当前 setImage 是不是合成图（退回时要把猫图标换回去）

/** 有 parts 才拼，拼不出（非 mac / 缺瓦片 / 缺字形）返回 null 走 Unicode 文字回落 */
function composedTrayImage(parts) {
  if (!parts || !parts.length) return null;
  try {
    if (!barImageTried) {
      barImageTried = true;
      barImage = new MetricBarImage({});
    }
    return barImage ? barImage.imageFor(parts) : null;
  } catch (e) {
    // 任何异常（如 electron 模块不完整）都不能影响顶栏，回到纯文字标题
    console.warn('[tray] 顶栏合成图不可用:', e.message);
    barImageTried = true;
    barImage = null;
    return null;
  }
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

/** 构建菜单模板（纯数据，便于 node 直跑测试断言；每次打开前重建，文案与当前状态一致） */
function buildMenuTemplate(d = {}) {
  // 最上面：系统信息二级菜单（对标 Swift setupStatusBar：指标条目可点击勾选→显示在顶栏，
  // CPU/内存下方各一条只读展示行，替代 mac 版的环形图自定义 view）。
  // 模板由 buildSysInfoTemplate 从 worker 投喂的缓存拼装，此处不同步 spawn、不卡主进程
  const sysInfoTemplate = d.buildSysInfoTemplate
    ? [{ label: '系统信息', submenu: d.buildSysInfoTemplate() }]
    : [];
  return [
    ...sysInfoTemplate,
    { label: toggleLabel(), click: () => d.togglePet && d.togglePet() },
    { label: '设置…', click: () => d.openSettings && d.openSettings() },
    { type: 'separator' },
    { label: `检查更新${versionLabel(d)}`, click: () => d.checkUpdate && d.checkUpdate() },
    { type: 'separator' },
    { label: '退出', accelerator: 'CmdOrCtrl+Q', click: () => d.quit && d.quit() },
  ];
}

function versionLabel(d) {
  return d.version ? `（当前 ${d.version}）` : '';
}

function buildMenu() {
  return Menu.buildFromTemplate(buildMenuTemplate(deps || {}));
}

/** 刷新托盘图标旁的顶栏指标（勾选的系统指标；空值清除）。仅 mac 生效，
 *  Windows 通知区图标 setTitle 会把图标替换成文字，丢失可见入口。
 *  优先把整条（猫 + 图标 + 数字）合成一张模板图走 setImage（对齐 Swift 的 SF Symbol 效果），
 *  拼不出才退回 setTitle 纯文字（parts 缺失或瓦片素材不可用）。
 *  退回纯文字时要先把 setImage 换回猫图标，否则上一次的合成图会一直留着。*/
function setTrayTitle(text, parts) {
  if (!tray || process.platform !== 'darwin') return;
  const composed = composedTrayImage(parts);
  if (composed) {
    tray.setImage(composed);
    tray.setTitle('');
    usingComposed = true;
    return;
  }
  if (usingComposed) {
    tray.setImage(trayIcon()); // 取消全部勾选或回落时：把猫图标换回来
    usingComposed = false;
  }
  tray.setTitle(text || '');
}

/** 菜单打开期间每秒重建并回设 contextMenu，让「磁盘 / 网络」数值实时刷新（Windows）。
 *  mac 展开中是 OS modal tracking，回设不会生效也不碰，菜单数值以下次打开为准，
 *  实时性由 SysInfoMonitor 的顶栏标题定时器兼顾 */
function refreshOpenMenu() {
  if (!tray || process.platform !== 'win32') return;
  tray.setContextMenu(buildMenu());
}

/** 弹菜单前先让置顶守护让位，避免宠物窗被抬到菜单上面 */
function popUpMenu() {
  if (deps && deps.onMenuOpen) deps.onMenuOpen();
  if (tray) tray.popUpContextMenu(buildMenu());
}

/** Win11 通知区默认把新图标折进溢出面板，用户看不到托盘入口 → 首次启动弹一次气泡引导。
 * 是否该弹 / 弹后置位由外部（index.js + config-store）通过 deps 决定，tray 不直接碰持久化。
 * displayBalloon 是 Windows 独有 API，非 win / 不支持时静默跳过，绝不影响启动主流程。 */
function showWinTrayHintIfNeeded() {
  if (process.platform !== 'win32' || !tray) return;
  if (deps && deps.shouldShowTrayHint && !deps.shouldShowTrayHint()) return;
  try {
    tray.displayBalloon({
      title: '桌面宠物已在系统托盘运行',
      content: 'Win11 会把托盘图标折进通知区的「^」溢出面板：点任务栏右下角 ^ 找到小猫图标，'
        + '长按拖到任务栏即可固定。单击/右键图标都会打开菜单，显隐在菜单里选。'
        + '也可直接右键桌面上的宠物打开菜单。',
      iconType: 'info',
    });
  } catch (e) {
    // 某些系统状态不支持气泡通知，忽略即可
  }
  if (deps && deps.onTrayHintShown) deps.onTrayHintShown();
}

/**
 * 创建系统托盘。
 * @param {object} handlers
 * @param {() => void} handlers.togglePet     显示 / 隐藏宠物窗（菜单项 / 快捷键用）
 * @param {() => void} handlers.openSettings  打开设置面板
 * @param {() => void} handlers.checkUpdate   手动检查更新
 * @param {() => void} handlers.quit          退出应用
 * @param {string} [handlers.version]         当前版本号（展示在菜单里，如 v0.0.1）
 * @param {() => boolean} [handlers.isPetVisible] 宠物窗当前是否可见（决定菜单文案与 tooltip）
 * @param {() => void} [handlers.onMenuOpen]  菜单即将弹出（用于暂停置顶抢层级）
 * @param {() => Array} [handlers.buildSysInfoTemplate] 系统信息二级菜单模板（传入才展示该项）
 */
function createTray(handlers = {}) {
  if (tray) return tray;

  deps = handlers;
  tray = new Tray(trayIcon());
  tray.setToolTip(defaultTooltip());

  // 左键 / 右键都弹菜单，显隐走菜单项（两平台统一；Windows 单击直接切换曾导致
  // 「一点猫就没了」的误操作，不再保留）
  tray.on('click', popUpMenu);
  tray.on('right-click', popUpMenu);
  if (process.platform === 'win32') {
    // Win11 托盘图标常被折进通知区溢出面板 → 首启弹一次气泡引导找回/固定
    showWinTrayHintIfNeeded();
  }

  // 菜单打开期间启动实时刷新（仅 Windows 需要：每秒重建并回设 contextMenu 让菜单内数值实时；
  //  mac 展开中是 OS modal tracking 无法刷新菜单，顶栏标题已由 worker 每秒回传）
  if (deps.buildSysInfoTemplate) {
    tray.on('menu-open', startMenuRefreshTimer);
    tray.on('menu-close', stopMenuRefreshTimer);
  }

  // 应用退出前释放托盘
  app.on('will-quit', () => {
    stopMenuRefreshTimer();
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

module.exports = { createTray, setTrayStatus, setTrayTitle, defaultTooltip, buildMenuTemplate, popUpMenu };
