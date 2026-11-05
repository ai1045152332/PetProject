// tests/friend-chat.test.js
// 好友会话窗（主进程）回归：已读上报时机 / 已读状态渲染 / 乐观消息去重
// node 直接跑，用 stub 的 electron 驱动 friend-chat-window.js，不启动真实窗口。
'use strict';

const path = require('path');
const Module = require('module');

const handlers = { handle: {}, on: {} };
const windows = [];

class FakeWindow {
  constructor() {
    this.destroyed = false;
    this.shown = 0;
    this.sent = [];
    this.focused = false;
    this.listeners = {};
    windows.push(this);
  }
  loadFile() {}
  once() {}
  show() { this.shown += 1; }
  focus() { this.focused = true; }
  setAlwaysOnTop() {}
  isDestroyed() { return this.destroyed; }
  isFocused() { return this.focused; }
  close() {
    if (this.destroyed) return;
    this.emit('close');
    this.destroyed = true;
    this.emit('closed');
  }
  on(evt, fn) { (this.listeners[evt] = this.listeners[evt] || []).push(fn); }
  emit(evt) { (this.listeners[evt] || []).forEach((fn) => fn()); }
  webContents = { send: (ch, payload) => { this.sent.push({ ch, payload }); } };
}

const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      BrowserWindow: FakeWindow,
      ipcMain: {
        handle: (ch, fn) => { handlers.handle[ch] = fn; },
        on: (ch, fn) => { handlers.on[ch] = fn; },
      },
    };
  }
  return origLoad.apply(this, arguments);
};

const chat = require(path.join(__dirname, '..', 'src', 'main', 'friend-chat-window.js'));

let failed = 0;
function check(name, condition) {
  if (condition) console.log(`✅ ${name}`);
  else { console.error(`❌ ${name}`); failed += 1; }
}

const tick = () => new Promise((r) => setTimeout(r, 10));
const MY_NO = 100001;

let historyRows = [];
const readCalls = [];

chat.setFriendChatAPI({
  history: async () => ({ ok: true, messages: historyRows.slice() }),
  send: async () => ({ ok: true }),
  confirmRead: async (ids) => { readCalls.push(ids.slice()); return { ok: true, marked: ids.length }; },
  myPetNo: () => MY_NO,
  petName: () => 'A猫',
});

const incoming = (id, text, petNo = 100002) => ({
  id, fromPetNo: petNo, fromName: 'B猫', text, sentMs: Date.now(), readMs: 0, mine: false,
});

(async () => {
  // ── 1. 点 ✕ 关卡：上报已读 ──
  chat.openFriendChat({ petNo: 100002, display: 'B猫 #100002', incoming: [incoming('m1', '在吗')], unreadIds: ['m1'] });
  await tick();
  check('打开会话窗建了窗口', windows.length === 1);

  handlers.on['friend-chat:close']();
  await tick();
  check('点 ✕ 关窗会确认已读', readCalls.length === 1 && readCalls[0].includes('m1'));

  // ── 2. Cmd+W / 直接关窗（不经过 ✕ 按钮）也要确认已读 ──
  readCalls.length = 0;
  historyRows = [];
  chat.openFriendChat({ petNo: 100002, display: 'B猫 #100002', incoming: [incoming('m2', '再问一次')], unreadIds: ['m2'] });
  await tick();
  windows.at(-1).close(); // 模拟系统关闭（Cmd+W / 退出应用）
  await tick();
  check('窗口被系统关闭也会确认已读（Cmd+W 路径）',
    readCalls.length === 1 && readCalls[0].includes('m2'));

  // ── 3. 换好友：旧窗静默关闭，不确认已读 ──
  readCalls.length = 0;
  chat.openFriendChat({ petNo: 100003, display: 'C猫 #100003', incoming: [incoming('m3', '我是 C', 100003)], unreadIds: ['m3'] });
  await tick();
  chat.openFriendChat({ petNo: 100002, display: 'B猫 #100002' });
  await tick();
  check('换好友静默关旧窗时不确认已读', readCalls.length === 0);

  // ── 4. 已读状态渲染：history 里 readMs>0 → 已读 ──
  historyRows = [
    { id: 'h1', fromPetNo: MY_NO, fromName: 'A猫', text: '我发的', sentMs: Date.now() - 1000, readMs: Date.now(), mine: true },
    { id: 'h2', fromPetNo: MY_NO, fromName: 'A猫', text: '还没读', sentMs: Date.now() - 500, readMs: 0, mine: true },
  ];
  windows.at(-1).emit('focus'); // 让新历史真正加载进来
  await tick();
  const snap = handlers.handle['friend-chat:payload']();
  const mineRows = (snap.rows || []).filter((r) => r.mine);
  check('readMs>0 渲染成已读', mineRows.some((r) => r.text === '我发的' && r.read === true));
  check('readMs=0 渲染成未读', mineRows.some((r) => r.text === '还没读' && r.read === false));

  // ── 5. 乐观消息不在历史里重复出现 ──
  await handlers.handle['friend-chat:send']({}, { text: '新发的一条' });
  await tick();
  const beforeReload = handlers.handle['friend-chat:payload']().rows.filter((r) => r.text === '新发的一条');
  check('发送后先乐观上屏一条', beforeReload.length === 1);

  historyRows = [...historyRows, {
    id: 'h3', fromPetNo: MY_NO, fromName: 'A猫', text: '新发的一条',
    sentMs: Date.now(), readMs: 0, mine: true,
  }];
  windows.at(-1).emit('focus'); // 触发一次重拉（等价于定时刷新）
  await tick();
  const afterReload = handlers.handle['friend-chat:payload']().rows.filter((r) => r.text === '新发的一条');
  check('服务端历史回来替换乐观行，不重复显示', afterReload.length === 1);

  // ── 6. 重新聚焦会重拉历史（已读状态自动更新）──
  historyRows = historyRows.map((m) => (m.id === 'h3' ? { ...m, readMs: Date.now() } : m));
  windows.at(-1).emit('focus');
  await tick();
  const refreshed = handlers.handle['friend-chat:payload']().rows.find((r) => r.text === '新发的一条');
  check('窗口重新聚焦后已读状态自动更新', refreshed && refreshed.read === true);

  console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
  process.exit(failed === 0 ? 0 : 1);
})();
