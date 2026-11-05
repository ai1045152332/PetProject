// tests/metric-bar-image.test.js
// mac 顶栏「整条状态项」合成图回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：顶栏 parts 口径与 Swift 对齐、瓦片排版（猫/图标/数字/指标间隔）、alpha over 与裁剪、
//       合成落盘 1x+@2x 同名兄弟、值未变化不重写、素材缺失/尺寸不符时回落纯文字、
//       仓库里真实瓦片素材与 manifest 的自洽（防止改了脚本忘了重导素材）
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SRC = path.join(__dirname, '..', 'src', 'main');
const { computeTrayParts, computeTrayTitle, METRIC_ICONS } = require(path.join(SRC, 'system', 'system-monitor.js'));
const { MetricBarImage, layoutStrip, blitAlpha, glyphKey, bakeLuminanceToAlpha, CAT_SIZE_PT, CAT_GAP_PT, GLYPH_DY_PT, SYMBOL_DY_PT, SPACE_KEY } = require(path.join(SRC, 'system', 'metric-bar-image.js'));

const TILES_DIR = path.join(__dirname, '..', 'assets', 'menu-icons');

let failed = 0;
function check(name, condition) {
  if (condition) console.log(`✅ ${name}`);
  else { console.error(`❌ ${name}`); failed += 1; }
}

const MANIFEST = JSON.parse(fs.readFileSync(path.join(TILES_DIR, 'manifest.json'), 'utf8'));
const STRIP_H = MANIFEST.stripHeight;

// ── 1) parts 口径与 Swift refreshMenuBarMetrics 逐项对齐 ──
{
  const snap = {
    cpu: { percent: 23.4 },
    mem: { percent: 62.5 },
    disk: { percent: 60.9375 },
    net: { downKBps: 1000.4, upKBps: 200.6 },
  };
  const all = computeTrayParts(snap, () => true);
  check('parts 顺序与 Swift 一致（cpu/mem/disk/net）', all.map((p) => p.metric).join(',') === 'cpu,mem,disk,net');
  check('CPU 取整带 %（对齐 Swift \\(Int(cpu.rounded()))%）', all[0].text === '23%');
  check('内存四舍五入到整数', all[1].text === '63%');
  check('磁盘百分比取整', all[2].text === '61%');
  check('网络为「下行K/上行K」且无 KB/s 后缀（对齐 Swift）', all[3].text === '1000K/201K');
  check('parts 带 Swift 侧同款 SF Symbol 名', all.map((p) => p.symbol).join(',') === 'cpu,memorychip,internaldrive,arrow.up.arrow.down');
  check('未勾选的指标不出现在 parts', computeTrayParts(snap, (m) => m === 'disk').length === 1);
  check('采到 null 的指标不出现在 parts', computeTrayParts({ cpu: null, net: null }, () => true).length === 0);
  check('回落标题与 parts 同源（同一份数值不会出现两种口径）', computeTrayTitle(snap, () => true)
    === [`${METRIC_ICONS.cpu}23%`, `${METRIC_ICONS.mem}63%`, `${METRIC_ICONS.disk}61%`, `${METRIC_ICONS.net}1000K/201K`].join('  '));
}

