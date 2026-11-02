// tests/sysinfo-menu.test.js
// 托盘「系统信息」回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：CPU/网络采集口径（对齐 Swift SystemMonitor）、缓存不重复 spawn、
//       二级菜单模板（勾选 + 只读展示行 + 分隔线）、勾选切换持久化与顶栏标题、
//       worker 只读缓存链路（点菜单不同步 spawn，防卡顿回归）、worker 消息协议、
//       mac 顶栏 setTitle / win 不 setTitle / win 菜单打开期间每秒重建、top/vm_stat/netstat 解析
'use strict';

const path = require('path');
const Module = require('module');
const assert = require('assert');

const SRC = path.join(__dirname, '..', 'src', 'main');
const TRAY_PATH = path.join(SRC, 'tray.js');
const { SysInfoMonitor, parseCpuTop, parseVmStat, parseNetstatIb, computeTrayTitle, METRIC_ICONS } = require(path.join(SRC, 'system-monitor.js'));
const { createCacheOnlySnapshot, buildWorkerMonitor, runWorkerLoop } = require(path.join(SRC, 'sysinfo-worker.js'));

let failed = 0;
function check(name, condition) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    console.error(`❌ ${name}`);
    failed += 1;
  }
}

// ── 假采集器 + 假时钟的监控核心逻辑 ──
function makeMonitor(overrides = {}) {
  const store = {};
  let nowMs = 0;
  let cpuCalls = 0;
  let netCalls = 0;
  const titles = [];
  const readers = {
    // CPU reader：已做好增量的占用率百分比（top -l 2 / PowerShell 计数器语义），按时间窗切换两组值
    cpu: () => {
      cpuCalls += 1;
      return nowMs >= 5000
        ? { percent: 50, breakdown: { system: 10, user: 40, idle: 50 } }
        : { percent: 30, breakdown: { system: 10, user: 20, idle: 70 } };
    },
    mem: () => ({ totalBytes: 16e9, freeBytes: 2e9, inactiveBytes: 4e9, speculativeBytes: 0 }),
    disk: () => ({ totalBytes: 512e9, availBytes: 200e9 }),
    net: () => {
      netCalls += 1;
      return { rx: nowMs >= 5000 ? 1024 * 5000 : 0, tx: nowMs >= 5000 ? 1024 * 1000 : 0 };
    },
    ...overrides.readers,
  };
  const monitor = new SysInfoMonitor({
    getOption: (key) => store[key],
    setOption: (key, value) => { store[key] = value; },
    readers,
    now: () => nowMs,
    ...overrides.deps,
  });
  return { monitor, store, titles, tick: (ms) => { nowMs = ms; }, cpuCalls: () => cpuCalls, netCalls: () => netCalls };
}

// 首次采样：网络无基线 → null（对齐 Swift 首次返回 nil）；CPU 直接可用；内存/磁盘同步可用
{
  const { monitor } = makeMonitor();
  const snap = monitor.snapshot();
  check('首次采样 CPU 直接给占用率', snap.cpu && Math.abs(snap.cpu.percent - 30) < 1e-9);
  check('首次采样 网络无基线返回 null', snap.net === null);
  check('内存已用 = 总量-空闲-非活跃-推测（口径同 Swift）', Math.abs(snap.mem.percent - 62.5) < 1e-9);
  check('磁盘已用/总量（512-200）/512 = 60.9%', Math.abs(snap.disk.percent - (312 / 512) * 100) < 1e-9);
  check('内存条目只显示名称（百分比交给展示行）', monitor.itemLabel('mem') === '内存');
  check('磁盘条目带百分比与容量', monitor.itemLabel('disk') === '磁盘  61%（已用 312.0GB / 共 512.0GB）');
}

// 第二次采样（超出缓存窗）：CPU 拿新值；网络按字节差 ÷ 时间窗
{
  const { monitor, tick } = makeMonitor();
  tick(0);
  monitor.snapshot();
  tick(5000);
  const snap = monitor.snapshot();
  check('CPU 占用超缓存窗后重新采样', Math.abs(snap.cpu.percent - 50) < 1e-9);
  check('CPU 三段明细（系统/用户/闲置）合计 100%', snap.cpu.breakdown.system === 10 && snap.cpu.breakdown.user === 40 && snap.cpu.breakdown.idle === 50);
  // Δrx=5000KB / 5s = 1000KB/s，Δtx=1000KB / 5s = 200KB/s
  check('网络速率 = 字节差 ÷ 时间窗', Math.abs(snap.net.downKBps - 1000) < 1e-9 && Math.abs(snap.net.upKBps - 200) < 1e-9);
  check('网络条目文案对齐 Swift 格式', monitor.itemLabel('net', snap) === '网络  ↓ 1000KB/s  ↑ 200KB/s');
}

