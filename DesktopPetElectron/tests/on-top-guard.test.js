// tests/on-top-guard.test.js
// 置顶守护回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：隐藏窗口不抬顶层、失焦/重新显示立刻抬、pause(Infinity) 期间不抢层级、resume 恢复、stop 后不再抬
'use strict';

const path = require('path');
const Module = require('module');

// ── mock electron（pet-window 顶层只解构 BrowserWindow / screen）──
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      app: { getPath: () => process.cwd() },
      BrowserWindow: class {},
      screen: { getPrimaryDisplay: () => ({ workAreaSize: { width: 1440, height: 900 } }) },
    };
  }
  return origLoad.apply(this, arguments);
};

const SRC = path.join(__dirname, '..', 'src', 'main');
// 轮询间隔在 mac 上被拉长到 10s（刻意），单测里按 Windows 分支跑才能观察轮询
const ORIGINAL_PLATFORM = process.platform;
Object.defineProperty(process, 'platform', { value: 'win32', configurable: true });
const { raisePet, startOnTopGuard } = require(path.join(SRC, 'pet-window.js'));

let failed = 0;
function check(name, condition) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    console.error(`❌ ${name}`);
    failed += 1;
  }
}

/** 伪 BrowserWindow：只实现置顶守护用到的接口 */
function fakeWin({ visible = true } = {}) {
  const listeners = new Map();
  const calls = [];
  const win = {
    destroyed: false,
    visible,
    isVisible: () => win.visible,
    isDestroyed: () => win.destroyed,
    setAlwaysOnTop: (...args) => calls.push(args),
    on: (event, fn) => {
      if (!listeners.has(event)) listeners.set(event, []);
      listeners.get(event).push(fn);
    },
    emit: (event, ...args) => (listeners.get(event) || []).forEach((fn) => fn(...args)),
    calls,
  };
  return win;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

(async () => {
  // 1. 隐藏 / 销毁的窗口不该被抬（避免把不可见窗口顶到最前）
  const hidden = fakeWin({ visible: false });
  raisePet(hidden);
  check('隐藏窗口不调用 setAlwaysOnTop', hidden.calls.length === 0);

  const destroyed = fakeWin();
  destroyed.destroyed = true;
  raisePet(destroyed);
  check('已销毁窗口不调用 setAlwaysOnTop', destroyed.calls.length === 0);

  const visible = fakeWin();
  raisePet(visible);
  check('可见窗口被抬顶层', visible.calls.length === 1);

  // 2. 失焦 / 重新显示立刻补一次置顶（Windows 上被别的置顶窗口压下去的场景）
  const guarded = fakeWin();
  const guard = startOnTopGuard(guarded, { intervalMs: 60000 });
  guarded.emit('blur');
  check('失焦后立刻重新置顶', guarded.calls.length === 1);
  guarded.emit('show');
  check('重新显示后立刻重新置顶', guarded.calls.length === 2);
  guarded.emit('always-on-top-changed', {}, false);
  check('置顶被系统取消后补一次', guarded.calls.length === 3);
  guarded.emit('always-on-top-changed', {}, true);
  check('置顶正常时不重复调用', guarded.calls.length === 3);

  // 3. 让出层级期间不抢（设置面板 / 托盘菜单打开时）
  guard.pause(Infinity);
  guarded.emit('blur');
  guarded.emit('show');
  check('pause(Infinity) 期间不抢回顶层', guarded.calls.length === 3);
  guard.resume();
  check('resume 后立刻抢回顶层', guarded.calls.length === 4);
  guarded.emit('blur');
  check('resume 后恢复失焦补位', guarded.calls.length === 5);

  // 4. 定时轮询兜底，stop 之后停止
  const polled = fakeWin();
  const pollGuard = startOnTopGuard(polled, { intervalMs: 10 });
  await sleep(80);
  check('定时轮询会周期性抬顶层', polled.calls.length >= 2);
  pollGuard.stop();
  const afterStop = polled.calls.length;
  polled.emit('blur');
  check('stop 后不再响应事件', polled.calls.length === afterStop);
  await sleep(40);
  check('stop 后不再轮询', polled.calls.length === afterStop);

  guard.stop();
  // 收尾还原平台，避免同进程后续模块受影响
  Object.defineProperty(process, 'platform', { value: ORIGINAL_PLATFORM, configurable: true });

  if (failed > 0) {
    console.error(`\n置顶守护测试失败 ${failed} 项`);
    process.exit(1);
  }
  console.log('\n全部通过');
})();
