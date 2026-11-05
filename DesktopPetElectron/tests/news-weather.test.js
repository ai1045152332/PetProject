// tests/news-weather.test.js
// 热点新闻 + 天气回归测试：node 直接跑，mock electron（config-store / app-info / card-window 都依赖它）
// 覆盖：头条/百度解析、换源兜底、天气链路（IP 定位 / 城市编码 / 后端响应转换 / emoji）、卡片窗单例复用
'use strict';

const path = require('path');
const Module = require('module');

const SRC = path.join(__dirname, '..', 'src', 'main');

// ── mock electron：config-store 要 app.getPath，card-window 要 BrowserWindow ──
const createdWindows = [];
const handlers = new Map();
const listeners = new Map();

class FakeBrowserWindow {
  constructor(options) {
    this.options = options;
    this.destroyed = false;
    this.visible = false;
    this.listeners = {};
    this.__sent = [];
    this.webContents = {
      send: (channel, payload) => this.__sent.push({ channel, payload }),
    };
    this.loadFile = (p) => { this.__loaded = p; };
    this.once = (event, fn) => { (this.listeners[event] = this.listeners[event] || []).push(fn); };
    this.on = (event, fn) => { (this.listeners[event] = this.listeners[event] || []).push(fn); };
    this.show = () => { this.visible = true; };
    this.focus = () => {};
    this.setAlwaysOnTop = () => {};
    this.close = () => {
      this.destroyed = true;
      (this.listeners.closed || []).forEach((fn) => fn());
    };
    this.isDestroyed = () => this.destroyed;
    createdWindows.push(this);
  }
}

const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      app: { getPath: () => path.join(require('os').tmpdir(), 'pet-news-weather-test') },
      BrowserWindow: FakeBrowserWindow,
      ipcMain: {
        handle: (channel, fn) => handlers.set(channel, fn),
        on: (channel, fn) => listeners.set(channel, fn),
      },
      screen: { getPrimaryDisplay: () => ({ workAreaSize: { height: 900 } }) },
    };
  }
  return origLoad.apply(this, arguments);
};

const { createNewsService } = require(path.join(SRC, 'info', 'news-service'));
const { weatherEmoji, createWeatherService } = require(path.join(SRC, 'info', 'weather-service'));
const { createCardWindow } = require(path.join(SRC, 'push', 'card-window'));

let failed = 0;
function check(name, condition) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    console.error(`❌ ${name}`);
    failed += 1;
  }
}

// ── 热搜改走服务端缓存：客户端只解析 /api/news 的返回，不再自己抓上游 ──
{
  (async () => {
    let requested = '';
    const news = createNewsService({
      baseUrl: () => 'http://server.test',
      fetchJSON: async (url) => {
        requested = url;
        return {
          code: 0,
          data: {
            cached: true,
            ttlSec: 600,
            items: Array.from({ length: 12 }, (_, i) => ({
              rank: i + 1, title: `热搜${i + 1}`, url: `https://n.example/${i}`,
            })),
          },
        };
      },
    });
    const items = await news.fetchHotNews();
    check('热搜请求打到服务端 /api/news', requested === 'http://server.test/api/news', requested);
    check('服务端榜单原样返回（排名/标题/链接）',
      items.length === 12 && items[0].rank === 1 && items[0].title === '热搜1' && items[0].url === 'https://n.example/0');

    const empty = createNewsService({ baseUrl: () => 'http://server.test', fetchJSON: async () => null });
    check('服务端不可用返回空数组（渲染层提示加载失败）', (await empty.fetchHotNews()).length === 0);

    const blank = createNewsService({
      baseUrl: () => 'http://server.test',
      fetchJSON: async () => ({ data: { items: [{ title: '' }, { title: '有效' }] } }),
    });
    check('空标题条目被丢弃', (await blank.fetchHotNews()).length === 1);
  })();
}

