// src/main/proactive-chat.js
// 主动搭话调度器（移植 mac 版 PetViewModel 的 proactiveChat 一组：startProactiveChat /
// restartProactiveChat / sayGreeting / performProactiveChat / randomNewsHeadline）
// 台词一律走宠物头顶气泡（speech-bubble），数据源是「热搜 + 本机 Todo」：
//   · 启动 20 秒后先来一句时段问候（带今日 Todo 数量），之后进入周期搭话
//   · 周期搭话在热搜 / Todo 之间轮换，避免总聊同一主题；缺一边时用另一边兜底，都没有就说鼓励语
//   · 热搜与天气都由服务端带 TTL 缓存（GET /api/news、/api/weather），客户端每次现取、本地不留缓存；
//     搭话时从这次拿到的榜单里随机挑一条（连续两次不重复）
// 勿扰/专注模式、睡觉、躲藏、一次性动画（抚摸）期间都不打扰（与 mac 版守卫一致）。
// 与 IPC / 窗口解耦，网络与定时器都可注入，便于 node 直跑单测。
'use strict';

const config = require('../core/config-store');

// 对齐 mac 版 PetViewModel 的同名常量
const DEFAULT_CHAT_INTERVAL = 30;   // 分钟
const MIN_CHAT_INTERVAL = 1;
const MAX_CHAT_INTERVAL = 720;
const FIRST_DELAY_SECONDS = 20;     // 启动后首句延迟
const HEADLINE_POOL = 10;           // 只用前 10 条热搜
const HEADLINE_MAX_CHARS = 20;      // 标题截断长度（气泡别撑太宽）

const ENABLED_KEY = 'proactiveChatEnabled';
const INTERVAL_KEY = 'proactiveChatIntervalMinutes';
const TOPICS_KEY = 'proactiveChatTopics';

// 搭话内容（设置面板「消息提醒 → 搭话内容」可勾选）：热点新闻 / 今日 Todo / 关心问候
const TOPIC_NEWS = 'news';
const TOPIC_TODO = 'todo';
const TOPIC_CARE = 'care';
const ALL_TOPICS = [TOPIC_NEWS, TOPIC_TODO, TOPIC_CARE];
const TOPIC_LABELS = {
  [TOPIC_NEWS]: '热点新闻',
  [TOPIC_TODO]: '今日 Todo',
  [TOPIC_CARE]: '关心问候',
};

/** 归一化勾选的内容：未知 key 丢掉，缺省（没设置过）为全开 */
function normalizeTopics(value) {
  if (!Array.isArray(value)) return ALL_TOPICS.slice();
  const picked = new Set(value.filter((key) => ALL_TOPICS.includes(key)));
  return ALL_TOPICS.filter((key) => picked.has(key));
}

/** 当前勾选的搭话内容（顺序固定：新闻 → Todo → 天气 → 关心问候） */
function currentTopics() {
  return normalizeTopics(config.get(TOPICS_KEY));
}

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