// 缓存：同一时间窗内重复取值不重复采集（省掉 top/df 的 spawn）
{
  const { monitor, tick, cpuCalls, netCalls } = makeMonitor();
  tick(0);
  monitor.snapshot(); // cpu/net 首次采集
  const c0 = cpuCalls();
  const n0 = netCalls();
  tick(800); // 仍在 1.5s/1s 缓存窗内
  monitor.snapshot();
  check('缓存期内不重复采集 CPU/网络', cpuCalls() === c0 && netCalls() === n0);
  tick(3000); // 超出缓存窗后重新采集
  monitor.getMetric('cpu');
  check('缓存窗过后重新采集', cpuCalls() === c0 + 1);
}

// ── 二级菜单模板 ──
{
  const { monitor, tick } = makeMonitor();
  tick(0);
  monitor.snapshot();
  tick(5000);
  const items = monitor.buildMenuTemplate();
  const labels = items.map((i) => i.label || i.type);
  check('模板含 CPU/内存/磁盘/网络 四个可勾选条目', ['CPU', '内存', labels.find((l) => l && l.startsWith('磁盘')), labels.find((l) => l && l.startsWith('网络'))].every(Boolean));
  check('CPU/内存下方各一条只读展示行（环形图文本替身）',
    items.filter((i) => i.enabled === false && i.label && i.label.startsWith('CPU 占用')).length === 1 &&
    items.filter((i) => i.enabled === false && i.label && i.label.startsWith('内存占用')).length === 1);
  check('指标条目之间以分隔线分组', items.filter((i) => i.type === 'separator').length === 3);
  const cpuChart = items.find((i) => i.label && i.label.startsWith('CPU 占用'));
  // 第二轮采样：系统 10% 用户 40% 闲置 50%，中心总占用 50%
  check('CPU 展示行呈现总占用与图例（替代环形图）', cpuChart.label.includes('CPU 占用 50%') && cpuChart.label.includes('系统 10%') && cpuChart.label.includes('用户 40%') && cpuChart.label.includes('闲置 50%'));
  const memChart = items.find((i) => i.label && i.label.startsWith('内存占用'));
  check('内存展示行 已用/空闲 合计 100%', memChart.label.includes('内存占用 63%') && memChart.label.includes('已用 63%') && memChart.label.includes('空闲 37%'));
  check('四个指标条目都是 checkbox', items.filter((i) => i.type === 'checkbox').length === 4);
}

// ── 勾选切换 → 持久化 + 顶栏标题 + 重建回调 ──
{
  const { monitor, store, tick } = makeMonitor();
  tick(0);
  monitor.snapshot();
  tick(5000);
  monitor.snapshot();
  check('默认全不勾选', monitor.anyEnabled() === false);
  check('未勾选时顶栏标题为空', monitor.trayTitle() === '');
  let rebuilt = 0;
  const items = monitor.buildMenuTemplate(() => { rebuilt += 1; });
  items.find((i) => i.label === 'CPU').click();
  check('点击 CPU 条目写入持久化配置（键对齐 menuBar.showCPU）', store['menuBar.showCPU'] === true);
  check('点击后触发回调计数（供重建菜单刷新勾）', rebuilt === 1);
  check('勾选后顶栏用图标不带文字标签', monitor.trayTitle() === `${METRIC_ICONS.cpu}50%`);
  const items2 = monitor.buildMenuTemplate();
  items2.find((i) => i.label === 'CPU').click();
  check('再次点击取消勾选', store['menuBar.showCPU'] === false && monitor.trayTitle() === '');
  items2.find((i) => i.label === '内存').click();
  check('勾选内存后顶栏为「图标+百分比」', monitor.trayTitle() === `${METRIC_ICONS.mem}63%`);
  check('顶栏不再出现中文指标名（对齐 Swift 的 SF Symbol 风格）', !/CPU|内存|磁盘|网络/.test(monitor.trayTitle()));
  check('未勾选网络不出现在标题（网络图标不出现）', (() => {
    monitor.setOption('menuBar.showNet', false);
    return !monitor.trayTitle().includes(METRIC_ICONS.net);
  })());
}

