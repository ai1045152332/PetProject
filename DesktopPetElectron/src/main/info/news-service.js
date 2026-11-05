// src/main/news-service.js
// DesktopPetElectron — 热点新闻（对标 mac 版 Services/NewsFetcher.swift）
// 抓取与缓存都在服务端（GET /api/news，服务端 10 分钟 TTL），客户端只取现成榜单：
// 不再直连头条/百度、也不在本地缓存，多端拿到的是同一份榜单。
'use strict';

const config = require('../core/config-store');

const TIMEOUT_MS = 8000;      // 请求服务端的超时（与 mac 版 NetworkClient 的 8s 对齐）

/** 通用 GET + JSON 解析（失败返回 null，由上层给空列表） */
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

/**
 * 创建新闻服务。
 * @param {object} [opts]
 * @param {(url: string) => Promise<any>} [opts.fetchJSON] 注入请求器（单测桩）
 * @param {() => string} [opts.baseUrl] 后端地址（默认读 config 的 serverBaseURL）
 */
function createNewsService({ fetchJSON: fetcher = fetchJSON, baseUrl } = {}) {
  const urlOf = () => {
    const base = String(baseUrl ? baseUrl() : config.get('serverBaseURL') || '').replace(/\/+$/, '');
    return `${base}/api/news`;
  };

  return {
    /** 取服务端缓存的 Top10 热搜；失败或空列表返回 []（渲染层提示加载失败） */
    async fetchHotNews() {
      const json = await fetcher(urlOf());
      const list = json && json.data && Array.isArray(json.data.items) ? json.data.items : [];
      const items = list
        .map((item, i) => ({
          rank: Number(item && item.rank) || i + 1,
          title: String((item && item.title) || ''),
          url: String((item && item.url) || ''),
        }))
        .filter((item) => item.title);
      const cached = Boolean(json && json.data && json.data.cached);
      console.log(`[news] 热搜 ${items.length} 条${cached ? '（服务端缓存）' : ''}${items.length ? `，首条「${items[0].title}」` : ''}`);
      return items;
    },
  };
}

module.exports = {
  createNewsService,
  fetchJSON,
};
