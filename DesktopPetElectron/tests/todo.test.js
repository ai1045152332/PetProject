// tests/todo.test.js
// Todo 功能回归测试：node 直接跑，mock electron app.getPath 到临时 userData
// 覆盖：待办落盘/校验/脏数据回落、到期标记、到期挑选与重复提醒间隔、扫描循环、清单窗口高度估算
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const Module = require('module');

const USER_DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-todo-test-'));

// mock electron：todo-store 只用 app.getPath；todo-window 另外用到 screen
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      app: { getPath: () => USER_DATA },
      BrowserWindow: class { constructor() {} },
      screen: {
        getPrimaryDisplay: () => ({ workAreaSize: { height: 900 } }),
        getDisplayMatching: () => ({ workAreaSize: { height: 900 } }),
      },
    };
  }
  return origLoad.apply(this, arguments);
};

const SRC = path.join(__dirname, '..', 'src', 'main');
const store = require(path.join(SRC, 'todo-store.js'));
const {
  pickDueTodo,
  clampRepeatMinutes,
  formatDueLabel,
  createTodoReminderLoop,
  DEFAULT_REPEAT_MINUTES,
} = require(path.join(SRC, 'todo-reminder.js'));
const { todoFinalHeight } = require(path.join(SRC, 'todo-window.js'));

let failed = 0;
function check(name, cond) {
  if (!cond) failed += 1;
  console.log(`${cond ? '✅' : '❌'} ${name}`);
}

// ── 1. 存储：空表 / 新增 / 落盘位置 ──
check('初始无待办', store.load().length === 0);
let res = store.add('  给植物浇水  ');
check('新增成功', res.ok === true);
check('内容去首尾空格', res.item.text === '给植物浇水');
check('未设提醒时 due 为 null', res.item.due === null);
check('id 非空', Boolean(res.item.id));
check('落盘到 userData/pet-todos.json', fs.existsSync(path.join(USER_DATA, 'pet-todos.json')));
check('重新读取仍是同一条', store.load().length === 1 && store.load()[0].text === '给植物浇水');

// ── 2. 提醒时间归一化 ──
res = store.add('交周报', '1769900000.7');
check('字符串 due 也接受并取整', res.ok === true && res.item.due === 1769900001);
res = store.add('晨跑', 0);
check('due = 0 视为不设提醒', res.ok === true && res.item.due === null);
res = store.add('读书', 'abc');
check('非法 due 视为不设提醒', res.ok === true && res.item.due === null);

// ── 3. 非法输入不动磁盘 ──
const beforeCount = store.load().length;
check('空内容被拒', store.add('   ').ok === false);
check('超长内容被拒', store.add('x'.repeat(store.MAX_TEXT + 1)).ok === false);
check('非法输入不改变条数', store.load().length === beforeCount);

// ── 4. 删除 ──
const delId = store.load()[0].id;
check('删除成功', store.remove(delId).ok === true);
check('删除后条数减一', store.load().length === beforeCount - 1);
check('删不存在的 id 也返回 ok', store.remove('nope').ok === true);
check('删不存在的 id 不改条数', store.load().length === beforeCount - 1);

// ── 5. 到期标记 ──
const dueItem = store.add('取快递', Math.floor(Date.now() / 1000) - 60).item;
check('到期待办写盘 due', store.load().find((i) => i.id === dueItem.id).due > 0);
check('markNotified 落盘', store.markNotified(dueItem.id, 123456) === true);
check('markNotified 可读回', store.load().find((i) => i.id === dueItem.id).lastNotifiedAt === 123456);
check('markNotified 忽略未知 id', store.markNotified('nope', 1) === false);

// ── 6. 脏数据回落：文件被手工改坏也不能崩 ──
const savedFile = store.storePath();
fs.writeFileSync(savedFile, '{oops', 'utf8');
check('坏 JSON 读成空表', store.load().length === 0);
fs.writeFileSync(savedFile, JSON.stringify([
  { id: 'a', text: '正常一条', due: 1769900000 },
  { id: '', text: '缺 id 丢弃' },
  { id: 'b', text: '   ' },
  null,
  '字符串条目',
]), 'utf8');
const cleaned = store.load();
check('脏条目被过滤', cleaned.length === 1 && cleaned[0].text === '正常一条');
check('缺 lastNotifiedAt 归一化为 null', cleaned[0].lastNotifiedAt === null);