// ── worker 只读缓存链路：主进程菜单构建/取值全程不同步 spawn（点托盘菜单卡顿的回归护栏）──
{
  // 1) 未挂 cacheOnly 时行为不变（供 worker 子进程直接采集用）
  // 2) 挂上只读源后：投喂前全 null 且不碰 reader；投喂后菜单用喂过的值，仍不碰 reader
  let spawnCalls = 0;
  const mainMonitor = new SysInfoMonitor({
    getOption: (key) => key === 'menuBar.showCPU',
    readers: {
      cpu: () => { spawnCalls += 1; return { percent: 99, breakdown: { system: 1, user: 98, idle: 1 } }; },
      mem: () => { spawnCalls += 1; return null; },
      disk: () => { spawnCalls += 1; return null; },
      net: () => { spawnCalls += 1; return null; },
    },
  });
  const cache = createCacheOnlySnapshot();
  mainMonitor.setCacheOnly(cache);
  const empty = mainMonitor.snapshotCached();
  const tpl0 = mainMonitor.buildMenuTemplate();
  check('投喂前只读快照全 null 且零采集', spawnCalls === 0
    && empty.cpu === null && empty.mem === null && empty.disk === null && empty.net === null);
  check('投喂前菜单不报错，展示行提示采样中', tpl0.some((i) => i.label && i.label.includes('采样中')));
  cache.apply({ cpu: { percent: 12.4, breakdown: { system: 4, user: 8, idle: 88 } }, disk: { percent: 60, usedGB: 300, totalGB: 500 } });
  const tpl1 = mainMonitor.buildMenuTemplate();
  check('投喂后菜单直接显新值，仍零采集', spawnCalls === 0
    && tpl1.some((i) => i.label === '磁盘  60%（已用 300.0GB / 共 500.0GB）')
    && tpl1.some((i) => i.label && i.label.startsWith('CPU 占用 12%')));
  check('顶栏标题读同一份缓存', mainMonitor.trayTitle() === `${METRIC_ICONS.cpu}12%`);

  // 3) worker 侧：buildWorkerMonitor 按 enabled 字典判勾选
  const wm = buildWorkerMonitor({ 'menuBar.showCPU': true }, {});
  check('worker 监控器按 enabled 字典判勾选', wm.isEnabled('cpu') === true && wm.isEnabled('mem') === false);
  check('computeTrayTitle 纯函数与实例同口径', computeTrayTitle(
    { cpu: { percent: 12.4 } }, (m) => m === 'cpu') === `${METRIC_ICONS.cpu}12%`);

  // 4) worker 循环协议：首帧 enabled（带基线标题），之后每秒 snapshot + enabled；stop 后不再发
  const sent = [];
  const fakeMonitor = {
    isEnabled: (m) => m === 'cpu',
    snapshot: () => ({ cpu: { percent: 40 } }),
    refresh: () => ({ cpu: { percent: 50 } }),
  };
  const timers = [];
  const fakeSetTimeout = (fn) => { timers.push(fn); return 1; };
  const origST = global.setTimeout;
  global.setTimeout = fakeSetTimeout;
  let loop;
  try {
    loop = runWorkerLoop(fakeMonitor, (m) => sent.push(m), global.setTimeout);
    check('worker 首帧先发 enabled（带基线算好的标题）', sent[0].type === 'enabled' && sent[0].title === `${METRIC_ICONS.cpu}40%`);
    timers.shift()(); // 跑第一次 tick
    check('worker 每 tick 回传 snapshot + enabled', sent[1].type === 'snapshot' && sent[1].snap.cpu.percent === 50
      && sent[2].type === 'enabled' && sent[2].title === `${METRIC_ICONS.cpu}50%`);
    loop.stop();
    const before = sent.length;
    timers.shift()(); // stop 后再跑 tick 应静默
    check('stop 后 tick 不再发消息', sent.length === before && timers.length === 0);
  } finally {
    global.setTimeout = origST;
  }
}

