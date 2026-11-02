// tests/custom-sprite.test.js
// 自定义形象图存储回归测试：node 直接跑，mock electron app.getPath 到临时 userData
// 覆盖：状态校验、扩展名/大小校验、安装落盘到 userData、重复上传替换、清除回退、快照映射
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const Module = require('module');

const USER_DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-sprite-test-'));
const SRC = path.join(__dirname, '..', 'src', 'main');

// mock electron：config-store / custom-sprite-store 只用 app.getPath
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return { app: { getPath: () => USER_DATA } };
  }
  return origLoad.apply(this, arguments);
};

const store = require(path.join(SRC, 'custom-sprite-store.js'));

let failed = 0;
function check(name, cond) {
  if (!cond) failed += 1;
  console.log(`${cond ? '✅' : '❌'} ${name}`);
}

// 造一张“源图”：写到 userData 之外的临时文件
function makeSrc(name, bytes = 16) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-sprite-src-'));
  const p = path.join(dir, name);
  fs.writeFileSync(p, Buffer.alloc(bytes, 1));
  return p;
}

const spriteDir = path.join(USER_DATA, 'CustomSprites');

// ── 1. 状态校验 ──
let res = store.installLocalImage('hide', makeSrc('a.png'));
check('非法状态 hide 被拒', res.ok === false);
res = store.installLocalImage('bogus', makeSrc('a.png'));
check('未知状态被拒', res.ok === false);

// ── 2. 扩展名校验 ──
res = store.installLocalImage('focus', makeSrc('notes.txt'));
check('非图片扩展名被拒', res.ok === false && /PNG|图片/.test(res.error));

// ── 3. 文件不存在 ──
res = store.installLocalImage('focus', path.join(USER_DATA, 'nope-does-not-exist.png'));
check('不存在的文件被拒', res.ok === false);

// ── 4. 正常安装：落到 userData/CustomSprites/local-focus.png ──
const png = makeSrc('cat.png');
res = store.installLocalImage('focus', png);
check('安装成功返回 ok', res.ok === true);
check('落盘到 userData/CustomSprites', res.file && res.file.startsWith(spriteDir));
check('文件名形如 local-focus.png', path.basename(res.file) === 'local-focus.png');
check('文件确实存在', fs.existsSync(res.file));
check('内容已拷贝', Buffer.compare(fs.readFileSync(res.file), fs.readFileSync(png)) === 0);

// ── 5. 快照：focus 有，其它无 ──
let snap = store.snapshotFileMap();
check('快照 focus 指向文件', snap.focus === res.file);
check('快照 idel 为空', snap.idel === null);
let status = store.statusMap();
check('状态图 focus=true', status.focus === true);
check('状态图 pet=false', status.pet === false);

// ── 6. 重复上传同名不同扩展会替换旧图，只留一份 ──
const jpg = makeSrc('cat2.jpg');
res = store.installLocalImage('focus', jpg);
check('改用 jpg 上传成功', res.ok === true && path.basename(res.file) === 'local-focus.jpg');
const focusFiles = fs.readdirSync(spriteDir).filter((n) => n.startsWith('local-focus.'));
check('旧 png 已被替换，只剩一份', focusFiles.length === 1 && focusFiles[0] === 'local-focus.jpg');

// ── 7. 清除回到默认 ──
res = store.clearLocalImage('focus');
check('清除成功', res.ok === true);
check('清除后文件已删', !fs.existsSync(path.join(spriteDir, 'local-focus.jpg')));
check('清除后快照 focus 为空', store.snapshotFileMap().focus === null);
check('清除不存在的状态也返回成功', store.clearLocalImage('idel').ok === true);

// ── 8. 多状态独立存放 ──
store.installLocalImage('sleep', makeSrc('s.png'));
store.installLocalImage('pet', makeSrc('p.png'));
status = store.statusMap();
check('sleep 已自定义', status.sleep === true);
check('pet 已自定义', status.pet === true);
check('idel 仍默认', status.idel === false);

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