// ── 2) 排版：猫 → 图标 → 数字，指标之间一个空格瓦片 ──
{
  const layout = layoutStrip([{ metric: 'cpu', text: '23%' }], MANIFEST);
  const keys = layout.tiles.map((t) => t.key);
  check('首张瓦片是猫且占满 22pt', layout.tiles[0].key === '@cat' && layout.tiles[0].w === CAT_SIZE_PT);
  check('排版序列 = 猫, cpu 图标, 2, 3, %', keys.join(',') === '@cat,cpu,g-2,g-3,g-pct');
  const xs = layout.tiles.map((t) => t.x);
  check('图标紧跟猫图并按 CAT_GAP 留白', layout.tiles[1].x === CAT_SIZE_PT + CAT_GAP_PT);
  check('猫图之后瓦片严格首尾相接（只留 CAT_GAP 一处空白）', layout.tiles.every((t, i) => {
    if (i === 0) return t.x === 0;
    if (i === 1) return t.x === layout.tiles[0].w + CAT_GAP_PT;
    return t.x === xs[i - 1] + layout.tiles[i - 1].w;
  }));
  check('总宽 = 末瓦片右边界', layout.width === xs[xs.length - 1] + layout.tiles[layout.tiles.length - 1].w);
  check('条高固定为菜单栏高', layout.height === STRIP_H);

  const two = layoutStrip([
    { metric: 'cpu', text: '5%' },
    { metric: 'net', text: '1K/2K' },
  ], MANIFEST);
  const twoKeys = two.tiles.map((t) => t.key);
  check('两个指标之间插入空格瓦片（对齐 Swift 的「 」连接）', twoKeys.join(',').includes(`g-pct,${SPACE_KEY},net`));
  check('空格瓦片宽度 = manifest 里的空格 advance', two.tiles.find((t) => t.key === SPACE_KEY).w === MANIFEST.tiles[SPACE_KEY].w);
  check('数字与空格瓦片下沉 GLYPH_DY_PT', two.tiles.filter((t) => t.key.startsWith('g-')).every((t) => t.dy === GLYPH_DY_PT));
  check('SF Symbol 图标瓦片下沉 SYMBOL_DY_PT（与数字独立可调）', two.tiles.filter((t) => ['cpu', 'net'].includes(t.key)).every((t) => t.dy === SYMBOL_DY_PT));
  check('两个旋钮可以不同（图标与数字并非同一条基线规则）', GLYPH_DY_PT !== SYMBOL_DY_PT);
  check('猫不下沉（它占满整高，没有基线概念）', layout.tiles[0].dy === 0);
  check('未知字符（例如中文）返回 null 触发回落', layoutStrip([{ metric: 'cpu', text: '高%' }], MANIFEST) === null);
  check('没有该指标瓦片时返回 null', layoutStrip([{ metric: 'gpu', text: '1%' }], MANIFEST) === null);
  check('字符映射：%/K/空格/数字都能找到瓦片键',
    glyphKey('%') === 'g-pct' && glyphKey('K') === 'g-K' && glyphKey(' ') === SPACE_KEY && glyphKey('7') === 'g-7');
  check('withCat=false 时从图标起排（供单独取图标条复用）',
    layoutStrip([{ metric: 'cpu', text: '1%' }], MANIFEST, { withCat: false }).tiles[0].key === 'cpu');
}

// ── 3) blit：alpha over 合成与越界裁剪 ──
{
  const dst = Buffer.alloc(4 * 2 * 4, 0); // 4×2 画布
  const src = Buffer.alloc(2 * 2 * 4, 0);
  for (let i = 0; i < 4; i += 1) { src[i * 4 + 3] = 128; src[i * 4] = 255; } // 半透明且带颜色（要被抹平成纯黑）
  blitAlpha(dst, 4, 2, src, 2, 2, 1, 0);
  check('只保留 alpha 形状（RGB 写 0）', dst[4] === 0 && dst[5] === 0 && dst[6] === 0);
  check('alpha over：空白处 = src 半透明 128', dst[7] === 128);
  const before = dst[7];
  blitAlpha(dst, 4, 2, src, 2, 2, 1, 0);
  check('重复叠加按 over 收敛（128 over 128 ≈ 192）', before === 128 && dst[7] > before && dst[7] <= 255);
  const clipped = Buffer.alloc(3 * 1 * 4, 0);
  const wide = Buffer.alloc(4 * 1 * 4, 0);
  wide[3] = 200; wide[7] = 200; wide[11] = 200; wide[15] = 200;
  blitAlpha(clipped, 3, 1, wide, 4, 1, 1, 0);
  check('越界瓦片按画布宽裁掉尾巴而不崩', clipped[3] === 0 && clipped[7] === 200 && clipped[11] === 200);
  const off = Buffer.alloc(1 * 1 * 4, 0);
  blitAlpha(off, 1, 1, wide, 4, 1, -3, 0);
  check('负偏移只画落进画布的部分', off[3] === 200);
}

