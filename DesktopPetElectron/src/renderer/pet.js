// src/renderer/pet.js
// 小猫帧循环（focus / idel / sleep / pet / hide 五态，帧数由主进程枚举目录后下发）
// 喝水提醒触发时专注动画从头播放唤起注意（原 warn 状态已合并进专注）。
// 状态由主进程状态机下发（专注跟随 / 贴边躲藏 / 设置面板 / 右键「抚摸」），
// 躲藏额外带 facing：素材只画一侧探头，贴右边时镜像并把画面钉在那条边上。
'use strict';

// 各状态帧数：先给一份保守兜底，真值由主进程枚举 assets/Sprites/<state>/ 后回传（pet:frame-counts）。
// 不写死的原因：素材与 mac 原生版共用 SharedAssets/Sprites，idel / pet 已迭代到 24 帧，
// 写死 8 会只播前三分之一、循环在中间卡断。
const FALLBACK_COUNTS = { focus: 8, idel: 8, sleep: 8, pet: 8, hide: 1 };
let frameCounts = { ...FALLBACK_COUNTS };
const FPS = 12;                     // 与 Swift 版 PetViewModel 的 12 FPS 一致
const FRAME_INTERVAL = 1000 / FPS;

const pad2 = (n) => String(n).padStart(2, '0');
const frameSrc = (state, i) => `../../assets/Sprites/${state}/frame_${pad2(i)}.png`;

/** 预加载全部帧，避免切换状态时闪烁 */
function preloadFrames(counts) {
  for (const [state, count] of Object.entries(counts)) {
    for (let i = 0; i < count; i++) {
      const img = new Image();
      img.src = frameSrc(state, i);
    }
  }
}

// 先用兜底帧数预加载，拿到真值后再补一次
preloadFrames(frameCounts);

const cat = document.getElementById('cat');

let state = 'focus';
let facing = 'right';
let index = 0;
// 各状态自定义形象图：{ state: fileURL }，无则该状态走内置帧动画
let sprites = {};

/** 当前帧应显示的 src：有自定义图就用它（单图静态），否则用内置帧 */
function srcFor(nextState, i) {
  const custom = sprites[nextState];
  return custom || frameSrc(nextState, i);
}

/** 躲藏时把素材裁切边钉在屏幕那条边上（对齐 mac 版 spriteRect 的 originX 修正）：
 *  素材的裁切边在左侧，所以贴左用原图靠左、贴右镜像后靠右 */
function syncClasses() {
  cat.classList.toggle('hide-left', state === 'hide' && facing === 'left');
  cat.classList.toggle('hide-right', state === 'hide' && facing === 'right');
}

// 状态切换：不认识的 state 忽略（尤其 hide 必须等主进程确认已吸附才能显示，
// 否则半个身子还在屏外），渲染层不自行推状态机
function setState(next, { restart = false } = {}) {
  if (!frameCounts[next]) return;
  if (state !== next) {
    state = next;
    index = 0;
  } else if (restart) {
    index = 0;
  } else {
    return;
  }
  syncClasses();
  cat.src = srcFor(state, index);
}

/** 应用主进程推来的状态包：{ state, facing, reset }（兼容老版直传字符串） */
function applyStatePayload(payload) {
  const next = payload && typeof payload === 'object' ? payload.state : payload;
  if (payload && typeof payload === 'object' && payload.facing) facing = payload.facing;
  setState(next, { restart: Boolean(payload && typeof payload === 'object' && payload.reset) });
  syncClasses();
}

setInterval(() => {
  index = (index + 1) % (frameCounts[state] || 1);
  cat.src = srcFor(state, index);
}, FRAME_INTERVAL);

// 喝水提醒联动：提醒触发时专注动画从第 0 帧重新播放（原 warn 切换已合并进专注）
if (window.petAPI && window.petAPI.onDrinkWater) {
  window.petAPI.onDrinkWater(() => {
    setState('focus', { restart: true });
  });
}

// Todo 到期联动：同喝水提醒，专注动画从第 0 帧重播唤起注意（提醒卡由主进程弹）
if (window.petAPI && window.petAPI.onTodoReminder) {
  window.petAPI.onTodoReminder((payload) => applyStatePayload(payload || { state: 'focus', reset: true }));
}

// 主进程状态机切换形象（专注跟随 / 贴边躲藏 / 设置面板 / 右键抚摸）
if (window.petAPI && window.petAPI.onPetState) {
  window.petAPI.onPetState((payload) => applyStatePayload(payload));
}

// 应用自定义形象映射：换图后立即重绘当前状态（新增→显示单图，清除→恢复帧动画）
function applySprites(map) {
  sprites = map || {};
  cat.src = srcFor(state, index);
  syncClasses();
}

if (window.petAPI && window.petAPI.onPetSprite) {
  window.petAPI.onPetSprite((map) => applySprites(map));
}
// 刚启动时主进程可能还没推，主动拉一次，保证重启后自定义形象仍在
if (window.petAPI && window.petAPI.requestSpriteSnapshot) {
  window.petAPI.requestSpriteSnapshot().then(applySprites).catch(() => {});
}

// 拉真实帧数：拿到后重新预加载，并把当前下标夹回合法范围（8 帧→ 24 帧不会错位）
if (window.petAPI && window.petAPI.requestFrameCounts) {
  window.petAPI.requestFrameCounts().then((counts) => {
    if (!counts || !Object.keys(counts).length) return; // 主进程没读到就继续用兜底
    frameCounts = counts;
    preloadFrames(counts);
    index = index % (frameCounts[state] || 1);
    cat.src = srcFor(state, index);
  }).catch(() => {});
}

// ── 鼠标交互：手动拖窗 + 右键菜单（对标 Swift 版 CatView）──
// 不用 -webkit-app-region: drag：原生拖拽区会吞掉鼠标事件，右键菜单弹不出来
let dragging = false;
let moveQueued = false;
let lastMove = null;
let downAt = null;   // 按下点（屏幕坐标）：用于区分“拖过”与“原地点两下”
let pressedMoved = false; // 本次按下期间是否移动过（移动过就是拖动，不算点击）

function sendMove() {
  moveQueued = false;
  if (!dragging || !lastMove || !window.petAPI) return;
  window.petAPI.dragMove(lastMove.x, lastMove.y);
}

window.addEventListener('mousedown', (e) => {
  if (e.button !== 0 || !window.petAPI) return;
  dragging = true;
  downAt = { x: e.screenX, y: e.screenY };
  pressedMoved = false;
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
  // 拖动位移超过阈值就标脏，后续 dblclick 不再当作“双击开清单”
  if (downAt && Math.hypot(e.screenX - downAt.x, e.screenY - downAt.y) > 6) pressedMoved = true;
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
  if (!window.petAPI) return;
  // 拖动过→交给主进程做贴边判定 / 拖出现身；原地点松手→当作单击
  if (pressedMoved) window.petAPI.dragEnd();
  else if (window.petAPI.notifyClick) window.petAPI.notifyClick();
});

// 双击宠物 → 打开 Todo 清单（对标 mac 版 CatView mouseDown clickCount == 2 → showTodoList）
// 拖动过（位移 > 6px）或仍在拖窗中不算点击，避免拖完窗口就弹清单
window.addEventListener('dblclick', (e) => {
  if (e.button !== 0 || !window.petAPI || !window.petAPI.openTodoList) return;
  if (dragging || pressedMoved) return;
  window.petAPI.openTodoList();
});

// 右键 → 弹原生菜单（对标 Swift 版 CatView.rightMouseDown）
window.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  if (window.petAPI) window.petAPI.requestContextMenu();
});