// ── 采集器解析（纯函数喂真实格式的样本输出）──
{
  // top -l 2 双轮输出：取第二轮（增量窗口）的百分比 → 直接给占用率与三段明细
  const topOut = 'Processes: 500 total\nCPU usage: 8.1% user, 4.2% sys, 87.7% idle\nShared region:\nCPU usage: 12.1% user, 8.3% sys, 79.6% idle\n';
  const topParsed = parseCpuTop(topOut);
  check('top 双轮输出取第二轮百分比', topParsed
    && Math.abs(topParsed.percent - 20.4) < 1e-9
    && topParsed.breakdown.user === 12.1 && topParsed.breakdown.system === 8.3 && topParsed.breakdown.idle === 79.6);
  check('top 单轮输出取当前值', (() => {
    const one = parseCpuTop('CPU usage: 5.0% user, 1.0% sys, 94.0% idle\n');
    return one && one.percent === 6 && one.breakdown.idle === 94;
  })());
  check('top 输出无法解析时返回 null', parseCpuTop('nothing here') === null);
  const vmOut = 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:                                1000.\nPages inactive:                            2000.\nPages speculative:                           500.\n';
  const memParsed = parseVmStat(vmOut, 17179869184);
  check('vm_stat 解析页数×页大小为字节', memParsed
    && memParsed.freeBytes === 1000 * 16384
    && memParsed.inactiveBytes === 2000 * 16384
    && memParsed.speculativeBytes === 500 * 16384);
  check('vm_stat 缺页大小时返回 null', parseVmStat('Pages free: 1.', 1e9) === null);
  // netstat -ibn 真实输出（macOS 15）：只取 en* 链路行的 Ibytes/Obytes
  const netOut = [
    'Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll',
    'lo0        16384 <Link#1>                      73028154     0 22940824839 73028154     0 22940824839     0',
    'en4        1500  <Link#7>    e6:fe:9d:2d:9f:f5        0     0          0        0     0          0     0',
    'en0        1500  <Link#16>   84:2f:57:76:4d:d5 71786346     0 54473886863 73334438     0 46443499193     0',
    'en0        1500  11.0.192/18   11.0.213.233    71786346     - 54473886863 73334438     - 46443499193     -',
    'utun1      1500  <Link#20>                            0     0          0      833     0         80     0',
  ].join('\n');
  const netParsed = parseNetstatIb(netOut);
  // 回归护栏：旧实现拿第 2 列（其实是 Mtu，所有接口都是 1500）去重，只会统计到排在前面的空接口 en4 → 网络恒为 0
  check('netstat 取 en* 链路行的 Ibytes/Obytes（不被空接口抢先）', netParsed
    && netParsed.rx === 54473886863 && netParsed.tx === 46443499193);
  check('netstat 不统计环回 lo0 与隧道 utun', netParsed && netParsed.rx !== 54473886863 + 22940824839);
  check('netstat 同名接口的地址行不重复累加', netParsed && netParsed.rx === 54473886863);
  check('netstat 无 Address 的链路行不错列（计数按行尾定位）', (() => {
    const only = parseNetstatIb([
      'Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll',
      'en8        1500  <Link#21>                            10     0       5000        5     0       2000     0',
    ].join('\n'));
    return only && only.rx === 5000 && only.tx === 2000;
  })());
  check('netstat 老格式（无字节列）返回 null 而不拿包数冒充字节', parseNetstatIb([
    'Name       Mtu   Network       Address            Ipkts Ierrs    Opkts Oerrs  Coll',
    'en0        1500  <Link#16>   84:2f:57:76:4d:d5 71786346     0 73334438     0     0',
  ].join('\n')) === null);
  check('netstat 没有任何 en* 接口时返回 null', parseNetstatIb([
    'Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll',
    'lo0        16384 <Link#1>                            10     0        100       10     0        100     0',
  ].join('\n')) === null);
}

// ── tray 接线：mac setTitle / win 不 setTitle / win 菜单打开期间每秒重建 ──
const trayInstances = [];
class FakeTray {
  constructor(image) {
    this.image = image;
    this.handlers = new Map();
    this.tooltips = [];
    this.contextMenus = [];
    this.poppedMenus = [];
    this.titles = [];
    trayInstances.push(this);
  }
  setToolTip(text) { this.tooltips.push(text); }
  setContextMenu(menu) { this.contextMenus.push(menu); }
  popUpContextMenu(menu) { this.poppedMenus.push(menu); }
  setTitle(text) { this.titles.push(text); }
  on(event, fn) {
    if (!this.handlers.has(event)) this.handlers.set(event, []);
    this.handlers.get(event).push(fn);
  }
  emit(event, ...args) { (this.handlers.get(event) || []).forEach((fn) => fn(...args)); }
  destroy() { this.destroyed = true; }
}

