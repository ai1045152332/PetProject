// tests/sprite-frames.test.js
// 内置精灵帧清单回归测试：node 直接跑
// 覆盖：目录枚举规则（只数 frame_NN.png / 跳过非目录与空目录 / 目录缺失不抛错）
//       以及共用 SharedAssets/Sprites 后各状态的真实帧数（软链必须能被主进程读到）
'use strict';

const path = require('path');

const MODULE_PATH = path.join(__dirname, '..', 'src', 'main', 'sprite-frames.js');
const { readFrameCounts, countFrames } = require(MODULE_PATH);

let failed = 0;
function check(name, cond) {
  if (!cond) failed += 1;
  console.log(`${cond ? '✅' : '❌'} ${name}`);
}

// 假 fs：readdirSync(root, {withFileTypes}) 返回 dirent，readdirSync(dir) 返回文件名数组
function fakeReader(tree) {
  return {
    readdirSync(dir, opts) {
      const key = dir.replace(/\\/g, '/');
      const hit = tree[key];
      if (hit === undefined) {
        throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
      }
      if (opts && opts.withFileTypes) {
        return hit.map((name) => ({
          name,
          isDirectory: () => !name.includes('.'),
        }));
      }
      return hit.filter((n) => n.includes('.'));
    },
  };
}

// ── 1. 目录枚举规则 ──
{
  const tree = {
    '/sprites': ['focus', 'idel', 'README.txt'],   // 文件不是状态目录
    '/sprites/focus': ['frame_00.png', 'frame_01.png', 'frame_02.png'],
    '/sprites/idel': ['frame_00.png', 'notes.md', 'frame_99.png'],
  };
  const reader = fakeReader(tree);
  const counts = readFrameCounts('/sprites', reader);
  check('按子目录枚举出各状态帧数', counts.focus === 3 && counts.idel === 2);
  check('非目录条目（README.txt）不当状态', counts.README === undefined && Object.keys(counts).length === 2);
  check('非 frame_NN.png 文件不计入', counts.idel === 2);
  check('帧文件名不按连续下标，数个数即可（frame_00 + frame_99 = 2 帧）', counts.idel === 2);
}

// ── 2. 空目录与缺失目录都不该冒出来 / 不该抛错 ──
{
  const counts = readFrameCounts('/sprites', fakeReader({
    '/sprites': ['focus', 'empty'],
    '/sprites/focus': ['frame_00.png'],
    '/sprites/empty': [],
  }));
  check('零帧的状态目录被丢弃（避免渲染层拿到 0 做取模）', counts.focus === 1 && Object.keys(counts).length === 1);
  check('Sprites 根目录不存在时返回空对象，不抛错', readFrameCounts('/nope', fakeReader({})).focus === undefined);
  check('countFrames 读不到目录返回 0', countFrames('/nope', fakeReader({})) === 0);
}

// ── 3. 真实素材：assets/Sprites 是指向 SharedAssets 的软链，主进程必须读得到 ──
{
  const real = readFrameCounts(path.join(__dirname, '..', 'assets', 'Sprites'));
  check('软链目录可枚举（assets/Sprites → SharedAssets/Sprites）', Object.keys(real).length >= 4);
  check('idel 已是 24 帧（mac 版新素材，不再是旧的 8 帧）', real.idel === 24);
  check('pet 已是 24 帧', real.pet === 24);
  check('focus / sleep 仍为 8 帧', real.focus === 8 && real.sleep === 8);
  check('hide 帧已随素材一并共用进来（1 帧）', real.hide === 1);
}

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
