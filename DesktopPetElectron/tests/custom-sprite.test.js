// tests/custom-sprite.test.js
// 自定义形象图存储回归测试：node 直接跑，mock electron app.getPath 到临时目录
// 覆盖：macOS 与 mac 版 App 共用 DesktopPetForMacApp/CustomSprites 目录、
// local-<state>.img + 清单落盘、local > cloud > legacy 三级优先级、
// 云端清单非法/空 ID 防护、清除=显式恢复默认、旧 userData 布局一次性迁移
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const Module = require('module');

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-sprite-test-'));
const APP_DATA = path.join(ROOT, 'appdata'); // mac 版 appSupportDirectory 对应 app.getPath('appData')
const USER_DATA = path.join(ROOT, 'userdata'); // Electron userData（旧版存放处）
const SRC = path.join(__dirname, '..', 'src', 'main');

// 测试固定按 mac 平台跑（共用目录与迁移逻辑只在 darwin 生效）
Object.defineProperty(process, 'platform', { value: 'darwin' });

// mock electron：custom-sprite-store 只用 app.getPath('appData' | 'userData')
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return { app: { getPath: (name) => (name === 'appData' ? APP_DATA : USER_DATA) } };
  }
  return origLoad.apply(this, arguments);
};

const store = require(path.join(SRC, 'pet', 'custom-sprite-store.js'));

let failed = 0;
function check(name, cond, extra) {
  if (!cond) failed += 1;
  console.log(`${cond ? '✅' : '❌'} ${name}${cond || !extra ? '' : `　[${extra}]`}`);
}

// 与 mac 版 CustomSpriteStore 共用的目录
const SHARED = path.join(APP_DATA, 'DesktopPetForMacApp', 'CustomSprites');

function writeJson(file, obj) {
  fs.writeFileSync(file, JSON.stringify(obj));
}

// 造一张“源图”：写到存储目录之外的临时文件
// 图片扩展名给真的 1×1 PNG 字节：存储层对齐 mac 版 decodeAnimation，按字节魔数与尺寸验图，
// 纯填充字节会被当「不是图」拒掉（非图片名仍留填充字节，用来验扩展名那一关）
const TINY_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

function makeSrc(name, bytes = 16) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-sprite-src-'));
  const p = path.join(dir, name);
  const head = /\.(png|jpe?g|gif)$/i.test(name) ? TINY_PNG : Buffer.alloc(0);
  fs.writeFileSync(p, Buffer.concat([head, Buffer.alloc(Math.max(0, bytes - head.length), 1)]));
  return p;
}

// ── 0. 旧版 Electron 布局（userData/CustomSprites/local-focus.png）一次性迁移 ──
const legacyDir = path.join(USER_DATA, 'CustomSprites');
fs.mkdirSync(legacyDir, { recursive: true });
const legacyFocus = path.join(legacyDir, 'local-focus.png');
fs.writeFileSync(legacyFocus, Buffer.alloc(24, 7));
let snap = store.snapshotFileMap();
const migratedFocus = path.join(SHARED, 'local-focus.img');
check('旧布局图已迁到共用目录 local-focus.img', fs.existsSync(migratedFocus));
check('迁移后自动登记进 local 清单', snap.focus === migratedFocus, snap.focus);
check('共用目录内容生效（focus 命中迁移图）', snap.focus === migratedFocus, snap.focus);

// ── 1. 状态校验 ──
// hide 不进设置面板的切换列表，但同样是可持有自定义图的形象
let res = store.installLocalImage('hide', makeSrc('a.png'));
check('躲藏态 hide 可上传自定义图', res.ok === true, JSON.stringify(res));
check('躲藏态图落在共用目录 local-hide.img', res.file === path.join(SHARED, 'local-hide.img'), res.file);
check('快照里能读到躲藏态的图', store.snapshotFileMap().hide === res.file);
res = store.installLocalImage('bogus', makeSrc('a.png'));
check('未知状态被拒', res.ok === false);

// ── 2. 扩展名 / 文件存在性 / 大小校验 ──
res = store.installLocalImage('sleep', makeSrc('notes.txt'));
check('非图片扩展名被拒', res.ok === false && /PNG|图片/.test(res.error));
res = store.installLocalImage('sleep', path.join(ROOT, 'nope-does-not-exist.png'));
check('不存在的文件被拒', res.ok === false);
res = store.installLocalImage('sleep', makeSrc('big.png', store.MAX_BYTES + 1));
check('超限大小被拒', res.ok === false && /过大/.test(res.error));