// ── 4) 合成器：假 nativeImage + 临时目录（假 PNG 用 "PNG:WxH" 文本表达尺寸，读回时解析）──
function makeEnv(manifest = MANIFEST) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'metric-bar-'));
  fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify(manifest));
  for (const key of Object.keys(manifest.tiles)) {
    for (const scale of [1, 2]) {
      const w = manifest.tiles[key].w * scale;
      fs.writeFileSync(path.join(dir, `${key}.${scale}x.png`), Buffer.from(`PNG:${w}x${manifest.stripHeight * scale}`));
    }
  }
  const catPath = path.join(dir, 'MenuBarIcon.png');
  fs.writeFileSync(catPath, Buffer.from('PNG:360x348'));
  const images = [];
  const created = [];
  const alphaOf = (w, h) => {
    const b = Buffer.alloc(w * h * 4, 0);
    // RGB 写满白：模拟「亮度即形状」的模板素材，亮度归一后形状（alpha）保持不变
    for (let i = 0; i < w * h; i += 1) { b[i * 4] = 255; b[i * 4 + 1] = 255; b[i * 4 + 2] = 255; b[i * 4 + 3] = 255; }
    return b;
  };
  const makeImage = (label, w, h, data) => {
    const img = {
      label,
      isEmpty: () => !(w && h),
      getSize: () => ({ width: w, height: h }),
      getBitmap: () => data || alphaOf(w, h),
      resize: (opts) => makeImage(`${label}~resize`, opts.width, opts.height, alphaOf(opts.width, opts.height)),
      toPNG: () => Buffer.from(`PNG:${w}x${h}`),
      setTemplateImage: (flag) => { img.template = Boolean(flag); },
    };
    images.push(img);
    return img;
  };
  const nativeImage = {
    createFromPath(p) {
      created.push(p);
      if (!fs.existsSync(p) || !fs.statSync(p).isFile()) return makeImage(path.basename(p), 0, 0, Buffer.alloc(0));
      const txt = fs.readFileSync(p, 'utf8');
      const m = /^PNG:(\d+)x(\d+)$/.exec(txt);
      if (!m) return makeImage(path.basename(p), 0, 0, Buffer.alloc(0));
      return makeImage(path.basename(p), parseInt(m[1], 10), parseInt(m[2], 10));
    },
    createFromBitmap(buf, opts) {
      return makeImage('bitmap', opts.width, opts.height, buf);
    },
  };
  return { dir, nativeImage, catPath, created, images };
}

{
  const env = makeEnv();
  const warns = [];
  const bar = new MetricBarImage({
    nativeImage: env.nativeImage,
    tileDir: env.dir,
    outDir: path.join(env.dir, 'menubar'),
    catPath: env.catPath,
    warn: (m) => warns.push(m),
  });
  const parts = [{ metric: 'cpu', symbol: 'cpu', text: '23%' }];
  const img = bar.imageFor(parts);
  const layout = layoutStrip(parts, MANIFEST);
  check('imageFor 返回 nativeImage（走 setImage）', img && img.label === 'menubar-metrics.png');
  check('合成图标记为模板图（深浅色菜单栏自动反色）', img && img.template === true);
  check('读回的是 1x 路径且 @2x 同名兄弟已落盘（Retina 清晰）',
    fs.existsSync(path.join(env.dir, 'menubar', 'menubar-metrics.png'))
    && fs.existsSync(path.join(env.dir, 'menubar', 'menubar-metrics@2x.png')));
  const p1 = fs.readFileSync(path.join(env.dir, 'menubar', 'menubar-metrics.png'), 'utf8');
  const p2 = fs.readFileSync(path.join(env.dir, 'menubar', 'menubar-metrics@2x.png'), 'utf8');
  check(`1x 画布尺寸 = 排版点尺寸（${layout.width}x${layout.height}）`, p1 === `PNG:${layout.width}x${layout.height}`);
  check('2x 画布尺寸正好是 1x 的两倍', p2 === `PNG:${layout.width * 2}x${layout.height * 2}`);
  check('读回图的 DIP 尺寸按 1x 报（@2x 只作高分屏表示）', img.getSize().width === layout.width);

  // 值没变不重编码重落盘
  const mtimeBefore = fs.statSync(path.join(env.dir, 'menubar', 'menubar-metrics.png')).mtimeMs;
  const again = bar.imageFor(parts);
  const mtimeAfter = fs.statSync(path.join(env.dir, 'menubar', 'menubar-metrics.png')).mtimeMs;
  check('同一串数值重复调用直接复用缓存图（每秒调用不重复写盘）', again === img && mtimeBefore === mtimeAfter);

  // 数值变化（排版宽度不同 → 像素真的变了）要重新合成
  const img2 = bar.imageFor([{ metric: 'cpu', symbol: 'cpu', text: '5%' }]);
  check('数值变化后重新合成新图', img2 !== img);

  check('无指标返回 null（顶栏清空走纯文字路径）', bar.imageFor([]) === null);
}

