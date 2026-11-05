// src/main/pet-context-menu.js
// 宠物右键菜单（路线图 P3）：照抄 Swift 版 CatView.rightMouseDown 的菜单结构，
// 本版收录能力已就绪的项：抚摸 🐾（切 pet 帧）/ 今日热点新闻 📰 / 查看天气 ☀️ / Todo 清单 📝 /
// 躲起来 👀（贴屏幕侧边探头）/ 设置…（打开设置面板）/ 关闭 ❌。
// 菜单分三栏：其他功能 ｜ 设置 ｜ 关闭（栏间用分隔线隔开）。
// 与 Swift 版一致：右键宠物可直接进设置；显隐、检查更新仍只在菜单栏托盘
// （Windows 走 trayFallback 额外补上这两项）。
// 喂猫条、背单词、股票等仍依赖未移植的服务（P4/P5），后续再加。
'use strict';

const { Menu } = require('electron');

/** 构建菜单模板（纯数据，便于 node 直跑测试断言）
 * 菜单分三栏（栏间分隔线）：其他功能 / 设置 / 关闭。
 * d.openSettings 存在时「设置」栏出「设置…」项（mac/Windows 都在宠物右键菜单里，方便不进托盘也能改配置）。
 * d.trayFallback=true（仅 Windows 传）时在「其他功能」栏补上显隐/检查更新两个托盘入口：
 * Win11 会把托盘图标默认折进通知区溢出面板，而宠物窗 skipTaskbar 不占任务栏，
 * 用户一旦找不到托盘就没有任何控制入口，故在始终可见的宠物右键菜单上兜底。
 * d.menuVisible(key) 返回 false 时该项不进菜单（对齐 mac 版 ContextMenuPrefs 勾选；未传时全部展示），
 * 标题也经 d.menuTitle(key) 取自同一份 prefs，文案只维护一处。
 * d.fullAccess=false（基础权限）时对齐 Swift 版 rightMouseDown：新闻/天气属高级功能（fullOnly，
 * 接口按量付费）置灰并排到可用项之后，「设置」栏尾部追加「解锁更多功能 🔓」引导项。 */
function buildTemplate(d = {}) {
  const fullAccess = d.fullAccess !== undefined ? Boolean(d.fullAccess) : true;
  // 「菜单设置」里被勾掉的项直接不进菜单（固定项不受影响，与 mac 版一致）
  const shown = (key) => (d.menuVisible ? d.menuVisible(key) !== false : true);
  const label = (key, fallback) => (d.menuTitle ? d.menuTitle(key) : fallback);
  // 第 1 栏：其他功能（可用项在前、待解锁项在后，组内保持原顺序）
  const features = [];
  if (d.pet && shown('pet')) features.push({ label: label('pet', '抚摸 🐾'), click: () => d.pet() });
  // Todo / 躲藏为本地能力，不依赖权限，位置与 Swift 版菜单顺序对齐
  if (d.openTodo && shown('todo')) features.push({ label: label('todo', 'Todo 清单 📝'), click: () => d.openTodo() });
  // 躲起来：吸附到最近的屏幕侧边（对齐 mac 版 hideBehindEdge）；未传回调时不出该项
  if (d.hide && shown('hide')) features.push({ label: label('hide', '躲起来 👀'), click: () => d.hide() });
  // 新闻 / 天气：菜单项文案与 mac 版 ContextMenuPrefs.items 对齐，顺序保持 新闻→天气
  if (d.openNews && shown('news')) features.push({ label: label('news', '今日热点新闻 📰'), click: () => d.openNews(), enabled: fullAccess });
  if (d.openWeather && shown('weather')) features.push({ label: label('weather', '查看天气 ☀️'), click: () => d.openWeather(), enabled: fullAccess });
  if (d.trayFallback) {
    const visible = d.isPetVisible ? Boolean(d.isPetVisible()) : true;
    features.push({ label: visible ? '隐藏宠物' : '显示宠物', click: () => d.togglePet && d.togglePet() });
    features.push({ label: `检查更新${d.version ? `（当前 ${d.version}）` : ''}`, click: () => d.checkUpdate && d.checkUpdate() });
  }
  // 第 2 栏：设置（两个平台都在这里开设置面板；解锁引导同属设置入口，排在设置…之后）
  const settings = [];
  if (d.openSettings) settings.push({ label: '设置…', click: () => d.openSettings() });
  if (!fullAccess && d.openAccessSettings) settings.push({ label: '解锁更多功能 🔓', click: () => d.openAccessSettings() });
  // 第 3 栏：关闭
  const quit = [{ label: '关闭 ❌', click: () => d.quit && d.quit() }];
  // 空栏不出分隔线（例如未接线 hide / 未传 openNews 时不留下悬空分隔）
  const groups = [features, settings, quit].filter((group) => group.length > 0);
  return groups.flatMap((group, index) => (index === 0 ? group : [{ type: 'separator' }, ...group]));
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
 * @param {() => string} [deps.getRestoreState] 回弹目标（默认等于进入前状态；
 *        躲藏中抚完要回到躲藏，不能把只探头的猫拉回屏内）
 * @param {number} [deps.frames] 一圈帧数（由主进程枚举 assets/Sprites/pet 得到，共用 mac 素材后为 24；默认 8 仅兜底）
 * @param {number} [deps.fps] 渲染层帧率（pet.js 为 12）
 * @param {number} [deps.holdMs] 播完后保持时长（mac 版 playOneShot hold = 1500ms）
 * @param {Function} [deps.setTimer] 可注入定时器（单测用）
 * @param {Function} [deps.clearTimer] 可注入取消定时器（单测用）
 * @returns {{play: () => void, cancel: () => void, isPlaying: () => boolean}}
 */
function createPettingOneShot({ getState, setState, getRestoreState, frames = 8, fps = 12, holdMs = 1500, setTimer = setTimeout, clearTimer = clearTimeout }) {
  let timer = null;
  return {
    play() {
      // 已经在抚摸循环里（上次回弹前又点了一次）：回退目标兜底为休闲
      const current = getState();
      const prev = current === 'pet' ? 'idel' : current;
      setState('pet');
      if (timer) clearTimer(timer);
      timer = setTimer(() => {
        timer = null;
        // 回弹目标由外部实时决定（躲藏态要留在躲藏，且窗口得收回屏内）
        const target = getRestoreState ? getRestoreState() : prev;
        if (getState() === 'pet') setState(target);
      }, Math.round((frames / fps) * 1000) + holdMs);
    },
    cancel() {
      if (timer) {
        clearTimer(timer);
        timer = null;
      }
    },
    // 一次性动画是否在播（主动搭话据此避让：抚摸中途再冒气泡会打断节奏）
    isPlaying: () => timer !== null,
  };
}

module.exports = { buildTemplate, popupPetContextMenu, createPettingOneShot };