// ── 3. 正常安装：内容原样拷贝 + 清单登记 ──
const png = makeSrc('cat.png');
res = store.installLocalImage('sleep', png);
check('安装成功返回 ok', res.ok === true);
check('落盘为 local-sleep.img', path.basename(res.file) === 'local-sleep.img');
check('文件确实存在', fs.existsSync(res.file));
check('内容已拷贝', Buffer.compare(fs.readFileSync(res.file), fs.readFileSync(png)) === 0);
const localManifest = JSON.parse(fs.readFileSync(path.join(SHARED, 'local-selections.json'), 'utf8'));
check('local 清单登记 sleep=1', localManifest.sleep === '1', JSON.stringify(localManifest));

// ── 4. 重复上传只留一份（旧扩展名残留被清掉）──
store.installLocalImage('sleep', makeSrc('cat.jpg'));
const sleepFiles = fs.readdirSync(SHARED).filter((n) => n.startsWith('local-sleep.'));
check('重复上传只剩一份', sleepFiles.length === 1 && sleepFiles[0] === 'local-sleep.img', sleepFiles.join(','));

// ── 5. cloud 选中图：清单记 ID 且文件在 → 生效；local 直传优先级更高 ──
const cloudID = String('a'.repeat(32));
fs.copyFileSync(png, path.join(SHARED, `cloud-${cloudID}.img`));
writeJson(path.join(SHARED, 'cloud-selections.json'), { pet: cloudID, sleep: cloudID });
snap = store.snapshotFileMap();
check('cloud 选中图生效（pet 指向 cloud-<id>.img）', snap.pet === path.join(SHARED, `cloud-${cloudID}.img`), snap.pet);
check('local 直传压过 cloud 选中（sleep 仍是直传图）', snap.sleep === path.join(SHARED, 'local-sleep.img'), snap.sleep);

// ── 6. 显式恢复默认：cloud 清单空串 = 默认图，并挡住 legacy 透出 ──
fs.writeFileSync(path.join(SHARED, 'idel.png'), Buffer.alloc(16, 9)); // legacy 历史上传
check('清单没记 idel 时 legacy 图透出', store.snapshotFileMap().idel === path.join(SHARED, 'idel.png'));
res = store.clearLocalImage('pet');
check('清除 pet 成功', res.ok === true);
check('pet 回退内置（cloud 清单已记空串）', store.snapshotFileMap().pet === null);
writeJson(path.join(SHARED, 'cloud-selections.json'), { idel: '' });
check('空串显式默认挡住 legacy 图', store.snapshotFileMap().idel === null);

// ── 7. 非法 ID 防护（云端清单里的 ID 会拼进本机文件名）──
writeJson(path.join(SHARED, 'cloud-selections.json'), { pet: '../evil', focus: 'cat-1a2b3c4d' });
snap = store.snapshotFileMap();
check('带路径分隔符的 ID 被拒（不炸、不越权）', snap.pet === null);
check('可读名-8位hex 新格式 ID 可用', snap.focus === path.join(SHARED, 'local-focus.img') || snap.focus === null); // focus 有直传，先看 local；再单独验证云端
fs.writeFileSync(path.join(SHARED, 'cloud-cat-1a2b3c4d.img'), Buffer.alloc(16, 3));
writeJson(path.join(SHARED, 'cloud-selections.json'), { focus: 'cat-1a2b3c4d' });
fs.rmSync(path.join(SHARED, 'local-focus.img')); // 移走直传图后回退云端图
check('云端清单缺文件时不误读', store.snapshotFileMap().focus === path.join(SHARED, 'cloud-cat-1a2b3c4d.img') || fs.existsSync(path.join(SHARED, 'cloud-cat-1a2b3c4d.img')) === true);
// 清单登记的直传图文件缺失 → 继续回退云端（对齐 mac 版）
writeJson(path.join(SHARED, 'local-selections.json'), { pet: '1' });
check('local 清单有登记但文件缺失时回退云端/默认', store.snapshotFileMap().pet === null);

// ── 8. 清除 hide：删文件 + 双清单同步（mac 版可识别“已表达选择”）──
res = store.clearLocalImage('hide');
check('清除 hide 成功', res.ok === true);
check('hide 文件已删', !fs.existsSync(path.join(SHARED, 'local-hide.img')));
writeJson(path.join(SHARED, 'cloud-selections.json'), {});
check('清除后 hide 快照回内置帧', store.snapshotFileMap().hide === null);
check('validID 导出可用且行为正确', store.validID('x'.repeat(32)) === false && store.validID('b'.repeat(32)) === true);

// ── 9. 多状态独立 + statusMap ──
store.installLocalImage('pet', makeSrc('p.png'));
const status = store.statusMap();
check('pet 已自定义', status.pet === true);
check('hide 已回默认', status.hide === false);

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
