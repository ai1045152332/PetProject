// src/renderer/pet.js
// 小猫帧循环 + 轻量状态机（focus ↔ warn）
// P0 只做 focus 循环；喝水提醒触发时切到 warn，提醒关闭后回到 focus。
// 后续 P1 再补全 idel/sleep/pet 与"一次性动画播完回基准态"逻辑。
'use strict';

const FRAME_COUNT = 8;               // 每个状态目录 8 帧：frame_00.png ~ frame_07.png
const FPS = 12;
const FRAME_INTERVAL = 1000 / FPS;

const pad2 = (n) => String(n).padStart(2, '0');
const frameSrc = (state, i) => `../../assets/Sprites/${state}/frame_${pad2(i)}.png`;

// 预加载用到的帧，避免切换时闪烁
for (const state of ['focus', 'warn']) {
  for (let i = 0; i < FRAME_COUNT; i++) {
    const img = new Image();
    img.src = frameSrc(state, i);
  }
}

const cat = document.getElementById('cat');

let state = 'focus';
let index = 0;

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

// 喝水提醒联动
if (window.petAPI) {
  if (window.petAPI.onDrinkWater) {
    window.petAPI.onDrinkWater(() => setState('warn'));
  }
  if (window.petAPI.onDrinkWaterReset) {
    window.petAPI.onDrinkWaterReset(() => setState('focus'));
  }
}
