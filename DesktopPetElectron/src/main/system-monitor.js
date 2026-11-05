// src/main/system-monitor.js
// 系统指标采集 + 「系统信息」二级菜单数据（对标 mac 原生版 SystemMonitor.swift + App 内监控接线）
// 口径与 Swift 版一致：
// - CPU：占用 =（用户 + 系统 + nice）占比，三段明细（系统 / 用户(nice 并入) / 闲置）。
//   mac 用常驻 top -l 0 流式采样（每秒推一行增量，读取近零延迟）；Win 用 PowerShell 计数器；
//   两者已在系统层做好增量，直接拿百分比（Electron 拿不到 host_cpu_load_info 的累计 tick）；
//   Win 首次无数据返回 null 对齐 Swift
//   ⚠ top 的 -s 只接整数秒（macOS），-s 0.5 会直接报错；也不要用 top -l 2 双轮 spawn，
//   单次要跑近 2s，把 worker 整轮刷新拖到 3s+（菜单数值明显滞后）
// - 内存：已用 ≈ 总量 - 空闲 - 非活跃 - 推测（与活动监视器接近，GB 按 1e9 换算）；明细里可回收部分全算空闲，合计正好 100%
// - 磁盘：根卷 已用 = 总量 - 可用，10s 缓存（变化慢，也省掉高频 spawn）
// - 网络：物理接口（mac en* / Win 以太网）收发字节差值 ÷ 时间窗 → KB/s，1s 缓存
// 原生菜单放不了 AppKit 的环形图自定义 view，环形图数据以「展示行」文本呈现；
// 顶栏指标图标：Swift 用 SF Symbol（cpu/memorychip/internaldrive/arrow.up.arrow.down），
// Electron 的 tray.setTitle 只收纯字符串（无富文本/attachment API），所以两条路：
// - 首选：mac 下由 metric-bar-image 把同一套 SF Symbol 导出的瓦片与数字拼成整条模板图走 setImage；
//   worker 回传的结构化 parts（{metric, symbol, text}）就是它的输入，口径与 Swift 的 parts 一致；
// - 回落：瓦片素材缺失/系统版本对不上时，用单色 Unicode 字形（METRIC_ICONS）继续 setTitle。
// 「一键清理内存」依赖 macOS 专属 purge 与解锁权限（AccessControl），Electron 跨平台版暂不移植。
// 顶栏标题不在本类定时刷新：由 sysinfo-worker 每秒算好回传（主进程零采集零阻塞）。
'use strict';

const os = require('os');
const { execFileSync } = require('child_process');

const METRICS = ['cpu', 'mem', 'disk', 'net'];
// 配置键与 Swift 版 UserDefaults 的 menuBar.show* 对齐
const PREF_KEYS = {
  cpu: 'menuBar.showCPU',
  mem: 'menuBar.showMemory',
  disk: 'menuBar.showDisk',
  net: 'menuBar.showNet',
};
// 各指标缓存间隔（秒），对齐 Swift 版；平台 reader 可用 cacheS 字段整体覆盖
// （mac 常驻流/秒级命令把缓存归零，worker 每个 tick 直接重读最新值）
const DEFAULT_CACHE_S = { cpu: 1, mem: 2, disk: 10, net: 1 };
// 顶栏图标（对齐 Swift refreshMenuBarMetrics 的 SF Symbol 顺序）：▣ cpu  ▤ memorychip  ◉ internaldrive  ⇅ arrow.up.arrow.down
// 这四个字形菜单栏字体本身不含，但系统会回退到 AppleSymbols/HiraKaku 等（已用 CTFontCreateForString 逐个验证）
const METRIC_ICONS = { cpu: '\u25a3', mem: '\u25a4', disk: '\u25c9', net: '\u21c5' };
// 指标 → Swift 侧用的 SF Symbol 名（写进 parts 供文档与素材对照，瓦片键用 metric）
const METRIC_SYMBOLS = { cpu: 'cpu', mem: 'memorychip', disk: 'internaldrive', net: 'arrow.up.arrow.down' };
const GB = 1e9;

const clampPct = (v) => Math.min(Math.max(v, 0), 100);

// ── 平台采集器（reader 均可注入，便于 node 直跑测试）──
// reader 约定：返回原始指标（CPU 为当前窗口占用率 / 网络为累计字节），差值与缓存统一在类内做

