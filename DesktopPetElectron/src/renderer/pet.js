// src/renderer/pet.js
// 小猫帧循环（focus 单一循环）
// 提醒已合并进专注：喝水提醒触发时专注动画从头播放唤起注意，不再有独立的 warn 状态。
// 后续 P1 再补全 idel/sleep/pet 与"一次性动画播完回基准态"逻辑。
'use strict';

const FRAME_COUNT = 8;               // 每个状态目录 8 帧：frame_00.png ~ frame_07.png
const FPS = 12;
const FRAME_INTERVAL = 1000 / FPS;

const pad2 = (n) => String(n).padStart(2, '0');
const frameSrc = (state, i) => `../../assets/Sprites/${state}/frame_${pad2(i)}.png`;

// 预加载用到的帧，避免切换时闪烁
for (const state of ['focus']) {
  for (let i = 0; i < FRAME_COUNT; i++) {
    const img = new Image();
    img.src = frameSrc(state, i);
  }
}

const cat = document.getElementById('cat');

let state = 'focus';
let index = 0;

// 状态切换 helper：P1 补全 idel/sleep/pet 多状态时复用
function setState(next) {
  if (state === next) return;
  state = next;
  index = 0;
  cat.src = frameSrc(state, 0);
}

setInterval(() => {
  index = (index + 1) % FRAME_COUNT;
  cat.src = frameSrc(state, index);
}, FRAME_INTERVAL);

// 喝水提醒联动：提醒触发时专注动画从第 0 帧重新播放（原 warn 切换已合并进专注）
if (window.petAPI && window.petAPI.onDrinkWater) {
  window.petAPI.onDrinkWater(() => {
    state = 'focus';
    index = 0;
    cat.src = frameSrc('focus', 0);
  });
}
