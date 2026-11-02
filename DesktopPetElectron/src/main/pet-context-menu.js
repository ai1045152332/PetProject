// src/main/pet-context-menu.js
// 宠物右键菜单（路线图 P3）：照抄 Swift 版 CatView.rightMouseDown 的菜单结构，
// 本版只收录能力已就绪的项：抚摸 🐾（切 pet 帧）/ Todo 清单 📝（本地待办）/ 关闭 ❌。
// 与 Swift 版一致：显隐、设置、检查更新都不在右键菜单（Swift 右键也没有这几项，入口在菜单栏托盘；
// 其右键里的「躲起来」是贴边藏，与显隐无关，属 P4/P5 未移植能力）。
// 喂猫条、躲起来、背单词、新闻、天气、股票、权限置灰等依赖未移植的服务（P4/P5），后续再加。
'use strict';

const { Menu } = require('electron');

/** 构建菜单模板（纯数据，便于 node 直跑测试断言）
 * d.trayFallback=true（仅 Windows 传）时补上显隐/设置/检查更新三个托盘入口：
 * Win11 会把托盘图标默认折进通知区溢出面板，而宠物窗 skipTaskbar 不占任务栏，
 * 用户一旦找不到托盘就没有任何控制入口，故在始终可见的宠物右键菜单上兜底。
 * mac 不传该标志——菜单栏常驻可见，无需兜底，保持与 Swift 版一致只放托盘。 */
function buildTemplate(d = {}) {
  const items = [
    { label: '抚摸 🐾', click: () => d.pet && d.pet() },
    // Todo 为本地能力（userData 持久化，不依赖服务端），位置与 Swift 版菜单顺序对齐
    { label: 'Todo 清单 📝', click: () => d.openTodo && d.openTodo() },
  ];
  if (d.trayFallback) {
    const visible = d.isPetVisible ? Boolean(d.isPetVisible()) : true;
    items.push(
      { label: visible ? '隐藏宠物' : '显示宠物', click: () => d.togglePet && d.togglePet() },
      { label: '设置…', click: () => d.openSettings && d.openSettings() },
      { label: `检查更新${d.version ? `（当前 ${d.version}）` : ''}`, click: () => d.checkUpdate && d.checkUpdate() },
    );
  }
  items.push({ type: 'separator' });
  items.push({ label: '关闭 ❌', click: () => d.quit && d.quit() });
  return items;
}

/**
 * 在宠物窗上弹出右键菜单。
 * 弹出前先让宠物让出置顶层级（Windows 上原生菜单否则会被 screen-saver 层压住），
 * 菜单关闭（menu-will-close）后再收回层级。
 * @param {import('electron').BrowserWindow} win
 * @param {object} deps 见 buildTemplate；另加 onMenuOpen / onMenuClose 层级让位钩子
 */
function popupPetContextMenu(win, deps = {}) {
  const menu = Menu.buildFromTemplate(buildTemplate(deps));
  if (deps.onMenuOpen) deps.onMenuOpen();
  if (deps.onMenuClose) menu.once('menu-will-close', () => deps.onMenuClose());
  menu.popup({ window: win });
  return menu;
}

/**
 * 右键「抚摸」一次性播放器：对标 Swift 版 PetViewModel.playOneShot(.pet)——
 * 播完一圈（帧数/FPS）再 hold 一会儿后回到原状态，不像设置面板那样永久切形象。
 * 期间状态被手动改走（如设置面板切形象）则不强行回弹。
 * @param {object} deps
 * @param {() => string} deps.getState   当前宠物状态
 * @param {(state: string) => void} deps.setState 切换宠物状态
 * @param {number} [deps.frames] 一圈帧数（由主进程枚举 assets/Sprites/pet 得到，共用 mac 素材后为 24；默认 8 仅兜底）
 * @param {number} [deps.fps] 渲染层帧率（pet.js 为 12）
 * @param {number} [deps.holdMs] 播完后保持时长（mac 版 playOneShot hold = 1500ms）
 * @param {Function} [deps.setTimer] 可注入定时器（单测用）
 * @param {Function} [deps.clearTimer] 可注入取消定时器（单测用）
 * @returns {{play: () => void, cancel: () => void}}
 */
function createPettingOneShot({ getState, setState, frames = 8, fps = 12, holdMs = 1500, setTimer = setTimeout, clearTimer = clearTimeout }) {
  let timer = null;
  return {
    play() {
      // 已经在抚摸循环里（上次回弹前又点了一次）：回退目标兜底为休闲
      const prev = getState() === 'pet' ? 'idel' : getState();
      setState('pet');
      if (timer) clearTimer(timer);
      timer = setTimer(() => {
        timer = null;
        if (getState() === 'pet') setState(prev);
      }, Math.round((frames / fps) * 1000) + holdMs);
    },
    cancel() {
      if (timer) {
        clearTimer(timer);
        timer = null;
      }
    },
  };
}

module.exports = { buildTemplate, popupPetContextMenu, createPettingOneShot };