/** 从一段文本解析 CPU 占用率与三段明细（流式逐行与双轮输出共用；无匹配返回 null） */
function parseCpuTopLine(seg) {
  const m = /(\d+(?:\.\d+)?)%\s*user.*?(\d+(?:\.\d+)?)%\s*sys.*?(\d+(?:\.\d+)?)%\s*idle/.exec(seg);
  if (!m) return null;
  return {
    percent: parseFloat(m[1]) + parseFloat(m[2]), // user+sys（nice 并入 user）
    breakdown: {
      system: parseFloat(m[2]),
      user: parseFloat(m[1]),
      idle: parseFloat(m[3]),
    },
  };
}

/**
 * top 输出解析：取最后一个「CPU usage:」采样行。
 * 常驻流里即最新一秒的增量；双轮输出（-l 2）即第二轮相对第一轮的增量窗口。
 */
function parseCpuTop(out) {
  const idx = out.lastIndexOf('CPU usage:');
  if (idx < 0) return null;
  return parseCpuTopLine(out.slice(idx));
}

// 常驻流式采样：top -l 0 每秒推一行增量（覆盖 Electron 拿不到的 host_cpu_load_info），
// reader 只取最近一行、近零延迟；取代原先每秒 spawn top -l 2（单次要跑近 2s，
// 把 worker 整轮刷新拖到 3s+，菜单数值明显滞后）。⚠ macOS 的 top -s 只接整数秒。
let cpuStream = null; // { latest, proc }

function ensureCpuStream(spawnFn = require('child_process').spawn) {
  if (cpuStream) return cpuStream;
  const st = { latest: null, proc: null };
  cpuStream = st;
  st.proc = spawnFn('/usr/bin/top', ['-l', '0', '-n', '0', '-s', '1'], { stdio: ['ignore', 'pipe', 'ignore'] });
  const { StringDecoder } = require('string_decoder');
  const decoder = new StringDecoder('utf8');
  let buf = '';
  st.proc.stdout.on('data', (chunk) => {
    buf += decoder.write(chunk);
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!line.includes('CPU usage:')) continue;
      const v = parseCpuTopLine(line);
      if (v) st.latest = v;
    }
  });
  // 流挂掉（进程退出等）后置空，下次 reader 调用重新拉起
  st.proc.on('exit', () => { if (cpuStream === st) cpuStream = null; });
  st.proc.on('error', () => { if (cpuStream === st) cpuStream = null; });
  return st;
}

/** 停掉常驻 top 流（worker 退出时回收孙进程） */
function stopCpuStream() {
  if (cpuStream && cpuStream.proc) cpuStream.proc.kill();
  cpuStream = null;
}

function readCpuTop() {
  const st = ensureCpuStream();
  return st.latest;
}

/** vm_stat 文本 → 字节数（纯解析，便于测试） */
function parseVmStat(out, totalBytes) {
  const pageMatch = /page size of (\d+) bytes/.exec(out);
  if (!pageMatch || !totalBytes) return null;
  const pageSize = parseFloat(pageMatch[1]);
  const pages = {};
  // vm_stat 行形如「Pages free:  1000.」，取 Pages 后面的指标名作键
  for (const m of out.matchAll(/^(\w+\s[\w\s]*?):\s+(\d+)/gm)) pages[m[1]] = parseFloat(m[2]);
  const bytes = (name) => (pages[name] || 0) * pageSize;
  return {
    totalBytes,
    freeBytes: bytes('Pages free'),
    inactiveBytes: bytes('Pages inactive'),
    speculativeBytes: bytes('Pages speculative'),
  };
}

/** mac 内存：vm_stat 页数 × pageSize + sysctl 物理总量（口径同 Swift 版） */
function readMemDarwin() {
  const statOut = execFileSync('/usr/bin/vm_stat', [], { encoding: 'utf8', timeout: 3000 });
  const totalOut = execFileSync('/usr/sbin/sysctl', ['-n', 'hw.memsize'], { encoding: 'utf8', timeout: 3000 });
  return parseVmStat(statOut, parseFloat(totalOut));
}

/** win 内存：GlobalMemoryStatusEx 没有 Node 原生入口，用系统内存总量 - 空闲量近似（free 含可回收缓存） */
function readMemWin() {
  const total = os.totalmem();
  if (!total) return null;
  return { totalBytes: total, freeBytes: os.freemem(), inactiveBytes: 0, speculativeBytes: 0 };
}

