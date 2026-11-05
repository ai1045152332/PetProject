// src/renderer/weather.js
// 天气窗渲染：主进程推来「加载中 / 错误 / 预报」三种内容，本层只负责排版
// 预报卡结构对标 mac 版 buildWeatherCardHTML；全部 textContent 写文本，防注入
'use strict';

(function () {
  const statusEl = document.getElementById('wStatus');
  const contentEl = document.getElementById('weatherContent');
  const inputEl = document.getElementById('cityInput');

  function el(className, text) {
    const node = document.createElement('div');
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  /** 渲染加载 / 错误一类的纯文本状态 */
  function renderStatus(message) {
    contentEl.textContent = '';
    statusEl.hidden = false;
    statusEl.textContent = message || '';
  }

  /** 渲染预报卡（hourly 取前 6 条，与 mac 版一致） */
  function renderForecast(f) {
    statusEl.hidden = true;
    contentEl.textContent = '';

    const card = el('w-card');

    // 顶部：城市 + 当前温度｜天气描述 + 今日高低
    const top = el('w-top');
    const left = el('');
    left.append(el('w-loc', `📍 ${f.city}`), el('w-temp-big', `${f.nowTemp}°`));
    const meta = el('w-meta');
    meta.append(el('w-desc', f.nowText), el('w-hl', `最高 ${f.todayMax}° 最低 ${f.todayMin}°`));
    top.append(left, meta);

    // 逐小时
    const hourly = el('w-hourly');
    for (const h of (f.hourly || []).slice(0, 6)) {
      const item = el('hw-item');
      item.append(el('hw-time', h.time), el('hw-icon', h.icon), el('hw-temp', `${h.temp}°`));
      hourly.appendChild(item);
    }

    // 三日预报：温度条按全期最值区间定位（高温 ≥30° 用暖色）
    const daily = el('w-daily');
    const temps = (f.daily || []).flatMap((d) => [Number(d.tempMin) || 0, Number(d.tempMax) || 0]);
    const gMin = temps.length ? Math.min(...temps) : 0;
    const gRange = Math.max((temps.length ? Math.max(...temps) : 1) - gMin, 1);
    for (const d of f.daily || []) {
      const minT = Number(d.tempMin) || 0;
      const maxT = Number(d.tempMax) || 0;
      const row = el('dw-row');
      const track = el('dw-bar-track');
      const bar = el('dw-bar');
      bar.style.left = `${((minT - gMin) / gRange * 100).toFixed(1)}%`;
      bar.style.width = `${((maxT - minT) / gRange * 100).toFixed(1)}%`;
      if (maxT >= 30) bar.classList.add('hot');
      track.appendChild(bar);
      row.append(
        el('dw-day', d.dayName),
        el('dw-icon', d.icon),
        el('dw-min', `${d.tempMin}°`),
        track,
        el('dw-max', `${d.tempMax}°`),
      );
      daily.appendChild(row);
    }

    card.append(top, el('w-divider'), hourly, el('w-divider'), daily);
    contentEl.appendChild(card);
  }

  function render(content) {
    const c = content || {};
    if (c.forecast) renderForecast(c.forecast);
    else renderStatus(c.message || '🌤️ 正在加载本地天气...');
  }

  // 输入城市 → 主进程查询（结果由 weather:update 推回，这里不等待）
  function queryCity() {
    const city = inputEl.value.trim();
    if (!city) return;
    window.weatherAPI.query(city);
  }

  document.getElementById('close').addEventListener('click', () => window.weatherAPI.dismiss());
  document.getElementById('queryBtn').addEventListener('click', queryCity);
  inputEl.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') queryCity();
  });

  window.weatherAPI.payload().then(render);
  window.weatherAPI.onUpdate(render);
})();