{
  // 素材缺失：删掉一个字形瓦片 → 整条回落，不抛错
  const env = makeEnv();
  fs.unlinkSync(path.join(env.dir, 'g-pct.1x.png'));
  const warns = [];
  const bar = new MetricBarImage({
    nativeImage: env.nativeImage, tileDir: env.dir, outDir: path.join(env.dir, 'menubar'), catPath: env.catPath,
    warn: (m) => warns.push(m),
  });
  check('缺瓦片时 imageFor 返回 null（回落 Unicode 文字标题）', bar.imageFor([{ metric: 'cpu', text: '23%' }]) === null);
  check('回落时给出可诊断的告警', warns.some((w) => w.includes('g-pct')));
}

{
  // manifest 与实际瓦片尺寸不一致（改了 Swift 脚本忘了重导素材）→ 回落而不是拼错位图
  const env = makeEnv();
  const bad = JSON.parse(JSON.stringify(MANIFEST));
  bad.tiles.cpu.w = 99;
  fs.writeFileSync(path.join(env.dir, 'manifest.json'), JSON.stringify(bad));
  const warns = [];
  const bar = new MetricBarImage({
    nativeImage: env.nativeImage, tileDir: env.dir, outDir: path.join(env.dir, 'menubar'), catPath: env.catPath,
    warn: (m) => warns.push(m),
  });
  check('瓦片尺寸与 manifest 不符时回落', bar.imageFor([{ metric: 'cpu', text: '23%' }]) === null);
  check('尺寸不符有告警', warns.some((w) => w.includes('不一致') || w.includes('尺寸异常')));
}

{
  // manifest.json 整体缺失（新克隆没跑生成脚本）
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'metric-bar-empty-'));
  const warns = [];
  const env = makeEnv();
  const bar = new MetricBarImage({
    nativeImage: env.nativeImage, tileDir: dir, outDir: path.join(dir, 'menubar'), catPath: env.catPath,
    warn: (m) => warns.push(m),
  });
  check('没有 manifest.json 时回落并提示去跑生成脚本',
    bar.imageFor([{ metric: 'cpu', text: '23%' }]) === null && warns.some((w) => w.includes('dump-menu-icons')));
}

// ── 5) 仓库真实素材自洽（不依赖 electron：直接读 PNG 头部）──
{
  const pngDims = (p) => {
    const b = fs.readFileSync(p);
    // PNG 签名 8 字节 + IHDR 长度 4 + 类型 4 → 宽高各 4 字节大端
    assert.strictEqual(b.slice(12, 16).toString('ascii'), 'IHDR');
    return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
  };
  const missing = [];
  const mismatched = [];
  for (const [key, tile] of Object.entries(MANIFEST.tiles)) {
    for (const scale of [1, 2]) {
      const p = path.join(TILES_DIR, `${key}.${scale}x.png`);
      if (!fs.existsSync(p)) { missing.push(path.basename(p)); continue; }
      const d = pngDims(p);
      if (d.w !== tile.w * scale || d.h !== MANIFEST.stripHeight * scale) {
        mismatched.push(`${path.basename(p)}=${d.w}x${d.h} 期望 ${tile.w * scale}x${MANIFEST.stripHeight * scale}`);
      }
    }
  }
  check('真实瓦片齐备（manifest 每个键都有 1x/2x）' + missing.join(','), missing.length === 0);
  check('真实瓦片尺寸与 manifest 一致' + mismatched.join(','), mismatched.length === 0);
  check('四个指标的 SF Symbol 瓦片都在', ['cpu', 'mem', 'disk', 'net'].every((k) => MANIFEST.tiles[k] && MANIFEST.tiles[k].kind === 'symbol'));
  check('顶栏用到的符号名都有对应指标键', computeTrayParts(
    { cpu: { percent: 1 }, mem: { percent: 1 }, disk: { percent: 1 }, net: { downKBps: 1, upKBps: 1 } }, () => true,
  ).every((p) => MANIFEST.tiles[p.metric]));
}