/** mac 磁盘：df -k 根卷（1K 块） */
function readDiskDf(timeout = 3000) {
  const out = execFileSync('/bin/df', ['-k', '/'], { encoding: 'utf8', timeout });
  const lines = out.trim().split('\n');
  const cols = (lines[lines.length - 1] || '').split(/\s+/);
  if (cols.length < 4) return null;
  const total = parseFloat(cols[1]) * 1024;
  const avail = parseFloat(cols[3]) * 1024;
  if (!total) return null;
  return { totalBytes: total, availBytes: avail };
}

/** win 磁盘：wmic 系统盘（容量字节） */
function readDiskWin(timeout = 4000) {
  const out = execFileSync('wmic.exe', ['logicaldisk', 'where', 'DeviceID="C:"', 'get', 'Size,FreeSpace', '/value'], {
    encoding: 'utf8',
    timeout,
    windowsHide: true,
  });
  const free = parseFloat(/FreeSpace=(\d+)/.exec(out)?.[1]);
  const total = parseFloat(/Size=(\d+)/.exec(out)?.[1]);
  if (!total) return null;
  return { totalBytes: total, availBytes: free || 0 };
}

/**
 * netstat -ibn 文本 → en* 接口累计字节（纯解析，便于 node 直跑测试）。
 * 口径同 Swift networkRate：只统计物理 en*（排除环回/虚拟/隧道），取链路行的 Ibytes/Obytes。
 * ⚠ 计数列必须从行尾定位：无 Address 的链路行（如 utun/无 MAC）会整体左移一列，
 *   写死 cols[6]/cols[7] 会把 Opkts 当 Obytes；
 * ⚠ 同一 en* 的地址行会重复同一组计数，只能取 `<Link#N>` 那一行，
 *   用「第二列」去重会撞车（第二列其实是 Mtu，所有接口都是 1500 → 只统计到第一个空接口，网络恒为 0）。
 */
function parseNetstatIb(out) {
  const lines = out.trim().split('\n');
  const head = (lines[0] || '').trim().split(/\s+/);
  const TAIL = ['Ipkts', 'Ierrs', 'Ibytes', 'Opkts', 'Oerrs', 'Obytes', 'Coll'];
  // 列布局不认识（老系统没有字节列等）就返回 null，宁可显示「采样中」也不拿包数冒充字节
  if (head.slice(-TAIL.length).join(' ') !== TAIL.join(' ')) return null;
  let rx = 0;
  let tx = 0;
  let hits = 0;
  for (const line of lines.slice(1)) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < TAIL.length + 2) continue;
    if (!/^en\d/.test(cols[0])) continue;
    if (!/^<Link#\d+>\*?$/.test(cols[2])) continue; // 只要链路层行，跳过重复的地址行
    rx += parseFloat(cols[cols.length - 5]) || 0; // Ibytes
    tx += parseFloat(cols[cols.length - 2]) || 0; // Obytes
    hits += 1;
  }
  return hits ? { rx, tx } : null;
}

/** mac 网络：netstat -ibn 只统计 en*（排除虚拟/隧道/环回） */
function readNetDarwin(timeout = 4000) {
  const out = execFileSync('/usr/sbin/netstat', ['-ibn'], { encoding: 'utf8', timeout });
  return parseNetstatIb(out);
}

/** win 网络：netstat -in 接口表以太网行的 In/Out Octets */
function readNetWin(timeout = 4000) {
  const out = execFileSync('netstat.exe', ['-in'], { encoding: 'utf8', timeout, windowsHide: true });
  let rx = 0;
  let tx = 0;
  for (const line of out.split('\n')) {
    const m = /^\s*([\d,]+)\s+([\d,]+)\s+.*Ethernet/.test(line.trim())
      ? line.trim().match(/^([\d,]+)\s+([\d,]+)\s+\S+\s+.*Ethernet/i)
      : null;
    if (m) {
      rx += parseFloat(m[1].replace(/,/g, '')) || 0;
      tx += parseFloat(m[2].replace(/,/g, '')) || 0;
    }
  }
  return { rx, tx };
}

/** win CPU：PowerShell 计数器双采样（typeperf 在中文系统输出 GBK 编码不可靠），直接返回当前占用率 */
function readCpuWin(timeout = 10000) {
  try {
    const out = execFileSync('powershell.exe', [
      '-NoProfile', '-Command',
      "(Get-Counter '\\Processor(_Total)\\% Processor Time' -SampleInterval 1 -MaxSamples 2).CounterSamples.CookedValue",
    ], { encoding: 'utf8', timeout, windowsHide: true });
    const samples = out.split(/\r?\n/).map((s) => parseFloat(s.trim())).filter((v) => Number.isFinite(v));
    if (!samples.length) return null;
    const pct = samples[samples.length - 1];
    return { percent: pct, breakdown: { system: 0, user: pct, idle: Math.max(100 - pct, 0) } };
  } catch (e) {
    console.warn('[system-monitor] powershell 计数器读取失败:', e.message);
    return null;
  }
}

