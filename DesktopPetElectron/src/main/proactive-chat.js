// src/main/proactive-chat.js
// 主动搭话调度器（移植 mac 版 PetViewModel 的 proactiveChat 一组：startProactiveChat /
// restartProactiveChat / sayGreeting / performProactiveChat / refreshNewsCache / randomNewsHeadline）
// 台词一律走宠物头顶气泡（speech-bubble），数据源是「热搜 + 本机 Todo」：
//   · 启动 20 秒后先来一句时段问候（带今日 Todo 数量），之后进入周期搭话
//   · 周期搭话在热搜 / Todo 之间轮换，避免总聊同一主题；缺一边时用另一边兜底，都没有就说鼓励语
//   · 热搜每 30 分钟后台刷一次缓存，搭话时随机挑一条（连续两次不重复）
// 勿扰/专注模式、睡觉、躲藏、一次性动画（抚摸）期间都不打扰（与 mac 版守卫一致）。
// 与 IPC / 窗口解耦，网络与定时器都可注入，便于 node 直跑单测。
'use strict';

const config = require('./config-store');

// 对齐 mac 版 PetViewModel 的同名常量
const DEFAULT_CHAT_INTERVAL = 30;   // 分钟
const MIN_CHAT_INTERVAL = 1;
const MAX_CHAT_INTERVAL = 720;
const FIRST_DELAY_SECONDS = 20;     // 启动后首句延迟（给热搜缓存留拉取时间）
const NEWS_REFRESH_SECONDS = 1800;  // 热搜缓存刷新间隔
const HEADLINE_POOL = 10;           // 只用前 10 条热搜
const HEADLINE_MAX_CHARS = 20;      // 标题截断长度（气泡别撑太宽）

const ENABLED_KEY = 'proactiveChatEnabled';
const INTERVAL_KEY = 'proactiveChatIntervalMinutes';

/** 间隔收敛：脏数据回落默认 30 分钟 */
function clampChatInterval(value) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < MIN_CHAT_INTERVAL) return DEFAULT_CHAT_INTERVAL;
  return Math.min(MAX_CHAT_INTERVAL, n);
}

function currentChatInterval() {
  return clampChatInterval(config.get(INTERVAL_KEY));
}

/** 是否开启主动搭话（默认开启，与 mac 版「没设置过时为 true」一致） */
function proactiveChatEnabled() {
  const saved = config.get(ENABLED_KEY);
  if (saved === undefined || saved === null || saved === '') return true;
  return Boolean(saved);
}

/** 按时段给出问候语（mac 版 timeGreeting） */
function timeGreeting(date = new Date()) {
  const hour = date.getHours();
  if (hour >= 5 && hour < 11) return '早上好 ☀️';
  if (hour >= 11 && hour < 13) return '中午好 🍚';
  if (hour >= 13 && hour < 18) return '下午好 ☕';
  if (hour >= 18 && hour < 23) return '晚上好 🌙';
  return '夜深了 🌌';
}

/** 兜底鼓励语（mac 版 encouragement） */
function encouragement(pool = Math.random) {
  const lines = ['休息一下，看看远处 🌿', '喝口水吧 💧', '你专注的样子很好看 ✨', '别太累，摸我一下放松下 🐾'];
  return lines[Math.floor(pool() * lines.length)] || '喵～';
}

/** 截断过长标题，避免气泡过宽（mac 版 truncate） */
function truncate(text, limit = HEADLINE_MAX_CHARS) {
  const s = String(text || '');
  return s.length <= limit ? s : `${s.slice(0, limit)}…`;
}

/**
 * 创建搭话调度器。
 * @param {object} deps
 * @param {(text: string) => void} deps.say 台词出口（气泡窗）
 * @param {() => Promise<Array<{title: string}>>|Array<{title: string}>} [deps.fetchHeadlines] 热搜源（news-service）
 * @param {() => number} [deps.todoCount] 本机 Todo 条数
 * @param {() => boolean} [deps.isSystemFocusActive] 系统勿扰/专注模式是否开着
 * @param {() => string} [deps.getPetState] 宠物当前形象（sleep / hide 时不打扰）
 * @param {() => boolean} [deps.isPlayingOneShot] 一次性动画播放中（抚摸时不打扰）
 * @param {Function} [deps.setTimer] 可注入定时器（单测用）
 * @param {Function} [deps.clearTimer] 可注入取消定时器（单测用）
 * @param {Function} [deps.random] 可注入随机源（单测用）
 */
