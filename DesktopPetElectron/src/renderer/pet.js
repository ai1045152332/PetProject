// src/renderer/pet.js
// 小猫帧循环（focus / idel / sleep / pet 四态，各 8 帧）
// 喝水提醒触发时专注动画从头播放唤起注意（原 warn 状态已合并进专注）。
// 状态由设置面板「宠物信息」切换（主进程 → pet:state），后续 P1 再由状态机自动流转。
'use strict';

// 各状态帧数（assets/Sprites/<state>/frame_XX.png）
const FRAME_COUNTS = { focus: 8, idel: 8, sleep: 8, pet: 8 };
const FPS = 12;
const FRAME_INTERVAL = 1000 / FPS;

const pad2 = (n) => String(n).padStart(2, '0');
const frameSrc = (state, i) => `../../assets/Sprites/${state}/frame_${pad2(i)}.png`;

// 预加载全部帧，避免切换状态时闪烁
for (const [state, count] of Object.entries(FRAME_COUNTS)) {
  for (let i = 0; i < count; i++) {
    const img = new Image();
    img.src = frameSrc(state, i);
  }
}

const cat = document.getElementById('cat');

let state = 'focus';
let index = 0;

// 状态切换：不认识的 state 忽略，避免渲染层出现空 src
function setState(next) {
  if (!FRAME_COUNTS[next] || state === next) return;
  state = next;
  index = 0;
  cat.src = frameSrc(state, 0);
}

setInterval(() => {
  index = (index + 1) % FRAME_COUNTS[state];
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

// 设置面板切换形象
if (window.petAPI && window.petAPI.onPetState) {
  window.petAPI.onPetState((next) => setState(next));
}
