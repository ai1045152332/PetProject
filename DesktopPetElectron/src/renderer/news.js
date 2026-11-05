// src/renderer/news.js
// 热点新闻卡渲染：主进程抓回 Top10 后推过来展示；点条目走系统浏览器（不放开 CSP 直连外链）
'use strict';

(function () {
  const listEl = document.getElementById('newsList');
  const emptyEl = document.getElementById('newsEmpty');

  /** 渲染一条热搜（全部用 textContent，标题里的特殊字符不会被当 HTML 注入） */
  function renderItem(item) {
    const row = document.createElement('div');
    row.className = 'news-item';

    const rank = document.createElement('span');
    rank.className = 'news-rank';
    rank.textContent = String(item.rank);

    const title = document.createElement('span');
    title.className = 'news-title';
    title.textContent = item.title || '无标题';

    row.append(rank, title);
    row.addEventListener('click', () => {
      if (item.url) window.newsAPI.openLink(item.url);
    });
    return row;
  }

  function render(payload) {
    const data = payload || {};
    const items = Array.isArray(data.items) ? data.items : [];
    listEl.textContent = '';

    if (data.loading) {
      emptyEl.hidden = false;
      emptyEl.textContent = '📰 加载热点新闻...';
      return;
    }
    if (!items.length) {
      emptyEl.hidden = false;
      emptyEl.textContent = '加载失败，请检查网络连接';
      return;
    }
    emptyEl.hidden = true;
    for (const item of items) listEl.appendChild(renderItem(item));
  }

  document.getElementById('close').addEventListener('click', () => window.newsAPI.dismiss());

  // 先拉当前内容（首次可能是「加载中」），抓取完成后主进程再推最终列表
  window.newsAPI.items().then(render);
  window.newsAPI.onUpdate(render);
})();
