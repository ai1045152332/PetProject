// tests/focus-edge.test.js
// 专注跟随 + 贴边躲藏回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：mac 勿扰断言解析 / Windows 注册表解析 / 监视器只在状态变化时回调 /
//       基准态映射 / 贴边吸附与现身的几何计算 / 躲藏中改尺寸按新尺寸重新吸附
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const Module = require('module');

// ── mock electron（pet-window 只用 BrowserWindow / screen）──
const origLoad = Module._load;
let fakeDisplays = [];
Module._load = function (request) {
  if (request === 'electron') {
    return {
      BrowserWindow: class {},
      screen: {
        getPrimaryDisplay: () => ({ workAreaSize: { width: 1440, height: 900 } }),
        getDisplayMatching: (b) => ({
          workArea: fakeDisplays.find((d) => d.name === b.display) ? d.workArea : { x: 0, y: 0, width: 1440, height: 900 },
        }),
      },
    };
  }
  return origLoad.apply(this, arguments);
};

const SRC = path.join(__dirname, '..', 'src', 'main');
const focus = require(path.join(SRC, 'pet', 'focus-mode-monitor.js'));
const { snapToEdgeForHiding, revealFromEdge } = require(path.join(SRC, 'pet', 'edge-snap.js'));
const { applyPetScale } = require(path.join(SRC, 'pet', 'pet-window.js'));

let failed = 0;
function check(name, condition, extra) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    console.error(`❌ ${name}${extra ? ' → ' + extra : ''}`);
    failed += 1;
  }
}
const tick = (ms = 30) => new Promise((r) => setTimeout(r, ms));

// ── 1. macOS 勿扰断言解析 ──
{
  check('存在活跃断言 = 勿扰开启',
    focus.parseMacFocusAssertions(JSON.stringify({ data: [{ storeAssertionRecords: [{ a: 1 }] }] })) === true);
  check('断言数组为空 = 勿扰关闭（断言已移入 invalidation）',
    focus.parseMacFocusAssertions(JSON.stringify({ data: [{ storeAssertionRecords: [] }] })) === false);
  check('data 缺失判为关闭', focus.parseMacFocusAssertions('{}') === false);
  check('脏 JSON 判为关闭且不抛错', focus.parseMacFocusAssertions('not json') === false);
}

// ── 2. 同步检测真的读文件（临时 home，用完即删）──
{
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-focus-'));
  check('文件不存在 → 未开启', focus.detectSync({ platform: 'darwin', home }) === false);

  const file = focus.assertionsPath(home);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ data: [{ storeAssertionRecords: [{ id: 1 }] }] }));
  check('写入断言后 → 已开启', focus.detectSync({ platform: 'darwin', home }) === true);

  fs.rmSync(home, { recursive: true, force: true });
}

// ── 3. Windows 注册表输出解析 ──
{
  const out = [
    '',
    'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager',
    '    Windows.System.FocusAssistAppStateEnabled    REG_DWORD    0x1',
    '',
  ].join('\r\n');
  check('REG_DWORD 0x1 读成开启', focus.isWinFocusEnabled(focus.parseRegQueryValue(out, 'Windows.System.FocusAssistAppStateEnabled')) === true);
  check('0x0 读成未开启', focus.isWinFocusEnabled(focus.parseRegQueryValue(out.replace('0x1', '0x0'), 'Windows.System.FocusAssistAppStateEnabled')) === false);
  check('键不存在时解析结果为 null（回落未开启）',
    focus.parseRegQueryValue('ERROR: The system was unable to find the specified registry key.', 'QuietHours') === null);
  check('读不到值 → 未开启', focus.isWinFocusEnabled(null) === false);

  // 注入假 exec：只有 FocusAssist 那个键返回 1
  const exec = (cmd, args, opts, cb) => {
    const name = args[args.length - 1];
    const value = name === 'Windows.System.FocusAssistAppStateEnabled' ? '0x1' : '0x0';
    cb(null, `    ${name}    REG_DWORD    ${value}\r\n`, '');
  };
  focus.detectFocusMode({ platform: 'win32', exec }).then((active) => {
    check('Windows 异步检测按注册表值判开启', active === true, String(active));
  });

  const execMissing = (cmd, args, opts, cb) => cb(new Error('file not found'), '', '');
  focus.detectFocusMode({ platform: 'win32', exec: execMissing }).then((active) => {
    check('Windows 读不到注册表（Win11 常态）→ 判未开启', active === false, String(active));
  });
}

// ── 4. 监视器：只在状态变化时回调（轮询由注入的定时器驱动）──
{
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-focus-'));
  let timerFn = null;
  const changes = [];
  const monitor = focus.startFocusModeMonitor({
    platform: 'darwin',
    home: () => home,
    onChange: (active) => changes.push(active),
    setIntervalFn: (fn) => { timerFn = fn; return { unref() {} }; },
    clearIntervalFn: () => { timerFn = null; },
    watchFn: () => ({ close() {}, unref() {} }),
  });

  // 初值：文件不存在 → 未开启；此时状态没变化，不应回调
  check('启动时未开启不产生回调', changes.length === 0);

  const file = focus.assertionsPath(home);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ data: [{ storeAssertionRecords: [{ id: 1 }] }] }));
  timerFn();
  tick().then(() => {
    check('开勿扰后回调一次 true', changes.join(',') === 'true', changes.join(','));
    timerFn();
    return tick();
  }).then(() => {
    check('状态没变不再重复回调', changes.length === 1);
    fs.writeFileSync(file, JSON.stringify({ data: [{ storeAssertionRecords: [] }] }));
    timerFn();
    return tick();
  }).then(() => {
    check('关勿扰后回调 false', changes.join(',') === 'true,false', changes.join(','));
    monitor.stop();
    fs.rmSync(home, { recursive: true, force: true });
    return runStateMapAndSnap();
  });
}

