// tests/pet-context-menu.test.js
// 宠物右键菜单回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：菜单项构成（仅抚摸/关闭，同 Swift 版不含显隐/设置/检查更新）、抚摸触发状态切换、
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
  const template = buildTemplate({
    pet: () => { petted += 1; },
    quit: () => { quit += 1; },
  });

  const labels = template.map((t) => t.label).filter(Boolean);
  check('首项是「抚摸 🐾」（对标 Swift 版 petAction）', labels[0] === '抚摸 🐾');
  check('仅含 抚摸 / 关闭 两项', labels.join('|') === '抚摸 🐾|关闭 ❌');
  check('同 Swift 版不含显隐/设置/检查更新（入口都在菜单栏托盘）', [
    '隐藏宠物', '显示宠物', '设置…',
  ].every((l) => !labels.includes(l)) && !labels.some((l) => l.startsWith('检查更新')));
  check('本版不含未移植能力（喂猫条/躲起来/背单词/新闻/天气/Todo/股票）', [
    '喂猫条 🍡', '躲起来 👀', '背单词 📚', '今日热点新闻 📰', '查看天气 ☀️', 'Todo 清单 📝', '输入股票代码查询 📈',
  ].every((l) => !labels.includes(l)));

  template.find((t) => t.label === '抚摸 🐾').click();
  check('点抚摸触发状态切换回调', petted === 1);
  template.find((t) => t.label === '关闭 ❌').click();
  check('点关闭触发退出', quit === 1);
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
  check('时长 = 8帧@12fps 一圈 + hold 1500ms（对标 mac 版 playOneShot）',
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

if (failed > 0) {
  console.error(`\n右键菜单测试失败 ${failed} 项`);
  process.exit(1);
}
console.log('\n全部通过');
