// tests/proactive-chat.test.js
// 「主动搭话」回归测试：node 直接跑，不依赖 electron 运行时，也不打真实网络
// 覆盖：间隔收敛、开关默认值、时段问候、热搜/Todo 轮换与截断、不打扰守卫、
//       气泡停留时长按文案长度自适应、气泡位置夹进工作区、SettingsService 读写与重挂定时器
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const Module = require('module');

const USER_DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-chat-'));

// ── mock electron：config-store 只用 app.getPath；speech-bubble 只用 BrowserWindow/screen 的构造 ──
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      app: { getPath: () => USER_DATA },
      BrowserWindow: function () {},
      screen: { getDisplayMatching: () => ({ workArea: { x: 0, y: 0, width: 1440, height: 900 } }) },
    };
  }
  return origLoad.apply(this, arguments);
};

const SRC = path.join(__dirname, '..', 'src', 'main');
const chat = require(path.join(SRC, 'pet', 'proactive-chat.js'));
const { holdMsFor, clampToBounds, MAX_WIDTH } = require(path.join(SRC, 'pet', 'speech-bubble.js'));
const { SettingsService } = require(path.join(SRC, 'settings', 'settings-service.js'));
const config = require(path.join(SRC, 'core', 'config-store.js'));

let failed = 0;
function check(name, condition, extra) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    failed += 1;
    console.error(`❌ ${name}${extra ? ` → ${extra}` : ''}`);
  }
}

// ── 间隔收敛：脏数据回落默认，越界夹到边界 ──
check('非法间隔回落 30 分钟', chat.clampChatInterval(undefined) === chat.DEFAULT_CHAT_INTERVAL);
check('0 分钟视作脏数据回落 30', chat.clampChatInterval(0) === chat.DEFAULT_CHAT_INTERVAL);
check('非整数间隔回落 30', chat.clampChatInterval(7.5) === chat.DEFAULT_CHAT_INTERVAL);
check('超上限夹到 720', chat.clampChatInterval(5000) === chat.MAX_CHAT_INTERVAL);
check('预设是 15/30/60', JSON.stringify(chat.CHAT_PRESETS) === JSON.stringify([15, 30, 60]));

// ── 开关默认开启，显式关闭后为 false ──
check('未设置过默认开启搭话', chat.proactiveChatEnabled() === true);
config.set(chat.ENABLED_KEY, false);
check('写 false 后关闭搭话', chat.proactiveChatEnabled() === false);
config.set(chat.ENABLED_KEY, true);

// ── 时段问候边界 ──
const at = (hour) => chat.timeGreeting(new Date(2026, 0, 1, hour, 0, 0));
check('05:00 早上好', at(5) === '早上好 ☀️');
check('11:00 中午好', at(11) === '中午好 🍚');
check('13:00 下午好', at(13) === '下午好 ☕');
check('18:00 晚上好', at(18) === '晚上好 🌙');
check('03:00 夜深了', at(3) === '夜深了 🌌');

// ── 标题截断（气泡别撑太宽）──
check('短标题不截断', chat.truncate('小猫吃饭') === '小猫吃饭');
check('超 20 字截断加省略号', chat.truncate('一'.repeat(25)) === `${'一'.repeat(20)}…`);

// ── 气泡停留时长：mac 版 catSay 规则 min(18, max(4, 字数 * 0.6)) ──
check('短句至少停 4 秒', holdMsFor('喵～') === 4000);
check('长句最多停 18 秒', holdMsFor('一'.repeat(200)) === 18000);
check('中等长度按比例', holdMsFor('一'.repeat(10)) === 6000);

// ── 气泡位置夹进工作区（不探出屏幕、不顶进菜单栏）──
{
  const area = { x: 0, y: 0, width: 1440, height: 900 };
  const right = clampToBounds({ x: 1400, y: -50, width: 240, height: 96 }, area);
  check('右侧越界被夹回工作区', right.x === 1440 - 240 - 4, JSON.stringify(right));
  check('顶部越界被夹到工作区上沿', right.y === 4, JSON.stringify(right));
  const left = clampToBounds({ x: -200, y: 500, width: 240, height: 96 }, area);
  check('左侧越界被夹回', left.x === 4, JSON.stringify(left));
  check('气泡最大宽度 240', MAX_WIDTH === 240);
}

// ── 搭话调度：注入定时器 / 随机源 / 热搜源，验证台词与守卫 ──
function makeChat(overrides = {}) {
  const spoken = [];
  const deps = {
    say: (text) => { spoken.push(text); return true; },
    fetchHeadlines: async () => Array.from({ length: 12 }, (_, i) => ({ title: `热搜${i + 1}` })),
    todoCount: () => 0,
    isSystemFocusActive: () => false,
    getPetState: () => 'idel',
    isPlayingOneShot: () => false,
    random: () => 0,
    ...overrides,
  };
  const instance = chat.createProactiveChat(deps);
  return { spoken, deps, instance };
}

