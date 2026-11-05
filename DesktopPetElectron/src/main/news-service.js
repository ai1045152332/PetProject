// src/main/news-service.js
// DesktopPetElectron — 热点新闻抓取（对标 mac 版 Services/NewsFetcher.swift）
// 主源：今日头条热榜；兜底：百度热搜。抓回/解析都在主进程完成，渲染层只展示结果，
// 不放开 CSP 连外网（也避免上游接口变更波及两个渲染进程）。
'use strict';

const TIMEOUT_MS = 8000;      // 单源超时（与 mac 版 NetworkClient timeout: 8 一致）
const TOP_N = 10;             // 只取 Top10（与 mac 版 prefix(10) 一致）

const TOUTIAO_URL = 'https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc';
const BAIDU_URL = 'https://top.baidu.com/api/board?platform=wise&tab=realtime';

/** 通用 GET + JSON 解析（失败返回 null，由上层换源/提示） */
async function fetchJSON(url) {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!res.ok) return null;
    return await res.json();
  } catch (e) {
    console.warn(`[news] 请求失败 ${url}: ${e.message}`);
    return null;
  }
}

/** 解析头条热榜：{ data: [{ Title, Url }] } → [{ rank, title, url }] */
function parseToutiao(json) {
  const list = json && Array.isArray(json.data) ? json.data : [];
  if (!list.length) return null;
  return list.slice(0, TOP_N).map((item, i) => ({
    rank: i + 1,
    title: item.Title || '无标题',
    url: item.Url || '',
  }));
}

/** 解析百度热搜：cards[0].content（个别结构多套一层 content）→ [{ rank, title, url }]
 * 百度的条目没有直达链接，与 mac 版一样用标题拼百度搜索 URL */
function parseBaidu(json) {
  const cards = json && json.data && Array.isArray(json.data.cards) ? json.data.cards : [];
  if (!cards.length) return null;
  const first = cards[0];
  let list = Array.isArray(first.content) ? first.content : [];
  // 「wise」端下常见 top 结构：content[0].content 才是真列表；内层缺失时保留外层
  if (list.length === 1 && Array.isArray(list[0].content) && list[0].content.length) {
    list = list[0].content;
  }
  if (!list.length) return null;
  return list.slice(0, TOP_N).map((item, i) => {
    const title = item.query || item.word || item.title || '无标题';
    return {
      rank: i + 1,
      title,
      url: `https://www.baidu.com/s?wd=${encodeURIComponent(title)}`,
    };
  });
}

/**
 * 创建新闻服务。
 * @param {object} [opts]
 * @param {(url: string) => Promise<any>} [opts.fetchJSON] 注入请求器（单测桩）
 */
function createNewsService({ fetchJSON: fetcher = fetchJSON } = {}) {
  return {
    /** 抓取 Top10 热点：头条 → 百度兜底 → 都失败返回 [] */
    async fetchHotNews() {
      const items = parseToutiao(await fetcher(TOUTIAO_URL))
        || parseBaidu(await fetcher(BAIDU_URL))
        || [];
      console.log(`[news] 热搜抓取: ${items.length} 条${items.length ? `，首条「${items[0].title}」` : ''}`);
      return items;
    },
  };
}

module.exports = {
  createNewsService,
  fetchJSON,
  parseToutiao,
  parseBaidu,
};
