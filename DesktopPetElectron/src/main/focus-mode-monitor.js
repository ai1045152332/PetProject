// src/main/focus-mode-monitor.js
// 系统勿扰 / 专注模式监视器（对标 mac 原生版 Services/FocusModeMonitor.swift）：
// 只读检测，绝不写系统状态。系统处于勿扰/专注时宠物走 focus，退出后回到 idel。
// 平台差异：
// - macOS：读 ~/Library/DoNotDisturb/DB/Assertions.json，存在活跃断言即视为勿扰开启；
//   该文件被系统频繁整份替换，因此用 fs.watch 盯目录 + 1s 兜底轮询（与 Swift 版同策略）。
// - Windows：注册表没有可靠的实时值（Win11 把状态挪进了 CloudStore 加密 blob），
//   这里读仍公开写入的 ContentDeliveryManager 键，读不到即判为未开启（宠物保持休闲），
//   判定失败绝不能影响宠物本身。
// - 其它平台（Linux 等）：无对应能力，恒为未开启。
// 与 electron / 定时器解耦：检测函数纯读文件/注册表，轮询由调用方驱动，便于 node 直跑单测。
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const DND_RELATIVE_PATH = path.join('Library', 'DoNotDisturb', 'DB', 'Assertions.json');
// Windows 专注助手（旧称 Quiet Hours）在注册表里的几个候选值，按新→旧排列
const WIN_FOCUS_NAMES = ['Windows.System.FocusAssistAppStateEnabled', 'QuietHours'];
const WIN_FOCUS_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager';
// 兜底轮询间隔：目录监听通常毫秒级感知，文件只有几 KB，1s 一次开销可忽略（与 Swift 版一致）
const POLL_INTERVAL_MS = 1000;

/** 勿扰断言文件路径（home 可注入，单测用） */
function assertionsPath(home = os.homedir()) {
  return path.join(home, DND_RELATIVE_PATH);
}

/**
 * 解析 macOS 勿扰断言 JSON：任意一段结构对不上都判为「未开启」，不抛错。
 * 实测 macOS 15：勿扰开启时 data[0].storeAssertionRecords 会出现活跃断言，
 * 关闭时该数组为空（断言移入 storeInvalidationRecords）。
 */
function parseMacFocusAssertions(raw) {
  let json;
  try {
    json = JSON.parse(raw);
  } catch {
    return false;
  }
  if (!json || !Array.isArray(json.data)) return false;
  return json.data.some(
    (record) => record
      && Array.isArray(record.storeAssertionRecords)
      && record.storeAssertionRecords.length > 0,
  );
}

/**
 * 解析 reg query 输出：取最后一个十六进制值（与 app-info.js 读 MachineGuid 同一套容错）。
 * 输出里没有值（键不存在 / 权限不足）返回 null，由调用方回落。
 */
function parseRegQueryValue(output, name) {
  const lines = String(output || '').split(/\r?\n/);
  const idx = lines.findIndex((l) => l.trim().toUpperCase().startsWith(String(name).toUpperCase()));
  if (idx < 0) return null;
  for (let i = idx; i < lines.length; i += 1) {
    const m = lines[i].match(/REG_(?:DWORD_\w+|DWORD)\s+(\S+)/i);
    if (m) return m[1];
  }
  return null;
}

/** 是否处于专注（Windows：候选值任一为 1 即算开启） */
function isWinFocusEnabled(rawHexValue) {
  if (rawHexValue == null) return false;
  return Number.parseInt(String(rawHexValue), 16) === 1;
}

/**
 * 同步检测一次系统勿扰/专注状态（纯读，无副作用）。
 * @param {object} [deps]
 * @param {NodeJS.Platform} [deps.platform]
 * @param {() => string} [deps.home]
 * @returns {boolean}
 */
function detectSync({ platform = process.platform, home = os.homedir } = {}) {
  if (platform === 'darwin') {
    try {
      return parseMacFocusAssertions(fs.readFileSync(assertionsPath(typeof home === 'function' ? home() : home), 'utf8'));
    } catch {
      return false;
    }
  }
  // Windows 走注册表需要子进程，这里给不出同步结果时由异步轮询覆盖；
  // 同步入口仅供启动时先取一个保守初值（未开启）。
  return false;
}