/** 按平台组装默认 reader；Win PowerShell 双采样较慢把 CPU 缓存放宽到 5s（mac 常驻流近零延迟） */
function platformReaders(platform = process.platform) {
  if (platform === 'darwin') {
    return {
      cpu: () => readCpuTop(),
      mem: () => readMemDarwin(),
      disk: () => readDiskDf(),
      net: () => readNetDarwin(),
      cpuStream: true, // worker 退出时需 stopCpuStream 回收常驻 top
      // 常驻流读内存即返最新行，vm_stat/df/netstat 单次仅 2-5ms：缓存归零，
      // 每个 tick 都拿最新值（原 1s 缓存与 1s 轮询周期撞车，约一半帧数值滞后一拍）
      cacheS: { cpu: 0, mem: 0, disk: 0, net: 0 },
    };
  }
  if (platform === 'win32') {
    return {
      cpu: () => readCpuWin(),
      mem: () => readMemWin(),
      disk: () => readDiskWin(),
      net: () => readNetWin(),
      cpuCacheS: 5,
    };
  }
  // 其他平台（Linux 测试环境等）不提供默认采集，接口注入 reader 仍可用
  return null;
}

/**
 * 系统指标监控：采集 + 勾选状态 + 顶栏标题 + 菜单文本。
 * @param {object} deps
 * @param {(key: string) => any} deps.getOption      读勾选状态（config-store）
 * @param {(key: string, value: any) => void} deps.setOption 写勾选状态
 * @param {object} [deps.readers]                   平台采集器（{cpu, mem, disk, net}）
 * @param {() => number} [deps.now]                 毫秒时间源（单测注入假时钟）
 */
class SysInfoMonitor {
  constructor(deps = {}) {
    this.getOption = deps.getOption || (() => false);
    this.setOption = deps.setOption || (() => {});
    this.readers = deps.readers || platformReaders() || {};
    this.now = deps.now || (() => Date.now());
    this.cacheS = { ...DEFAULT_CACHE_S, ...(deps.readers && deps.readers.cacheS ? deps.readers.cacheS : {}), ...(this.readers.cpuCacheS ? { cpu: this.readers.cpuCacheS } : {}) };
    // 网络按字节差值计算：{ rx, tx, atMs }
    this.netBase = null;
    this.cache = {}; // metric -> { atMs, value }
    this.cacheOnly = null; // worker 投喂的只读快照源
  }

  isEnabled(metric) {
    return Boolean(this.getOption(PREF_KEYS[metric]));
  }

  /** 是否有任何指标被勾选（决定顶栏与文本采集是否空转，对齐 Swift anyMetricEnabled） */
  anyEnabled() {
    return METRICS.some((m) => this.isEnabled(m));
  }

  /** 点击菜单项切换勾选：持久化 → 回调（主进程把新勾选同步给 worker 重算顶栏，
   *  对标 Swift toggleSysInfoMetric 的「刷新菜单勾选 + 刷新顶栏文字」） */
  toggle(metric, onAfterToggle) {
    const next = !this.isEnabled(metric);
    this.setOption(PREF_KEYS[metric], next);
    if (onAfterToggle) onAfterToggle();
    return next;
  }

  /** 原始指标 → 派生值（与 Swift 各函数口径一致；差值型指标首次无基线返回 null）*/
  derive(metric, raw, prev, elapsedS) {
    if (!raw) return null;
    if (metric === 'cpu') {
      // CPU reader（top/PowerShell）已返回当前占用率，无需再做差值
      return {
        percent: clampPct(raw.percent),
        breakdown: {
          system: clampPct(raw.breakdown.system),
          user: clampPct(raw.breakdown.user),
          idle: clampPct(raw.breakdown.idle),
        },
      };
    }
    if (metric === 'mem') {
      const total = raw.totalBytes;
      if (!total) return null;
      const reclaim = (raw.freeBytes || 0) + (raw.inactiveBytes || 0) + (raw.speculativeBytes || 0);
      const used = total > reclaim ? total - reclaim : total;
      return {
        percent: clampPct((used / total) * 100),
        usedGB: used / GB,
        totalGB: total / GB,
        breakdown: {
          used: clampPct((used / total) * 100),
          free: clampPct((reclaim / total) * 100),
        },
      };
    }
    if (metric === 'disk') {
      const total = raw.totalBytes;
      if (!total) return null;
      const used = Math.max(total - (raw.availBytes || 0), 0);
      return {
        percent: clampPct((used / total) * 100),
        usedGB: used / GB,
        totalGB: total / GB,
      };
    }
    if (metric === 'net') {
      if (!prev || !(elapsedS > 0)) return null;
      const drx = raw.rx >= prev.rx ? raw.rx - prev.rx : 0;
      const dtx = raw.tx >= prev.tx ? raw.tx - prev.tx : 0;
      return { downKBps: drx / elapsedS / 1024, upKBps: dtx / elapsedS / 1024 };
    }
    return null;
  }

