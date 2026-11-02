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

// ── 鼠标交互：手动拖窗 + 右键菜单（对标 Swift 版 CatView）──
// 不用 -webkit-app-region: drag：原生拖拽区会吞掉鼠标事件，右键菜单弹不出来
let dragging = false;
let moveQueued = false;
let lastMove = null;

function sendMove() {
  moveQueued = false;
  if (!dragging || !lastMove || !window.petAPI) return;
  window.petAPI.dragMove(lastMove.x, lastMove.y);
}

window.addEventListener('mousedown', (e) => {
  if (e.button !== 0 || !window.petAPI) return;
  dragging = true;
  window.petAPI.dragStart(e.screenX, e.screenY);
});

window.addEventListener('mousemove', (e) => {
  if (!dragging) return;
  // 鼠标滑出窗口外松键时收不到 mouseup，按按键状态兜底结束
  if (e.buttons === 0) {
    dragging = false;
    if (window.petAPI) window.petAPI.dragEnd();
    return;
  }
  // 按帧合并 mousemove，避免高频 IPC 拖垮主进程
  lastMove = { x: e.screenX, y: e.screenY };
  if (!moveQueued) {
    moveQueued = true;
    requestAnimationFrame(sendMove);
  }
});

window.addEventListener('mouseup', (e) => {
  if (e.button !== 0 || !dragging) return;
  dragging = false;
  if (window.petAPI) window.petAPI.dragEnd();
});

// 右键 → 弹原生菜单（对标 Swift 版 CatView.rightMouseDown）
window.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  if (window.petAPI) window.petAPI.requestContextMenu();
});
