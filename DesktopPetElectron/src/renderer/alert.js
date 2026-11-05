// src/renderer/alert.js — 提示卡：渲染头像/眉题/正文/说明/按钮，并把内容真实高度报给主进程（自适应免滚动条）
'use strict';

// body 上下 padding 各 18px，卡片外框要加上才能当窗口高
const BODY_PADDING = 36;
const DEFAULT_AVATAR = '🐾';

function esc(value) {
  return String(value == null ? '' : value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** 量卡片自然高度报给主进程（.card 不被视口拉伸，offsetHeight 即内容真实高） */
function fitWindow() {
  if (!window.appAlertAPI || typeof window.appAlertAPI.resize !== 'function') return;
  const card = document.getElementById('card');
  window.appAlertAPI.resize(card.offsetHeight + BODY_PADDING);
}

function render(payload) {
  const data = payload || {};
  const title = data.title || '提示';
  document.title = title;
  document.getElementById('avatar').textContent = data.icon || DEFAULT_AVATAR;
  document.getElementById('message').textContent = data.message || '';
  // 眉题只在与正文不同才有信息量（alert 用法里 title 与 message 同文，隐藏避免重复）
  const eyebrow = document.getElementById('eyebrow');
  eyebrow.textContent = (data.message && data.message !== title) ? title : (data.message ? '' : title);
  // detail 支持多行：走 textContent + CSS pre-wrap，不拼 HTML
  document.getElementById('detail').textContent = data.detail || '';

  const buttons = Array.isArray(data.buttons) && data.buttons.length ? data.buttons : ['好'];
  const defaultIndex = Number.isInteger(data.defaultIndex) ? data.defaultIndex : 0;
  const cancelIndex = Number.isInteger(data.cancelIndex) ? data.cancelIndex : buttons.length - 1;
  const actions = document.getElementById('actions');
  actions.innerHTML = buttons.map((label, i) => `<button type="button" data-index="${i}"${i === defaultIndex ? ' class="primary"' : ''}>${esc(label)}</button>`).join('');
  actions.querySelectorAll('button').forEach((btn) => {
    btn.addEventListener('click', () => {
      if (window.appAlertAPI) window.appAlertAPI.click(Number(btn.dataset.index));
    });
  });

  // ✕ 与 Esc 同义：按取消键收口
  document.getElementById('closeBtn').addEventListener('click', () => {
    if (window.appAlertAPI) window.appAlertAPI.click(cancelIndex);
  });

  // 对齐原生 MessageBox 的键盘习惯：回车=默认键，Esc=取消键
  document.addEventListener('keydown', (e) => {
    if (!window.appAlertAPI) return;
    if (e.key === 'Enter') window.appAlertAPI.click(defaultIndex);
    else if (e.key === 'Escape') window.appAlertAPI.click(cancelIndex);
  });

  // 等本轮布局落定再量高
  requestAnimationFrame(fitWindow);
}

if (window.appAlertAPI) {
  window.appAlertAPI.payload().then(render).catch(() => {});
}