function fakeNativeImage(size, isTemplate) {
  const img = {
    size,
    isTemplate,
    resize: (opts) => fakeNativeImage({ width: opts.width, height: opts.height }, img.isTemplate),
    setTemplateImage: (flag) => { img.isTemplate = Boolean(flag); },
  };
  return img;
}

const origLoad2 = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      Tray: FakeTray,
      Menu: { buildFromTemplate: (template) => ({ template }) },
      app: { on: () => {} },
      nativeImage: { createFromPath: () => fakeNativeImage({ width: 32, height: 32 }, false) },
    };
  }
  return origLoad2.apply(this, arguments);
};

const ORIGINAL_PLATFORM = process.platform;
function loadTray(platform) {
  Object.defineProperty(process, 'platform', { value: platform, configurable: true });
  delete require.cache[require.resolve(TRAY_PATH)];
  return require(TRAY_PATH);
}

// mac：勾选指标 → 顶栏 setTitle（由 worker 回传驱动）；菜单模板挂「系统信息」
{
  const sysInfoTpl = () => [{ label: 'CPU', type: 'checkbox', checked: false }];
  const trayModule = loadTray('darwin');
  const tray = trayModule.createTray({
    version: '0.0.1',
    isPetVisible: () => true,
    buildSysInfoTemplate: sysInfoTpl,
  });
  trayModule.setTrayTitle('CPU 23%');
  check('mac 顶栏 setTitle 生效', tray.titles[tray.titles.length - 1] === 'CPU 23%');
  trayModule.setTrayTitle('');
  check('mac 取消全部勾选后清除顶栏文字', tray.titles[tray.titles.length - 1] === '');
  const tpl = trayModule.buildMenuTemplate({
    isPetVisible: () => true,
    version: '0.0.1',
    buildSysInfoTemplate: sysInfoTpl,
  });
  check('主菜单第一项是「系统信息」二级菜单', tpl[0].label === '系统信息' && Array.isArray(tpl[0].submenu));
  check('系统信息注入后菜单总项数为 7', tpl.length === 7);
}

// win：setTitle 不生效（防图标被文字替换）；菜单打开期间每秒重建 contextMenu
{
  const origSetInterval = global.setInterval;
  const origClearInterval = global.clearInterval;
  const started = [];
  global.setInterval = (fn, ms) => { started.push({ fn, ms }); return 7; };
  global.clearInterval = () => {};
  const trayModule = loadTray('win32');
  const tray = trayModule.createTray({
    version: '0.0.1',
    isPetVisible: () => true,
    buildSysInfoTemplate: () => [{ label: 'CPU', type: 'checkbox', checked: true }],
  });
  trayModule.setTrayTitle('CPU 23%');
  try {
    check('win 不 setTitle（通知区图标不能被文字顶掉）', tray.titles.length === 0);
    tray.emit('menu-open');
    check('win 菜单打开启动每秒刷新定时器', started.length === 1 && started[0].ms === 1000);
    const ctxBefore = tray.contextMenus.length;
    started[0].fn();
    check('win 刷新定时器重建并回设 contextMenu（菜单内数值实时刷新）', tray.contextMenus.length === ctxBefore + 1);
    const menu = tray.contextMenus[tray.contextMenus.length - 1];
    check('win 实时菜单同样带系统信息二级菜单', menu.template[0].label === '系统信息' && menu.template[0].submenu.length === 1);
    tray.emit('menu-close');
    global.setInterval = origSetInterval;
    global.clearInterval = origClearInterval;
  } finally {
    global.setInterval = origSetInterval;
    global.clearInterval = origClearInterval;
  }
}

Object.defineProperty(process, 'platform', { value: ORIGINAL_PLATFORM, configurable: true });
delete require.cache[require.resolve(TRAY_PATH)];

if (failed > 0) {
  console.error(`\n系统信息测试失败 ${failed} 项`);
  process.exit(1);
}
assert(failed === 0);
console.log('\n全部通过');