function createProactiveChat(deps = {}) {
  const setT = deps.setTimer || setTimeout;
  const clearT = deps.clearTimer || clearTimeout;
  const random = deps.random || Math.random;

  let newsTimer = null;   // 热搜缓存定时刷新
  let firstTimer = null;  // 启动首句
  let repeatTimer = null; // 周期搭话
  let headlines = [];     // 热搜缓存（只存标题）
  let lastSpoken = null;  // 上次搭话说过的热搜（连续两次不重复）
  let tick = 0;           // 轮换计数（偶数优先聊热搜，奇数优先聊 Todo）

  /** 后台刷新热搜缓存（失败保持旧缓存，不打扰用户） */
  async function refreshNewsCache() {
    if (!deps.fetchHeadlines) return;
    try {
      const items = await deps.fetchHeadlines();
      headlines = (Array.isArray(items) ? items : [])
        .slice(0, HEADLINE_POOL)
        .map((item) => (item && item.title ? String(item.title) : ''))
        .filter((title) => title.length > 0);
      console.log(`[proactive-chat] 热搜缓存刷新: ${headlines.length} 条${headlines.length ? `，首条「${truncate(headlines[0], 12)}」` : ''}`);
    } catch (e) {
      console.warn(`[proactive-chat] 热搜缓存刷新失败: ${e.message}`);
    }
  }

  /** 从缓存里随机挑一条（避开上次说过的那条；池里只剩一条时无可避免） */
  function pickHeadline() {
    if (!headlines.length) return null;
    let pool = headlines;
    if (lastSpoken && pool.length > 1) pool = pool.filter((title) => title !== lastSpoken);
    const picked = pool[Math.floor(random() * pool.length)] || pool[0] || null;
    if (picked) lastSpoken = picked;
    return picked;
  }

  /** 陪伴式搭话只在「宠物醒着、不在躲藏、没在播一次性动画、系统不专注」时进行 */
  function canChat() {
    if (!proactiveChatEnabled()) return false;
    if (deps.isSystemFocusActive && deps.isSystemFocusActive()) return false;
    const state = deps.getPetState ? deps.getPetState() : 'idel';
    if (state === 'sleep' || state === 'hide') return false;
    if (deps.isPlayingOneShot && deps.isPlayingOneShot()) return false;
    return true;
  }

  /** 启动首句：时段问候 +（若有）今日 Todo 数量 */
  function sayGreeting() {
    if (!canChat()) return;
    const count = deps.todoCount ? deps.todoCount() : 0;
    const greet = timeGreeting();
    deps.say(count > 0 ? `${greet}｜今天你有 ${count} 个 Todo 📝` : `${greet}｜今天没有待办，轻松一下～`);
  }

  /** 周期主动搭话：热搜 / Todo 轮换，缺数据时相互兜底 */
  function performProactiveChat() {
    if (!canChat()) return;
    tick += 1;
    const count = deps.todoCount ? deps.todoCount() : 0;
    const headline = pickHeadline();
    if (tick % 2 === 0 && headline) {
      deps.say(`热搜在聊「${truncate(headline)}」🔥 右键看今日热点～`);
      return;
    }
    if (count > 0) {
      deps.say(`今天你还有 ${count} 个 Todo 没完成 📝 加油～`);
      return;
    }
    if (headline) {
      deps.say(`热搜在聊「${truncate(headline)}」🔥`);
      return;
    }
    deps.say(encouragement(random));
  }

  /** 按当前间隔重建周期搭话定时器（改完立即生效，不重跑启动首句） */
  function restartRepeat() {
    if (repeatTimer) clearT(repeatTimer);
    repeatTimer = null;
    const minutes = currentChatInterval();
    repeatTimer = setT(() => performProactiveChat(), minutes * 60 * 1000);
    if (typeof repeatTimer.unref === 'function') repeatTimer.unref();
  }

  return {
    /** 启动：先拉一次热搜，再挂缓存刷新、首句与周期搭话 */
    start() {
      refreshNewsCache();
      newsTimer = setT(() => {
        refreshNewsCache();
        restartRepeat(); // 每轮周期里顺带按最新间隔校准（改配置后最迟一轮生效）
      }, NEWS_REFRESH_SECONDS * 1000);
      if (typeof newsTimer.unref === 'function') newsTimer.unref();
      firstTimer = setT(() => {
        firstTimer = null;
        sayGreeting();
        restartRepeat();
      }, FIRST_DELAY_SECONDS * 1000);
      if (typeof firstTimer.unref === 'function') firstTimer.unref();
      console.log(`[proactive-chat] 已启动，间隔 ${currentChatInterval()} 分钟`);
    },

    /** 设置面板改了间隔或开关：立即按新节奏重建周期搭话（对齐 mac 版 restartProactiveChat） */
    restart() {
      restartRepeat();
    },

    stop() {
      for (const timer of [newsTimer, firstTimer, repeatTimer]) {
        if (timer) clearT(timer);
      }
      newsTimer = firstTimer = repeatTimer = null;
    },

    // 以下导出供单测直接验证台词逻辑
    sayGreeting,
    performProactiveChat,
    refreshNewsCache,
    pickHeadline,
    get headlineCount() {
      return headlines.length;
    },
  };
}

module.exports = {
  createProactiveChat,
  proactiveChatEnabled,
  currentChatInterval,
  clampChatInterval,
  timeGreeting,
  encouragement,
  truncate,
  ENABLED_KEY,
  INTERVAL_KEY,
  DEFAULT_CHAT_INTERVAL,
  MIN_CHAT_INTERVAL,
  MAX_CHAT_INTERVAL,
  CHAT_PRESETS: [15, 30, 60],
  FIRST_DELAY_SECONDS,
  NEWS_REFRESH_SECONDS,
};
