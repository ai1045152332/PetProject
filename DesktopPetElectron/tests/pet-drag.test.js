// tests/pet-drag.test.js
// 手动拖窗回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：start 记录 offset / move 按 offset 搬窗且取整 / 未 start 时 move 无效 / end 后不再响应 move
'use strict';

const path = require('path');
const Module = require('module');

// ── mock electron（pet-window 顶层只解构 BrowserWindow / screen）──
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      BrowserWindow: class {},
      screen: { getPrimaryDisplay: () => ({ workAreaSize: { width: 1440, height: 900 } }) },
    };
  }
  return origLoad.apply(this, arguments);
};

const SRC = path.join(__dirname, '..', 'src', 'main');
const { createDragController } = require(path.join(SRC, 'pet', 'pet-window.js'));

let failed = 0;
function check(name, condition) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    console.error(`❌ ${name}`);
    failed += 1;
  }
}

/** 伪 BrowserWindow：只实现拖窗用到的接口，位置固定在 (500, 400)，setPosition 记录落点 */
const win = { getPosition: () => [500, 400], isDestroyed: () => false };
let placed = null;
win.setPosition = (nx, ny) => { placed = [nx, ny]; };
const drag = createDragController(win);

check('未按下时 move 无效', drag.move(999, 999) === false && placed === null);

// 鼠标在窗口内 (560, 450) 按下 → offset = 窗口原点 - 鼠标 = (500-560, 400-450) = (-60, -50)
drag.start(560, 450);
check('start 后进入拖动态', drag.dragging === true);

// 鼠标移到 (700, 600) → 窗口搬到 (700-60, 600-50) = (640, 550)
check('move 按 offset 搬窗', drag.move(700, 600) === true && placed[0] === 640 && placed[1] === 550);

// 2. 半像素坐标取整，避免窗口落在半个 DIP 上
// 1234.5-60=1174.5 → Math.round 取 1175；-0.4 → -0（与 0 相等）
drag.move(1234.5, 1234.5);
check('move 坐标取整', placed[0] === 1175 && placed[1] === 1185, JSON.stringify(placed));
drag.move(59.6, 50.4);
check('取整不会因 -0 报错', placed[0] === 0 && placed[1] === 0);

// 3. 松键后不再跟随
drag.end();
check('end 后退出拖动态', drag.dragging === false);
check('end 后 move 无效', drag.move(100, 100) === false);

// 4. 重复 start 会以新按下点重算 offset
drag.start(700, 600); // offset = (500-700, 400-600) = (-200, -200)
drag.move(800, 800);
check('重复 start 重算 offset', placed[0] === 600 && placed[1] === 600);
drag.end();

// 5. 窗口销毁后不炸
const dead = { isDestroyed: () => true, getPosition: () => [0, 0], setPosition: () => { throw new Error('不该被调用'); } };
const dragDead = createDragController(dead);
dragDead.start(1, 1);
check('销毁窗口：start/move 静默无效', dragDead.move(2, 2) === false && dragDead.dragging === false);

if (failed > 0) {
  console.error(`\n拖窗测试失败 ${failed} 项`);
  process.exit(1);
}
console.log('\n全部通过');