/** 关心问候语（比兜底鼓励语更"聊天"，用于「消息提醒 → 关心问候」勾选时） */
function careLine(pool = Math.random) {
  const lines = [
    '在忙什么呢？要不要歇两分钟 🐾',
    '我一直在这儿陪着你呢～',
    '伸个懒腰吧，肩膀放松一下 🌿',
    '今天也辛苦啦，记得好好吃饭 🍚',
    '有点想你了，摸我一下？🐱',
  ];
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

  let firstTimer = null;  // 启动首句
  let repeatTimer = null; // 周期搭话
  let lastSpoken = null;  // 上次搭话说过的热搜（连续两次不重复）
  let tick = 0;           // 轮换计数：在「有料的」话题之间轮着说

  /** 现取热搜（服务端有 TTL 缓存，这里不落地；没勾热点新闻就不请求） */
  async function fetchHeadlinesNow() {
    if (!deps.fetchHeadlines) return [];
    if (!currentTopics().includes(TOPIC_NEWS)) return [];
    try {
      const items = await deps.fetchHeadlines();
      return (Array.isArray(items) ? items : [])
        .slice(0, HEADLINE_POOL)
        .map((item) => (item && item.title ? String(item.title) : ''))
        .filter((title) => title.length > 0);
    } catch (e) {
      console.warn(`[proactive-chat] 热搜获取失败: ${e.message}`);
      return [];
    }
  }

  /** 从榜单里随机挑一条（避开上次说过的那条；池里只剩一条时无可避免） */
  function pickHeadline(list) {
    const pool0 = Array.isArray(list) ? list : [];
    if (!pool0.length) return null;
    let pool = pool0;
    if (lastSpoken && pool.length > 1) pool = pool.filter((title) => title !== lastSpoken);
    const picked = pool[Math.floor(random() * pool.length)] || pool[0] || null;
    if (picked) lastSpoken = picked;
    return picked;
  }

  /** 陪伴式搭话只在「宠物醒着、不在躲藏、没在播一次性动画、系统不专注」时进行 */
  function canChat() {
    if (!proactiveChatEnabled()) return '已关闭主动搭话';
    if (deps.isSystemFocusActive && deps.isSystemFocusActive()) return '系统勿扰/专注中';
    const state = deps.getPetState ? deps.getPetState() : 'idel';
    if (state === 'sleep') return '宠物在睡觉';
    if (state === 'hide') return '宠物躲藏中';
    if (deps.isPlayingOneShot && deps.isPlayingOneShot()) return '正在播一次性动画';
    return '';
  }

  /** 统一出口：气泡没显示（宠物窗不可见等）时留下线索，避免「静默失败」 */
  function saySafe(text) {
    const ok = deps.say ? deps.say(text) : false;
    if (ok === false) console.warn(`[proactive-chat] 台词没显示出来（宠物窗可能不可见）: ${text}`);
    return ok;
  }

  /** 给热搜拉取加个上限：网络半开时不能把整轮搭话卡在 await 上 */
  function withTimeout(promise, ms, fallback) {
    return Promise.race([
      promise,
      new Promise((resolve) => {
        const t = setT(() => resolve(fallback), ms);
        if (t && typeof t.unref === 'function') t.unref();
      }),
    ]);
  }

  /** 启动首句：时段问候 +（若有）今日 Todo 数量 */
  function sayGreeting() {
    const blocked = canChat();
    if (blocked) { console.log(`[proactive-chat] 跳过问候：${blocked}`); return; }
    const count = deps.todoCount ? deps.todoCount() : 0;
    const greet = timeGreeting();
    saySafe(count > 0 ? `${greet}｜今天你有 ${count} 个 Todo 📝` : `${greet}｜今天没有待办，轻松一下～`);
  }

  /**
   * 周期主动搭话：只在「勾选且当前有料」的话题之间轮换。
   * 新闻每次现取（服务端有 TTL 缓存），本地不存；都没有时退回关心问候。
   */
  async function performProactiveChat() {
    const blocked = canChat();
    if (blocked) { console.log(`[proactive-chat] 跳过本轮：${blocked}`); return; }
    const topics = currentTopics();
    const count = deps.todoCount ? deps.todoCount() : 0;
    // 没勾热点新闻就不发请求；拉取最多等 5 秒，超时按「没有热搜」继续，绝不卡住这一轮
    const headlineList = topics.includes(TOPIC_NEWS)
      ? await withTimeout(fetchHeadlinesNow(), 5000, [])
      : [];
    const headline = topics.includes(TOPIC_NEWS) ? pickHeadline(headlineList) : null;
    const candidates = [];
    if (headline) candidates.push(TOPIC_NEWS);
    if (topics.includes(TOPIC_TODO) && count > 0) candidates.push(TOPIC_TODO);
    if (topics.includes(TOPIC_CARE)) candidates.push(TOPIC_CARE);

    if (!candidates.length) {
      console.log('[proactive-chat] 跳过本轮：勾选的内容都没有素材（无热搜 / 无 Todo）');
      return;
    }
    tick += 1;
    // 固定顺序轮转（新闻 → Todo → 关心问候），第一句从第一个「有料」的话题开始
    const topic = candidates[(tick - 1) % candidates.length];
    let line;
    if (topic === TOPIC_NEWS) line = `热搜在聊「${truncate(headline)}」🔥 右键看今日热点～`;
    else if (topic === TOPIC_TODO) line = `今天你还有 ${count} 个 Todo 没完成 📝 加油～`;
    else line = careLine(random);
    const ok = saySafe(line);
    console.log(`[proactive-chat] 搭话（${TOPIC_LABELS[topic]}${ok ? '' : '·未显示'}）：${line}`);
  }

  /**
   * 按当前间隔重建周期搭话定时器（改完立即生效，不重跑启动首句）。
   * 用「跑完一次再按最新间隔重挂」代替 setInterval：既对齐 mac 版 repeats 的节律，
   * 又让间隔被改小/改大后下一轮就采用新值，不必等到旧周期结束。
   */
  function restartRepeat() {
    if (repeatTimer) clearT(repeatTimer);
    repeatTimer = null;
    const minutes = currentChatInterval();
    repeatTimer = setT(() => {
      repeatTimer = null;
      performProactiveChat();
      restartRepeat();
    }, minutes * 60 * 1000);
    if (typeof repeatTimer.unref === 'function') repeatTimer.unref();
    console.log(`[proactive-chat] 下一句约 ${minutes} 分钟后`);
  }

  return {
    /** 启动：先拉一次热搜，再挂缓存刷新、首句与周期搭话 */
    start() {
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

    /** 立刻说一句（设置面板「说一句」按钮 / 排障用）：不走定时器，直接跑一轮 */
    chatNow() {
      return performProactiveChat();
    },

    stop() {
      for (const timer of [firstTimer, repeatTimer]) {
        if (timer) clearT(timer);
      }
      firstTimer = repeatTimer = null;
    },

    // 以下导出供单测直接验证台词逻辑
    sayGreeting,
    performProactiveChat,
    pickHeadline,
  };
}

module.exports = {
  createProactiveChat,
  proactiveChatEnabled,
  currentChatInterval,
  clampChatInterval,
  normalizeTopics,
  currentTopics,
  timeGreeting,
  encouragement,
  careLine,
  truncate,
  ENABLED_KEY,
  INTERVAL_KEY,
  TOPICS_KEY,
  ALL_TOPICS,
  TOPIC_LABELS,
  DEFAULT_CHAT_INTERVAL,
  MIN_CHAT_INTERVAL,
  MAX_CHAT_INTERVAL,
  CHAT_PRESETS: [15, 30, 60],
  FIRST_DELAY_SECONDS,
};
