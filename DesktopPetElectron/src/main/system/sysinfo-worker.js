// src/main/sysinfo-worker.js
// 「系统信息」采集子进程：把 top / netstat / vm_stat / df 等同步 spawn 挪出主进程。
// 根因：菜单构建原先在主进程同步采样（top -l 2 自身要跑约 1 秒），点托盘图标会卡死整个应用。
// 方案：worker 每秒 refresh 一次并把快照投喂回主进程（cache-only 快照源），
//       顶栏标题也在 worker 算好回传（勾选状态由主进程 IPC 同步过来），主进程零采集零阻塞。
// fork 出的普通 Node 进程不随 app.quit 自动回收，退出必须 killWorker()。
'use strict';

const path = require('path');
const { fork } = require('child_process');
const { SysInfoMonitor, platformReaders, METRICS, computeTrayTitle, computeTrayParts, stopCpuStream } = require('./system-monitor');

const POLL_INTERVAL_MS = 1000;

// ── 子进程侧 ──

/** 纯函数：由勾选状态与 reader 建监控器（与主进程共用，便于 node 直跑测试） */
function buildWorkerMonitor(enabled, readers) {
  return new SysInfoMonitor({
    getOption: (key) => Boolean(enabled[key]),
    setOption: () => {},
    readers,
  });
}

/** 顶栏一条消息：回落用的纯文字标题 + mac 合成图用的结构化 parts */
function titleMessage(snap, isEnabled) {
  return { type: 'enabled', title: computeTrayTitle(snap, isEnabled), parts: computeTrayParts(snap, isEnabled) };
}

/** 采集主循环：先建网络字节基线，之后每秒 refresh 并把 {type:'snapshot'} / {type:'enabled'} 发给主进程 */
function runWorkerLoop(monitor, send, schedule = (fn, ms) => setTimeout(fn, ms)) {
  let stopped = false;
  const stoppedSend = (msg) => { if (!stopped) send(msg); };
  // 先喂 enabled，主进程首帧标题即可正确计算
  stoppedSend(titleMessage(monitor.snapshot(), (m) => monitor.isEnabled(m)));
  schedule(function tick() {
    if (stopped) return;
    let snap = null;
    try {
      snap = monitor.refresh();
    } catch (e) {
      console.error('[sysinfo-worker] 采集异常:', e.message);
    }
    if (snap) {
      stoppedSend({ type: 'snapshot', snap });
      stoppedSend(titleMessage(snap, (m) => monitor.isEnabled(m)));
    }
    if (!stopped) schedule(tick, POLL_INTERVAL_MS);
  }, 0);
  return { stop() { stopped = true; } };
}

/** 子进程入口（node 直跑该文件时触发） */
function workerMain() {
  const enabled = {};
  let monitor = null;
  let loop = null;

  process.on('message', (msg) => {
    if (!msg || typeof msg !== 'object') return;
    if (msg.type === 'init' && !monitor) {
      // reader 不随 IPC 传递（子进程收不到函数），子进程自己组装平台采集器
      const readers = platformReaders();
      if (!readers) return;
      Object.assign(enabled, msg.enabled || {});
      monitor = buildWorkerMonitor(enabled, readers);
      loop = runWorkerLoop(monitor, (m) => process.send(m));
    } else if (msg.type === 'enabled' && monitor) {
      // 主进程勾选变化实时同步：worker 不写配置，重建监控器以携带最新勾选（顺带重置基线）
      Object.assign(enabled, msg.enabled || {});
      if (loop) loop.stop();
      monitor = buildWorkerMonitor(enabled, monitor.readers);
      loop = runWorkerLoop(monitor, (m) => process.send(m));
    }
  });
  // 退出时回收常驻 top 流（孙进程）
  process.on('exit', () => stopCpuStream());
  // 主进程退出（含崩溃）即自杀，防孤儿进程
  setInterval(() => { if (!process.connected) process.exit(0); }, 2000).unref();
}

// ── 主进程侧 ──

/** 只读快照源：存 worker 投喂的最新快照，任何路径都不触发采集 */
function createCacheOnlySnapshot() {
  let snap = { cpu: null, mem: null, disk: null, net: null };
  return {
    apply(next) { snap = { ...snap, ...next }; },
    snapshot() { return snap; },
  };
}

/**
 * 启动采集 worker 并接好双向消息。
 * @param {object} deps
 * @param {(key: string) => any} deps.getOption     读勾选状态（发 init 与勾选变化时同步给 worker）
 * @param {(snap: object) => void} deps.onSnapshot  收到新快照（投喂只读缓存）
 * @param {(title: string, parts: Array) => void} deps.onTitle  收到算好的顶栏标题与结构化指标
 * @returns {{postEnabled: () => void, kill: () => void}}
 */
function startWorker(deps) {
  const child = fork(path.join(__dirname, 'sysinfo-worker.js'), [], { silent: true });
  child.on('message', (msg) => {
    if (!msg || typeof msg !== 'object') return;
    if (msg.type === 'snapshot') deps.onSnapshot(msg.snap);
    else if (msg.type === 'enabled') deps.onTitle(msg.title || '', msg.parts || []);
  });
  child.on('error', (e) => console.error('[sysinfo-worker] 通信异常:', e.message));
  child.on('exit', (code) => console.log(`[sysinfo-worker] 退出 code=${code}`));
  // readers 不跨 IPC（函数无法序列化），子进程自行组装
  child.send({ type: 'init', enabled: enabledMap(deps.getOption) });
  return {
    /** 勾选变化后同步给 worker（worker 会重建监控器并回传新标题） */
    postEnabled() {
      if (child.connected) child.send({ type: 'enabled', enabled: enabledMap(deps.getOption) });
    },
    kill() {
      if (child.connected) child.disconnect();
      child.kill();
    },
  };
}

function enabledMap(getOption) {
  const map = {};
  for (const m of METRICS) map[getOptionKey(m)] = Boolean(getOption(getOptionKey(m)));
  return map;
}

function getOptionKey(metric) {
  // 与 system-monitor 的 PREF_KEYS 一致（不 import 避免主/子共用模块时循环依赖顾虑）
  return { cpu: 'menuBar.showCPU', mem: 'menuBar.showMemory', disk: 'menuBar.showDisk', net: 'menuBar.showNet' }[metric];
}

// 作为子进程被 node 直接运行时进入采集循环；被 require 时只提供上述接口
if (require.main === module) workerMain();

module.exports = { startWorker, createCacheOnlySnapshot, buildWorkerMonitor, runWorkerLoop, titleMessage, workerMain, POLL_INTERVAL_MS };