// ── 6) 猫图标的亮度→alpha 归一（回归护栏：顶栏左边变成实心黑块）──
{
  // MenuBarIcon.png 的真实特征：alpha 全 255，形状靠「暗底 + 亮墨」的亮度表达
  const px = (r, g, b, a) => [r, g, b, a];
  const src = Buffer.alloc(4 * 4, 0);
  const raw = [...px(8, 9, 11, 255), ...px(8, 9, 11, 255), ...px(240, 240, 240, 255), ...px(255, 255, 255, 255)];
  raw.forEach((v, i) => { src[i] = v; });
  const baked = bakeLuminanceToAlpha(src);
  check('暗底像素归一后几乎全透明（不再当成墨 → 不会整块涂黑）', baked[3] < 16 && baked[7] < 16);
  check('亮墨像素保留不透明', baked[11] > 230 && baked[15] === 255);
  check('归一后 RGB 归零（模板图只看 alpha）', baked[0] === 0 && baked[1] === 0 && baked[2] === 0);

  // 白底假猫（亮度 255）走完整链路：归一后形状不应丢失
  const env = makeEnv();
  const bar = new MetricBarImage({
    nativeImage: env.nativeImage, tileDir: env.dir, outDir: path.join(env.dir, 'menubar'), catPath: env.catPath,
  });
  check('素材加载成功', bar.load() === true);
  const cat = bar.bitmaps['@cat@1'];
  check('亮底猫瓦片归一后仍保留形状（没被误抹成空白）', cat.data.every((v, i) => i % 4 !== 3 || v === 255));

  // 用全暗的假猫（alpha 全 255 但亮度 0）验证：归一后猫区完全透明
  const darkEnv = makeEnv();
  const darkCat = Buffer.alloc(CAT_SIZE_PT * CAT_SIZE_PT * 4, 0);
  for (let i = 0; i < CAT_SIZE_PT * CAT_SIZE_PT; i += 1) { darkCat[i * 4 + 3] = 255; } // 只有 alpha，RGB 全黑
  darkEnv.nativeImage = {
    createFromPath: (p) => (p === darkEnv.catPath
      ? { getSize: () => ({ width: CAT_SIZE_PT, height: CAT_SIZE_PT }), getBitmap: () => darkCat, resize: () => ({ getSize: () => ({ width: CAT_SIZE_PT, height: CAT_SIZE_PT }), getBitmap: () => darkCat }) }
      : env.nativeImage.createFromPath(p)),
    createFromBitmap: env.nativeImage.createFromBitmap,
  };
  const bar2 = new MetricBarImage({
    nativeImage: darkEnv.nativeImage, tileDir: darkEnv.dir, outDir: path.join(darkEnv.dir, 'menubar'), catPath: darkEnv.catPath,
  });
  bar2.load();
  const cat2 = bar2.bitmaps['@cat@1'];
  check('全暗猫素材归一后 alpha 全 0（顶栏不会变黑块）', cat2 && cat2.data.every((v, i) => i % 4 !== 3 || v === 0));
}

if (failed > 0) {
  console.error(`\n顶栏合成图测试失败 ${failed} 项`);
  process.exit(1);
}
assert(failed === 0);
console.log('\n全部通过');