/**
 * 异步检测一次（Windows 用；mac 也能用，走同一份文件读取）。
 * @param {object} [deps] platform / home / exec（可注入便于单测）
 * @returns {Promise<boolean>}
 */
function detectFocusMode({
  platform = process.platform,
  home = os.homedir,
  exec = execFile,
} = {}) {
  if (platform === 'darwin') {
    return new Promise((resolve) => {
      const file = assertionsPath(typeof home === 'function' ? home() : home);
      fs.readFile(file, 'utf8', (err, raw) => resolve(!err && parseMacFocusAssertions(raw)));
    });
  }
  if (platform !== 'win32') return Promise.resolve(false);
  return new Promise((resolve) => {
    const query = (name) => new Promise((done) => {
      exec('reg', ['query', WIN_FOCUS_KEY, '/v', name], { windowsHide: true }, (err, stdout) => {
        done(!err && isWinFocusEnabled(parseRegQueryValue(stdout, name)));
      });
    });
    // 逐个试：任何一个读到 1 就是专注；全部读不到（Win11 常态）判为未开启
    WIN_FOCUS_NAMES.reduce(
      (chain, name) => chain.then((active) => (active ? true : query(name))),
      Promise.resolve(false),
    ).then(resolve);
  });
}

/**
 * 启动监视：轮询 + macOS 目录监听，状态变化才回调。
 * @param {object} [opts]
 * @param {(active: boolean) => void} opts.onChange 状态变化（主线程语义，Node 事件循环天然满足）
 * @param {object} [opts.platform]  platform / home / setIntervalFn / clearIntervalFn / watchFn 均可注入（单测用）
 * @returns {{stop: () => void, checkNow: () => Promise<void>}}
 */
function startFocusModeMonitor({
  onChange,
  platform = process.platform,
  home = os.homedir,
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval,
  watchFn = fs.watch,
  pollMs = POLL_INTERVAL_MS,
} = {}) {
  let active = false;
  let stopped = false;
  let timer = null;
  let watcher = null;

  const apply = (next) => {
    if (stopped || next === active) return;
    active = next;
    console.log(`[focus-mode] 系统勿扰/专注状态变化 → ${next ? '已开启(专注)' : '已关闭(休闲)'}`);
    if (onChange) onChange(next);
  };

  const checkNow = async () => {
    if (stopped) return;
    try {
      apply(await detectFocusMode({ platform, home }));
    } catch (e) {
      // 检测异常一律当作未开启，绝不让宠物状态机挂掉
      apply(false);
    }
  };

  active = detectSync({ platform, home });
  timer = setIntervalFn(checkNow, pollMs);
  if (typeof timer === 'object' && typeof timer.unref === 'function') timer.unref();

  // macOS 才有意义：系统频繁整份替换断言文件，盯目录比盯文件更稳（其它平台只靠轮询）
  if (platform === 'darwin') {
    try {
      const dir = path.dirname(assertionsPath(typeof home === 'function' ? home() : home));
      watcher = watchFn(dir, () => checkNow());
      if (watcher && typeof watcher.unref === 'function') watcher.unref();
      if (watcher) watcher.on('error', () => { /* 监听失效交给轮询兜底 */ });
    } catch {
      watcher = null;
    }
  }

  console.log(`[focus-mode] 监视已启动（${platform}），当前系统勿扰状态: ${active}`);

  return {
    checkNow,
    stop() {
      stopped = true;
      if (timer) clearIntervalFn(timer);
      timer = null;
      if (watcher) {
        try { watcher.close(); } catch { /* 忽略 */ }
        watcher = null;
      }
    },
  };
}

/** 专注对应的宠物基准态（mac 版 systemFocusActive ? .focus : .idel） */
function petStateForFocusMode(active) {
  return active ? 'focus' : 'idel';
}

module.exports = {
  startFocusModeMonitor,
  detectFocusMode,
  petStateForFocusMode,
  detectSync,
  parseMacFocusAssertions,
  parseRegQueryValue,
  isWinFocusEnabled,
  assertionsPath,
  POLL_INTERVAL_MS,
};