  /** 单指标取值：命中缓存直接返回；差值型指标失败时保留基线，成功则基线前移 */
  getMetric(metric) {
    const reader = this.readers[metric];
    if (!reader) return null;
    const cached = this.cache[metric];
    const t = this.now();
    if (cached && t - cached.atMs < this.cacheS[metric] * 1000) return cached.value;
    const prev = metric === 'net' ? this.netBase : null;
    const elapsedS = prev ? (t - prev.atMs) / 1000 : 0;
    let raw = null;
    try {
      raw = reader();
    } catch (e) {
      console.warn(`[system-monitor] ${metric} 采集失败:`, e.message);
      return cached ? cached.value : null;
    }
    const value = this.derive(metric, raw, prev, elapsedS);
    // 差值型指标（网络）：拿到新原始值就前移基线；失败保留旧基线下次重试
    if (raw && metric === 'net') {
      this.netBase = { ...raw, atMs: t };
    }
    // 成功采到（含无基线的 null）都写缓存，避免采样窗内反复重读（top/df 的 spawn 很贵）
    if (raw) this.cache[metric] = { atMs: t, value };
    return value !== null && value !== undefined ? value : (cached && cached.value ? cached.value : null);
  }
  /**
   * 全量快照（菜单构建与顶栏共用；未勾选也采集环形图展示行，对齐 Swift 环形图始终刷新）。
   * ⚠ 会同步 spawn 采集，只允许在 sysinfo-worker 子进程里调用；主进程用 snapshotCached。
   */
  snapshot() {
    return {
      cpu: this.getMetric('cpu'),
      mem: this.getMetric('mem'),
      disk: this.getMetric('disk'),
      net: this.getMetric('net'),
    };
  }

  /** 强制重采并返回快照（worker 循环专用）：保留缓存窗口语义，
   *  避免 Win 每秒 spawn PowerShell 双采样（CPU 缓存放宽到 5s 天然限频） */
  refresh() {
    return this.snapshot();
  }

  /**
   * 主进程侧只读快照：优先返回采集器（sysinfo-worker 子进程）投喂的缓存，
   * 投喂前为空，避免菜单构建路径同步 spawn 卡住主进程。
   */
  snapshotCached() {
    return this.cacheOnly ? this.cacheOnly.snapshot() : this.snapshot();
  }

  /** 挂上只读快照源（cacheOnly 需实现 snapshot()） */
  setCacheOnly(source) {
    this.cacheOnly = source;
  }

  /**
   * 二级菜单条目文本（格式对齐 Swift refreshSysInfo）。
   * CPU / 内存的百分比由「展示行」（Swift 环形图的替代）呈现，标题只留名称；
   * 无数据（首次采样/平台不支持）时同样只留名称。
   */
  itemLabel(metric, snap = this.snapshot()) {
    const d = snap[metric];
    if (metric === 'disk' && d) {
      return `磁盘  ${Math.round(d.percent)}%（已用 ${d.usedGB.toFixed(1)}GB / 共 ${d.totalGB.toFixed(1)}GB）`;
    }
    if (metric === 'net' && d) {
      return `网络  ↓ ${Math.round(d.downKBps)}KB/s  ↑ ${Math.round(d.upKBps)}KB/s`;
    }
    if (metric === 'cpu') return 'CPU';
    if (metric === 'mem') return '内存';
    return metric;
  }