// ── 7. 到期挑选（对标 mac 版 checkTodoReminders）──
const NOW = 1_700_000_000_000;           // epoch 毫秒
const REPEAT = 5 * 60 * 1000;            // 重复提醒间隔 5 分钟
check('未到点不提醒', pickDueTodo([{ id: 1, due: NOW / 1000 + 60, lastNotifiedAt: null }], NOW, REPEAT) === null);
check('无 due 的随手记永不弹卡', pickDueTodo([{ id: 1, due: null, lastNotifiedAt: null }], NOW, REPEAT) === null);
check('到点且从未提醒 → 命中', pickDueTodo([{ id: 'a', due: NOW / 1000 - 1, lastNotifiedAt: null }], NOW, REPEAT)?.id === 'a');
check('刚提醒过（未满间隔）不再弹', pickDueTodo([{ id: 'a', due: NOW / 1000 - 1, lastNotifiedAt: NOW - 60 * 1000 }], NOW, REPEAT) === null);
check('距上次提醒满间隔 → 再弹', pickDueTodo([{ id: 'a', due: NOW / 1000 - 1, lastNotifiedAt: NOW - REPEAT }], NOW, REPEAT)?.id === 'a');
check('一次只弹第一条命中项', pickDueTodo([
  { id: 'a', due: NOW / 1000 - 10, lastNotifiedAt: null },
  { id: 'b', due: NOW / 1000 - 20, lastNotifiedAt: null },
], NOW, REPEAT)?.id === 'a');
check('非数组输入不崩', pickDueTodo(null, NOW, REPEAT) === null);

// ── 8. 重复提醒间隔收敛（对齐 mac 版 setter：1~240，脏值回落 5）──
check('clampRepeatMinutes(10) = 10', clampRepeatMinutes(10) === 10);
check('clampRepeatMinutes("10") 字符串也认', clampRepeatMinutes('10') === 10);
check('clampRepeatMinutes(0) 回落默认', clampRepeatMinutes(0) === DEFAULT_REPEAT_MINUTES);
check('clampRepeatMinutes(-3) 回落默认', clampRepeatMinutes(-3) === DEFAULT_REPEAT_MINUTES);
check('clampRepeatMinutes("abc") 回落默认', clampRepeatMinutes('abc') === DEFAULT_REPEAT_MINUTES);
check('clampRepeatMinutes(999) 截到上限 240', clampRepeatMinutes(999) === 240);

// ── 9. 到期时间文案（对齐 mac 版「约定时间 M月d日 HH:mm」）──
check('formatDueLabel 无 due 返回空串', formatDueLabel(null) === '');
check('formatDueLabel 输出 M月d日 HH:mm', /^\d{1,2}月\d{1,2}日 \d{2}:\d{2}$/.test(formatDueLabel(Math.floor(Date.now() / 1000))));

// ── 10. 扫描循环：命中即标记 + 触达，未命中不打扰 ──
{
  const fired = [];
  const marked = [];
  let timer = null;
  const loop = createTodoReminderLoop({
    load: () => [{ id: 'x', text: '打卡', due: 1000, lastNotifiedAt: null }],
    markNotified: (id, at) => marked.push([id, at]),
    fire: (item) => fired.push(item.text),
    getRepeatMinutes: () => 5,
    setTimer: (fn, ms) => { timer = { fn, ms }; return timer; },
    clearTimer: () => { timer = null; },
  });

  const hit = loop.checkNow(NOW);
  check('checkNow 命中到期项并回调 fire', fired.join(',') === '打卡' && hit.id === 'x');
  check('命中后先落「已触达」标记', marked.length === 1 && marked[0][0] === 'x' && marked[0][1] === NOW);

  const firedBefore = fired.length;
  check('未到期不触达', createTodoReminderLoop({
    load: () => [{ id: 'y', due: NOW / 1000 + 3600, lastNotifiedAt: null }],
    fire: () => {},
  }).checkNow(NOW) === null && fired.length === firedBefore);

  loop.start();
  check('start 挂了 30 秒周期的扫描定时器（与 mac 版 todoCheckSeconds 一致）',
    timer && timer.ms === 30 * 1000);
  loop.stop();
  check('stop 后定时器被清掉', timer === null);
}

// ── 11. 清单窗口高度（对标 mac 版 todoFinalHeight）──
check('空态 560', todoFinalHeight(0, 900) === 560);
check('每多一条 +52（大屏不被封顶）', todoFinalHeight(3, 1200) === 560 + 3 * 52);
check('900 高屏 3 条已被 72% 封顶到 648（与 mac 版同结果）', todoFinalHeight(3, 900) === Math.round(900 * 0.72));
check('小屏按可视区 72% 封顶', todoFinalHeight(50, 900) === Math.round(900 * 0.72));
check('下限 420', todoFinalHeight(0, 500) === 420);
check('负数条数按 0 处理', todoFinalHeight(-3, 900) === 560);

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