// ── 5. 基准态映射（勿扰→专注，否则休闲）──
function runStateMapAndSnap() {
  check('勿扰中基准态是 focus', focus.petStateForFocusMode(true) === 'focus');
  check('非勿扰基准态是 idel', focus.petStateForFocusMode(false) === 'idel');

  // ── 6. 贴边吸附几何 ──
  const area = { x: 0, y: 0, width: 1440, height: 900 };
  const far = snapToEdgeForHiding({ bounds: { x: 700, y: 300, width: 200, height: 200 }, area });
  check('屏幕中间松手不吸附', far === null);

  const right = snapToEdgeForHiding({ bounds: { x: 1210, y: 300, width: 200, height: 200 }, area });
  check('距右边 30px（<60）吸附到右边', right && right.facing === 'right' && right.bounds.x === 1240, JSON.stringify(right));

  const tooFar = snapToEdgeForHiding({ bounds: { x: 1140, y: 300, width: 200, height: 200 }, area });
  check('距右边 100px（>60）不吸附', tooFar === null);

  const left = snapToEdgeForHiding({ bounds: { x: 20, y: 300, width: 200, height: 200 }, area });
  check('左边更近时吸左边', left && left.facing === 'left' && left.bounds.x === 0, JSON.stringify(left));

  const yClamped = snapToEdgeForHiding({ bounds: { x: 1230, y: 850, width: 200, height: 200 }, area });
  check('纵向夹在工作区内，不让窗口滑出底部', yClamped && yClamped.bounds.y === 700, JSON.stringify(yClamped));

  // 右键「躲起来」：不看距离，直接吸到最近一侧
  const forced = snapToEdgeForHiding({ bounds: { x: 700, y: 300, width: 200, height: 200 }, area, requiresNearEdge: false });
  check('躲起来（requiresNearEdge=false）直接吸到最近一侧',
    forced && forced.facing === 'right' && forced.bounds.x === 1240, JSON.stringify(forced));

  // ── 7. 现身：完整收回屏内 ──
  const revealed = revealFromEdge({ bounds: { x: 1240, y: 300, width: 200, height: 200 }, area });
  check('贴右边现身收进屏内 4px', revealed.x === 1236 && revealed.y === 300, JSON.stringify(revealed));
  const revealedLeft = revealFromEdge({ bounds: { x: 0, y: 0, width: 200, height: 200 }, area });
  check('贴左上角现身留 4px 边距', revealedLeft.x === 4 && revealedLeft.y === 4, JSON.stringify(revealedLeft));
  const kept = revealFromEdge({ bounds: { x: 500, y: 400, width: 200, height: 200 }, area });
  check('本来就在屏内则位置不动', kept.x === 500 && kept.y === 400);

  return runScaleResnap();
}

// ── 8. 躲藏中改宠物大小：按新尺寸重新贴同一条边（对齐 mac 版 resizeWindow）──
function runScaleResnap() {
  fakeDisplays = [{ name: 'main', workArea: { x: 0, y: 0, width: 1440, height: 900 } }];
  const win = {
    bounds: { x: 1240, y: 300, width: 200, height: 200 }, // 已整边贴右
    isDestroyed: () => false,
    getPosition() { return [this.bounds.x, this.bounds.y]; },
    getSize() { return [this.bounds.width, this.bounds.height]; },
    setBounds(b) { this.bounds = { ...this.bounds, ...b }; },
    display: 'main',
  };
  const snapped = applyPetScale(win, 1.5); // 200 → 300
  check('躲藏中放大返回吸附结果', Boolean(snapped) && snapped.facing === 'right');
  check('放大后仍整边贴右（1440-300）', win.bounds.width === 300 && win.bounds.x === 1140, JSON.stringify(win.bounds));

  const plain = applyPetScale({
    bounds: { x: 700, y: 300, width: 200, height: 200 },
    isDestroyed: () => false,
    getPosition() { return [this.bounds.x, this.bounds.y]; },
    getSize() { return [this.bounds.width, this.bounds.height]; },
    setBounds(b) { this.bounds = { ...this.bounds, ...b }; },
  }, 1.0);
  check('屏内的猫放大不判为躲藏（返回 null，走原钳制逻辑）', plain === null);

  finish();
}

function finish() {
  // 等异步分支（Windows 检测）先落定再汇总
  setTimeout(() => {
    if (failed > 0) {
      console.error(`\n专注/躲藏测试失败 ${failed} 项`);
      process.exit(1);
    }
    console.log('\n全部通过');
  }, 100);
}