  /** 展示行：替代 Swift 环形图的文本段（中心总占用 + 图例，整数合计正好 100%） */
  chartLabel(metric, snap = this.snapshot()) {
    if (metric === 'cpu') {
      const bd = snap.cpu && snap.cpu.breakdown;
      if (!bd) return 'CPU 占用  采样中…';
      const sys = Math.round(bd.system);
      const usr = Math.round(bd.user);
      const idle = Math.max(100 - sys - usr, 0);
      return `CPU 占用 ${sys + usr}%\n  系统 ${sys}%  用户 ${usr}%  闲置 ${idle}%`;
    }
    if (metric === 'mem') {
      const bd = snap.mem && snap.mem.breakdown;
      if (!bd) return '内存占用  采样中…';
      const used = Math.round(bd.used);
      const free = Math.max(100 - used, 0);
      return `内存占用 ${used}%\n  已用 ${used}%  空闲 ${free}%`;
    }
    return '';
  }

  /** 二级菜单模板（对标 Swift subMenu：指标条目可勾选，CPU/内存下方挂只读展示行，条目间分隔线）
   *  数值走 snapshotCached（worker 投喂的缓存），点击到菜单出现之间不同步 spawn */
  buildMenuTemplate(onAfterToggle) {
    const snap = this.snapshotCached();
    const items = [];
    const pushMetric = (metric) => {
      items.push({
        label: this.itemLabel(metric, snap),
        type: 'checkbox',
        checked: this.isEnabled(metric),
        click: () => this.toggle(metric, onAfterToggle),
      });
      if (metric === 'cpu' || metric === 'mem') {
        // 环形图的文本替身：只读展示行，不可点（对标 Swift cpuChartItem.isEnabled = false）
        items.push({ label: this.chartLabel(metric, snap), enabled: false });
      }
      items.push({ type: 'separator' });
    };
    for (const metric of METRICS) pushMetric(metric);
    items.pop(); // 末尾不要分隔线
    return items;
  }

  /** 顶栏标题：图标旁的「图标 数值」串（对齐 Swift buildMetricTitle，Electron 无富文本 API，用 Unicode 字形代 SF Symbol）。
   *  主进程实际由 worker 算好后回传，这里供测试与同口径复用 */
  trayTitle(snap = this.snapshotCached()) {
    return computeTrayTitle(snap, (m) => this.isEnabled(m));
  }

  /** 顶栏结构化指标（mac 合成图用；与 trayTitle 同一份数据，不会出现两种口径） */
  trayParts(snap = this.snapshotCached()) {
    return computeTrayParts(snap, (m) => this.isEnabled(m));
  }
}

/** 纯函数版顶栏指标（worker 子进程与主进程共用，isEnabled 由调用方注入）
 *  与 Swift refreshMenuBarMetrics 逐项对齐：勾选且采到值才出一项，数值取整 */
function computeTrayParts(snap, isEnabled) {
  const parts = [];
  if (isEnabled('cpu') && snap.cpu) parts.push({ metric: 'cpu', symbol: METRIC_SYMBOLS.cpu, text: `${Math.round(snap.cpu.percent)}%` });
  if (isEnabled('mem') && snap.mem) parts.push({ metric: 'mem', symbol: METRIC_SYMBOLS.mem, text: `${Math.round(snap.mem.percent)}%` });
  if (isEnabled('disk') && snap.disk) parts.push({ metric: 'disk', symbol: METRIC_SYMBOLS.disk, text: `${Math.round(snap.disk.percent)}%` });
  if (isEnabled('net') && snap.net) {
    parts.push({
      metric: 'net',
      symbol: METRIC_SYMBOLS.net,
      text: `${Math.round(snap.net.downKBps)}K/${Math.round(snap.net.upKBps)}K`,
    });
  }
  return parts;
}

/** 纯函数版回落标题（无合成图素材时用）
 *  格式对齐 Swift：图标紧跟数值，指标之间两个空格（无勾选返回空串） */
function computeTrayTitle(snap, isEnabled) {
  if (!METRICS.some(isEnabled)) return '';
  return computeTrayParts(snap, isEnabled).map((p) => `${METRIC_ICONS[p.metric]}${p.text}`).join('  ');
}

module.exports = {
  SysInfoMonitor,
  METRICS,
  METRIC_ICONS,
  METRIC_SYMBOLS,
  PREF_KEYS,
  platformReaders,
  computeTrayTitle,
  computeTrayParts,
  parseCpuTop,
  parseCpuTopLine,
  ensureCpuStream,
  stopCpuStream,
  parseVmStat,
  readCpuTop,
  readCpuWin,
  readMemDarwin,
  readMemWin,
  readDiskDf,
  readDiskWin,
  parseNetstatIb,
  readNetDarwin,
  readNetWin,
};
