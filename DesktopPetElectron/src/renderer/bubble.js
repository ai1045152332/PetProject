// src/renderer/bubble.js
// 气泡渲染层：接主进程推来的台词 → 排版 → 把内容尺寸回报主进程（主进程据此定位到猫头顶并显形）
// 弹入 / 呼吸浮动 / 淡出都在 CSS 里做，主进程只负责窗口位置与显隐时序。
'use strict';

const api = window.bubbleAPI;

const bubble = document.getElementById('bubble');
const textEl = document.getElementById('text');

const SIDE_PAD = 8;   // body 左右内边距 4px 的两倍
const TAIL_HEIGHT = 15; // 尾巴溢出气泡盒的高度（CSS 里 13px + 描边余量）

/** 重新触发一次弹入动画（复用窗口说第二句时也要「啵」地冒出来） */
function replayEnter() {
  bubble.classList.remove('leaving');
  bubble.style.animation = 'none';
  // 读一次尺寸强制回流，赋值后动画才会从头播
  void bubble.offsetWidth;
  bubble.style.animation = '';
}

/** 量完内容尺寸报给主进程（由它 show 并贴到头顶） */
function reportSize() {
  if (!api || !api.reportSize) return;
  // 必须用 offsetWidth/Height：这是不受 transform 影响的布局尺寸。
  // 之前用 getBoundingClientRect，弹入动画起步瞬间 scale(0.7) 被算进去，
  // 量出来比真实内容小 → 窗口装不下内容，右边就冒出滚动条
  api.reportSize(
    Math.ceil(bubble.offsetWidth) + SIDE_PAD,
    Math.ceil(bubble.offsetHeight) + TAIL_HEIGHT + SIDE_PAD,
  );
}

function showText(text) {
  const content = String(text || '').trim();
  if (!content) return;
  textEl.textContent = content;
  replayEnter();
  reportSize();
}

if (api) {
  // 窗口复用时的增量更新
  api.onUpdate(showText);
  // 主进程喊收：播淡出动画（真正的 close 由主进程按淡出时长执行）
  api.onLeave(() => {
    bubble.style.animation = '';
    bubble.classList.add('leaving');
  });
  // 点一下气泡立刻收起（mac 版 bubbleView.onClick → 淡出关闭）
  bubble.addEventListener('click', () => api.dismiss && api.dismiss());
  // 刚加载完主动拉一次，避免「先 send 后挂监听」丢掉第一句
  api.payload().then((data) => {
    if (data && data.text) showText(data.text);
  }).catch(() => {});
}