// ── 天气：emoji 映射与 mac 版一致（判序也一致：雷阵雨含「雨」先命中 🌧️）──
{
  (async () => {
    check('天气描述 → emoji', weatherEmoji('晴') === '☀️' && weatherEmoji('多云转阴') === '⛅'
      && weatherEmoji('大雨') === '🌧️' && weatherEmoji('雷阵雨') === '🌧️' && weatherEmoji('打雷') === '⛈️' && weatherEmoji('雾') === '🌫️');

    // ── 天气：本地链路（IP 定位 → /api/weather 带坐标 + deviceId） ──
    const calls = [];
    const svc = createWeatherService({
      getJSON: async (url) => {
        calls.push(url);
        if (url.includes('ip.sb')) return { city: '杭州', latitude: 30.28, longitude: 120.16 };
        if (url.includes('/api/weather')) {
          return {
            code: 0,
            msg: 'ok',
            data: {
              city: '杭州', nowTemp: '21', nowText: '多云',
              todayMax: '25', todayMin: '15',
              hourly: [{ time: '14:00', temp: '22', text: '晴' }],
              daily: [{ dayName: '今天', textDay: '多云', tempMax: '25', tempMin: '15' }],
            },
          };
        }
        return null;
      },
    });
    const local = await svc.fetchLocal();
    check('本地天气：IP 定位后按坐标查 PetServer', local && local.city === '杭州' && local.nowTemp === '21');
    check('请求 /api/weather 带 lat/lon/deviceId',
      calls.some((u) => u.includes('/api/weather') && u.includes('lat=30.2800') && u.includes('deviceId=')));
    check('hourly/daily 补了 emoji 图标', local.hourly[0].icon === '☀️' && local.daily[0].icon === '⛅');

    // ── 天气：城市名查询先过 Nominatim 地理编码 ──
    calls.length = 0;
    const geoSvc = createWeatherService({
      getJSON: async (url) => {
        calls.push(url);
        if (url.includes('nominatim')) {
          return [{ lat: '39.9042', lon: '116.4074', display_name: '北京市, 东城区, 中国' }];
        }
        if (url.includes('/api/weather')) {
          return { code: 0, data: { city: '北京市', nowTemp: '12', nowText: '晴', todayMax: '18', todayMin: '8', hourly: [], daily: [] } };
        }
        return null;
      },
    });
    const beijing = await geoSvc.fetchByCity('北京');
    check('城市查询先地理编码（带城市名且 Nominatim 在前）',
      calls.some((u) => u.includes('nominatim') && u.includes(encodeURIComponent('北京')))
        && calls[0].includes('nominatim') && calls[1].includes('/api/weather'));
    check('编码后的坐标传给天气接口（lat 保留 4 位）',
      calls[1].includes('lat=39.9042') && calls[1].includes('lon=116.4074') && beijing && beijing.nowTemp === '12');
    check('服务端未给 city 时用编码短名兜底',
      beijing.city === '北京市');
    check('后端 code≠0 时返回 null（渲染层提示稍后再试）', await (async () => {
      const bad = createWeatherService({ getJSON: async (url) => (url.includes('ip.sb') ? { city: 'x', latitude: 1, longitude: 2 } : { code: 503, msg: 'not configured' }) });
      return (await bad.fetchLocal()) === null;
    })());

    // ── 卡片窗：单例复用 + 复用只前置刷新，不新建窗口 ──
    const card = createCardWindow({
      name: 'news', title: '今日热点新闻', width: 460, height: 560,
      htmlFile: 'news.html', preloadFile: 'news-preload.js', updateChannel: 'news:update',
    });
    const w1 = card.open({ items: [], loading: true });
    check('首次 open 新建窗口并暂存 payload 供渲染层 invoke', w1.__cardPayload.loading === true && createdWindows.length === 1);
    const w2 = card.open({ items: [{ rank: 1, title: 'a', url: '' }], loading: false });
    check('窗口开着时复用：不新建、send 推新内容', w2 === w1 && createdWindows.length === 1
      && w1.__sent.some((m) => m.channel === 'news:update'));
    card.close();
    check('close 后 isOpen 为假且句柄清空', !card.isOpen() && card.getWindow() === null);
    card.open({ items: [], loading: true });
    check('关闭后重开会新建窗口', createdWindows.length === 2);

    if (failed > 0) {
      console.error(`\n新闻/天气测试失败 ${failed} 项`);
      process.exit(1);
    }
    console.log('\n全部通过');
  })();
}
