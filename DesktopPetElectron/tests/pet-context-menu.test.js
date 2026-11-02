// tests/pet-context-menu.test.js
// 宠物右键菜单回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：菜单项构成（抚摸 / Todo 清单 / 关闭，其余未移植能力不出现）、抚摸触发状态切换、
//       弹菜单前后让出/收回置顶层
'use strict';

const path = require('path');
const Module = require('module');

const SRC = path.join(__dirname, '..', 'src', 'main');
const MODULE_PATH = path.join(SRC, 'pet-context-menu.js');

const builtMenus = [];

class FakeMenu {
  constructor(template) {
    this.template = template;
    this.popupCalls = [];
    this.closeHandlers = [];
    builtMenus.push(this);
  }

  once(event, fn) {
    if (event === 'menu-will-close') this.closeHandlers.push(fn);
  }

  popup(opts) {
    this.popupCalls.push(opts);
  }

  emitClose() {
    this.closeHandlers.forEach((fn) => fn());
  }
}

// ── mock electron ──
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      Menu: { buildFromTemplate: (template) => new FakeMenu(template) },
    };
  }
  return origLoad.apply(this, arguments);
};

const { buildTemplate, popupPetContextMenu, createPettingOneShot } = require(MODULE_PATH);

let failed = 0;
function check(name, condition) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    console.error(`❌ ${name}`);
    failed += 1;
  }
}

// ── 模板构成：只收录本版已就绪的能力 ──
{
  let petted = 0;
  let quit = 0;
  let todoOpened = 0;
  const template = buildTemplate({
    pet: () => { petted += 1; },
    quit: () => { quit += 1; },
    openTodo: () => { todoOpened += 1; },
  });

  const labels = template.map((t) => t.label).filter(Boolean);
  check('首项是「抚摸 🐾」（对标 Swift 版 petAction）', labels[0] === '抚摸 🐾');
  check('仅含 抚摸 / Todo 清单 / 关闭 三项', labels.join('|') === '抚摸 🐾|Todo 清单 📝|关闭 ❌');
  check('同 Swift 版不含显隐/设置/检查更新（入口都在菜单栏托盘）', [
    '隐藏宠物', '显示宠物', '设置…',
  ].every((l) => !labels.includes(l)) && !labels.some((l) => l.startsWith('检查更新')));
  check('本版不含未移植能力（喂猫条/躲起来/背单词/新闻/天气/股票）', [
    '喂猫条 🍡', '躲起来 👀', '背单词 📚', '今日热点新闻 📰', '查看天气 ☀️', '输入股票代码查询 📈',
  ].every((l) => !labels.includes(l)));

  template.find((t) => t.label === '抚摸 🐾').click();
  check('点抚摸触发状态切换回调', petted === 1);
  template.find((t) => t.label === 'Todo 清单 📝').click();
  check('点 Todo 清单触发开清单回调', todoOpened === 1);
  template.find((t) => t.label === '关闭 ❌').click();
  check('点关闭触发退出', quit === 1);
}

// ── Windows 兜底（trayFallback）：托盘被 Win11 折进溢出面板时，右键菜单补上托盘入口 ──
{
  let toggled = 0, settings = 0, checked = 0;
  const template = buildTemplate({
    pet: () => {}, quit: () => {},
    trayFallback: true,
    isPetVisible: () => true,
    togglePet: () => { toggled += 1; },
    openSettings: () => { settings += 1; },
    checkUpdate: () => { checked += 1; },
  });
  const labels = template.map((t) => t.label).filter(Boolean);
  check('Windows 兜底含显隐/设置/检查更新',
    labels.includes('隐藏宠物') && labels.includes('设置…') && labels.some((l) => l.startsWith('检查更新')));
  check('Windows 兜底仍以「关闭 ❌」收尾', labels[labels.length - 1] === '关闭 ❌');
  template.find((t) => t.label === '隐藏宠物').click();
  template.find((t) => t.label === '设置…').click();
  template.find((t) => t.label.startsWith('检查更新')).click();
  check('Windows 兜底各项点击接通对应回调', toggled === 1 && settings === 1 && checked === 1);

  // 宠物隐藏时文案翻为「显示宠物」
  const hiddenLabels = buildTemplate({ trayFallback: true, isPetVisible: () => false }).map((t) => t.label);
  check('宠物隐藏时兜底项显示「显示宠物」', hiddenLabels.includes('显示宠物'));
}

// ── 弹菜单的层级让位协议：先 pause，菜单关闭后 resume ──
{
  const events = [];
  const fakeWin = { id: 1 };
  const menu = popupPetContextMenu(fakeWin, {
    onMenuOpen: () => events.push('open'),
    onMenuClose: () => events.push('close'),
  });

  check('弹菜单前先让出置顶层', events[0] === 'open');
  check('菜单弹在宠物窗上', menu.popupCalls.length === 1 && menu.popupCalls[0].window === fakeWin);
  check('菜单含「关闭 ❌」项', menu.template.map((t) => t.label).includes('关闭 ❌'));
  check('菜单含「Todo 清单 📝」项', menu.template.map((t) => t.label).includes('Todo 清单 📝'));

  menu.emitClose();
  check('菜单关闭后收回置顶层', events.join(',') === 'open,close');
}

// ── 抚摸一次性播放：对标 Swift playOneShot，播完自动回原状态 ──
{
  let state = 'idel';
  const log = [];
  let due = null;
  const setTimer = (fn, ms) => { due = { fn, ms }; return due; };
  const clearTimer = () => { due = null; };
  const oneShot = createPettingOneShot({
    getState: () => state,
    setState: (s) => { state = s; log.push(s); },
    setTimer,
    clearTimer,
  });

  oneShot.play();
  check('点抚摸先切到 pet', state === 'pet' && log.join(',') === 'pet');
  check('不传 frames 时按 8 帧兜底算时长（8@12fps 一圈 + hold 1500ms）',
    due && due.ms === Math.round((8 / 12) * 1000) + 1500);

  due.fn();
  check('到期自动回到原状态 idel', state === 'idel' && log.join(',') === 'pet,idel');

  // 期间被设置面板手动切走 → 不回弹
  state = 'sleep';
  log.length = 0;
  oneShot.play();
  check('从 sleep 抚摸：先切 pet', state === 'pet');
  state = 'focus'; // 模拟用户在 hold 期间从设置面板切了形象
  due.fn();
  check('期间手动切走则不回弹', state === 'focus' && log.join(',') === 'pet');

  // hold 期间重复点击：上次定时器被接管，回退目标仍对
  state = 'idel';
  oneShot.play();
  const first = due;
  oneShot.play();
  check('重复抚摸重设定时器（前一次已取消）', due !== first && due !== null);
  oneShot.cancel();
  check('cancel 后待回弹定时器被清掉', due !== null ? false : true);
}

// ── 抚摸一圈时长必须跟真实帧数走（共用 mac 素材后 pet 是 24 帧）──
{
  let due = null;
  const oneShot = createPettingOneShot({
    getState: () => 'idel',
    setState: () => {},
    frames: 24,
    setTimer: (fn, ms) => { due = { fn, ms }; return due; },
    clearTimer: () => { due = null; },
  });
  oneShot.play();
  check('帧数 24 时一圈按 24@12fps + hold 算（不按 8 帧提前回弹）',
    due && due.ms === Math.round((24 / 12) * 1000) + 1500);
}

if (failed > 0) {
  console.error(`\n右键菜单测试失败 ${failed} 项`);
  process.exit(1);
}
console.log('\n全部通过');
