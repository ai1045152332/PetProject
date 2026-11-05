// src/renderer/push.js — 运营推送卡：文字（可滚动）/ 视频（内嵌播放器）
'use strict';

const titleEl = document.getElementById('title');
const bodyEl = document.getElementById('body');
const closeEl = document.getElementById('close');

let autoCloseTimer = null;

function clearAutoClose() {
  if (autoCloseTimer) {
    clearTimeout(autoCloseTimer);
    autoCloseTimer = null;
  }
}

function render(payload) {
  if (!payload) return;
  clearAutoClose();
  titleEl.textContent = payload.title || '通知';
  bodyEl.textContent = '';

  if (payload.kind === 'video' && payload.url) {
    const wrap = document.createElement('div');
    wrap.className = 'push-video';
    const video = document.createElement('video');
    video.src = payload.url;
    video.controls = true;
    video.autoplay = true;
    video.playsInline = true;
    // 远端视频经常因防盗链 / 403 / 编码不支持而加载失败，原来只留个黑块没有任何提示；
    // 出错时收起播放器换成兜底文案 + 转系统浏览器的链接，正常加载出来再撤掉
    const fallback = document.createElement('div');
    fallback.className = 'push-fallback';
    fallback.hidden = true;
    const hint = document.createElement('div');
    hint.className = 'push-hint';
    hint.textContent = '视频没能播放（链接可能已失效、被防盗链或格式不支持）';
    const link = document.createElement('a');
    link.className = 'push-link';
    link.textContent = '用浏览器打开';
    link.href = payload.url;
    link.addEventListener('click', (event) => {
      event.preventDefault();
      if (window.pushAPI) window.pushAPI.openExternal(payload.url);
    });
    fallback.append(hint, link);
    wrap.append(video, fallback);
    bodyEl.append(wrap);
    video.addEventListener('error', () => {
      video.hidden = true;
      fallback.hidden = false;
    });
    video.addEventListener('loadeddata', () => {
      video.hidden = false;
      fallback.hidden = true;
    });
    // 播完自动关（用户也可能中途点 ×）
    video.addEventListener('ended', () => {
      if (window.pushAPI) window.pushAPI.dismiss();
    });
  } else {
    const text = document.createElement('div');
    text.className = 'push-text';
    text.textContent = payload.text || '';
    bodyEl.append(text);
    const ms = Number(payload.durationMs) || 0;
    if (ms > 0) {
      autoCloseTimer = setTimeout(() => {
        if (window.pushAPI) window.pushAPI.dismiss();
      }, ms);
    }
  }

  // 内容被替换（窗口复用）时重播入场动画
  const card = document.getElementById('card');
  card.style.animation = 'none';
  void card.offsetWidth;
  card.style.animation = '';
}

closeEl.addEventListener('click', () => {
  if (window.pushAPI) window.pushAPI.dismiss();
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && window.pushAPI) window.pushAPI.dismiss();
});

if (window.pushAPI) {
  window.pushAPI.payload().then(render).catch(() => {});
  window.pushAPI.onUpdate(render);
}