(async () => {
  // 热搜缓存：只取前 10 条，空标题丢弃
  {
    const { instance, spoken } = makeChat({
      todoCount: () => 0,
      fetchHeadlines: async () => [
        ...Array.from({ length: 12 }, (_, i) => ({ title: `热搜${i + 1}` })),
        { title: '' },
        null,
      ],
    });
    await instance.performProactiveChat();
    check('热搜只用前 10 条', /^热搜在聊「热搜([1-9]|10)」/.test(spoken[0] || ''), spoken[0]);
  }

  // 抓取失败保留旧缓存，不打扰用户
  {
    const { instance, spoken } = makeChat({ fetchHeadlines: async () => { throw new Error('断网'); } });
    await instance.performProactiveChat();
    check('热搜抓取失败仍能搭话（改说关心问候）', spoken.length === 1 && !spoken[0].startsWith('热搜'), spoken[0]);
  }

  // 启动首句：带 Todo 数量 / 无 Todo 两种文案
  {
    const { instance, spoken } = makeChat({ todoCount: () => 3 });
    instance.sayGreeting();
    check('首句带今日 Todo 数量', /｜今天你有 3 个 Todo 📝$/.test(spoken[0] || ''), spoken[0]);
  }
  {
    const { instance, spoken } = makeChat({ todoCount: () => 0 });
    instance.sayGreeting();
    check('无 Todo 时首句走轻松文案', /｜今天没有待办，轻松一下～$/.test(spoken[0] || ''), spoken[0]);
  }

  // 轮换：按「新闻 → Todo → 天气 → 关心问候」固定顺序，只挑有料的
  {
    const { instance, spoken } = makeChat({
      todoCount: () => 5,
      fetchHeadlines: async () => [{ title: '小猫开会' }, { title: '毛豆加班' }],
    });
    await instance.performProactiveChat(); // 第 1 句：新闻（有缓存）
    await instance.performProactiveChat(); // 第 2 句：Todo（有未完成）
    await instance.performProactiveChat(); // 第 3 句：关心问候（天气没数据，跳过）
    check('第 1 句先聊热搜', /^热搜在聊「(小猫开会|毛豆加班)」🔥 右键看今日热点～$/.test(spoken[0] || ''), spoken[0]);
    check('第 2 句轮到 Todo', /个 Todo 没完成 📝 加油～$/.test(spoken[1] || ''), spoken[1]);
    check('第 3 句轮到关心问候（天气没料自动跳过）', /🐾|陪着你|伸个懒腰|辛苦啦|想你了/.test(spoken[2] || ''), spoken[2]);
  }

  // 只勾热点新闻：即使有 Todo 也只聊热搜，不会串台
  {
    config.set(chat.TOPICS_KEY, ['news']);
    const { instance, spoken } = makeChat({
      todoCount: () => 9,
      fetchHeadlines: async () => [{ title: '只聊新闻' }],
    });
    await instance.performProactiveChat();
    await instance.performProactiveChat();
    check('只勾新闻时两次都说热搜', spoken.length === 2 && spoken.every((t) => t.startsWith('热搜在聊')), JSON.stringify(spoken));
    config.set(chat.TOPICS_KEY, chat.ALL_TOPICS.slice());
  }

  // 超长热搜标题进台词时被截到 20 字
  {
    const long = '一'.repeat(30);
    const { instance, spoken } = makeChat({ todoCount: () => 0, fetchHeadlines: async () => [{ title: long }] });
    await instance.performProactiveChat();
    check('台词里的长标题被截断', spoken[0] === `热搜在聊「${'一'.repeat(20)}…」🔥 右键看今日热点～`, spoken[0]);
  }

  // 连续两次不重复同一条热搜
  {
    const picks = [];
    const { instance } = makeChat({ random: () => 0 });
    const list = ['A', 'B'];
    for (let i = 0; i < 4; i += 1) picks.push(instance.pickHeadline(list));
    check('热搜避开上一条', picks[1] !== picks[0], JSON.stringify(picks));
    check('池里两条轮换不重复', new Set(picks.slice(0, 2)).size === 2, JSON.stringify(picks));
  }

  // 只剩一条热搜时无可避免仍要说出来
  {
    const { instance } = makeChat({});
    instance.pickHeadline(['唯一的一条']);
    check('只剩一条时不再挑避重', instance.pickHeadline(['唯一的一条']) === '唯一的一条');
  }

  // 守卫：关闭开关 / 勿扰 / 睡觉 / 躲藏 / 抚摸中都不打扰
  {
    const guards = [
      ['关闭开关', { overrides: { enabled: false } }],
      ['系统勿扰', { overrides: { isSystemFocusActive: () => true } }],
      ['睡觉', { overrides: { getPetState: () => 'sleep' } }],
      ['躲藏', { overrides: { getPetState: () => 'hide' } }],
      ['抚摸中', { overrides: { isPlayingOneShot: () => true } }],
    ];
    for (const [name, cfg] of guards) {
      if (cfg.overrides.enabled === false) config.set(chat.ENABLED_KEY, false);
      const { instance, spoken } = makeChat(cfg.overrides || {});
      instance.sayGreeting();
      await instance.performProactiveChat();
      check(`${name}时不打扰用户`, spoken.length === 0, JSON.stringify(spoken));
      if (cfg.overrides.enabled === false) config.set(chat.ENABLED_KEY, true);
    }
  }

  // 无 Todo 且热搜正好奇数轮 → 走热搜短句；两者都没有 → 鼓励语
  {
    const { instance, spoken } = makeChat({
      todoCount: () => 0,
      fetchHeadlines: async () => [{ title: '唯一热搜' }],
    });
    await instance.performProactiveChat(); // 只有一条热搜、Todo 为 0 → 说热搜
    check('无 Todo 时聊热搜', spoken[0] === '热搜在聊「唯一热搜」🔥 右键看今日热点～', spoken[0]);
  }
  {
    const { instance, spoken } = makeChat({ todoCount: () => 0, fetchHeadlines: async () => [] });
    await instance.performProactiveChat();
    check('既无 Todo 又无热搜时说鼓励语', spoken.length === 1 && !spoken[0].includes('Todo') && !spoken[0].includes('热搜'), spoken[0]);
  }

  // start/stop：启动只挂「热搜刷新 + 首句」两个定时器，周期搭话等首句跑完再排（对齐 mac 版）
  {
    const armed = [];
    let cleared = 0;
    const fakeSet = (fn, ms) => { const t = { fn, ms }; armed.push(t); return t; };
    const fakeClear = () => { cleared += 1; };
    const instance = chat.createProactiveChat({
      say: () => {},
      fetchHeadlines: async () => [],
      setTimer: fakeSet,
      clearTimer: fakeClear,
    });
    instance.start();
    check('启动只挂首句定时器（热搜/天气由服务端缓存，客户端不再定时刷新）', armed.length === 1, `实际 ${armed.length}`);
    check('首句延迟 20 秒', armed[0].ms === chat.FIRST_DELAY_SECONDS * 1000, String(armed[0].ms));
    // 首句跑完才排周期搭话，按当前间隔（默认 30 分钟）
    armed[0].fn();
    check('首句后排出周期搭话（默认 30 分钟）', armed.length === 2 && armed[1].ms === chat.DEFAULT_CHAT_INTERVAL * 60 * 1000,
      JSON.stringify(armed.map((t) => t.ms)));
    instance.stop();
    check('stop 取消已挂的定时器', cleared === 1, `实际 ${cleared}`);

    // 周期搭话跑完会按最新间隔重挂（改小间隔下一轮即生效）
    cleared = 0;
    armed.length = 0;
    const repeat = chat.createProactiveChat({ say: () => {}, fetchHeadlines: async () => [], setTimer: fakeSet, clearTimer: fakeClear });
    repeat.start();
    const beforeLen = armed.length;
    config.set(chat.INTERVAL_KEY, 5);
    repeat.restart();
    check('restart 按新间隔重建周期搭话', armed.length === beforeLen + 1 && armed[armed.length - 1].ms === 5 * 60 * 1000,
      JSON.stringify(armed.map((t) => t.ms)));
    repeat.stop();
  }

  // ── SettingsService：load 带出搭话状态，写入后校验并回传最新值 ──
  {
    let restarts = 0;
    // 上面 fake timer 用例改过间隔，这里清回「从未设置过」以验证默认值
    config.remove(chat.INTERVAL_KEY);
    const service = new SettingsService({});
    service.proactiveChat = { restart: () => { restarts += 1; } };

    const saved = service.load();
    check('load() 带出 proactiveChat 形状', saved.proactiveChat.enabled === true
      && saved.proactiveChat.minutes === 30
      && JSON.stringify(saved.proactiveChat.presets) === JSON.stringify([15, 30, 60]),
      JSON.stringify(saved.proactiveChat));

    const ok = service.setProactiveChat({ intervalMinutes: 15 });
    check('写入间隔成功并回传最新状态', ok.ok === true && ok.chat.minutes === 15, JSON.stringify(ok));
    check('写间隔后重挂周期定时器', restarts === 1);
    check('间隔已落盘', config.get(chat.INTERVAL_KEY) === 15);

    const bad = service.setProactiveChat({ intervalMinutes: 0 });
    check('非法间隔被拒绝', bad.ok === false && typeof bad.error === 'string', JSON.stringify(bad));
    check('非法写入不改动已存值', service.load().proactiveChat.minutes === 15);

    const off = service.setProactiveChat({ enabled: false });
    check('关闭开关立即生效', off.ok === true && off.chat.enabled === false);
    check('非法写入不重挂定时器（改开关才重挂）', restarts === 2, `实际 ${restarts}`);
    check('脏数据间隔回落默认', (() => { config.set(chat.INTERVAL_KEY, 'abc'); return service.load().proactiveChat.minutes; })() === 30);

    service.setProactiveChat({ enabled: true, intervalMinutes: 30 });
  }

  if (failed > 0) {
    console.error(`\n主动搭话测试失败 ${failed} 项`);
    process.exit(1);
  }
  console.log('\n全部通过');
})();
