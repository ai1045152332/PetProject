// src/main/metric-bar-image.js
// mac 顶栏「整条状态项」合成图：把猫图标 + SF Symbol 指标图标 + 数值拼成一张模板图，
// 交给 tray.setImage()，用来对齐 mac 原生版的 NSAttributedString + SF Symbol 附件效果。
//
// 为什么非要自己拼图（而不是像 Swift 那样「图标 + 文字」）：
// - Electron 的 tray.setTitle() 只收纯字符串，没有富文本/NSTextAttachment 能力，图片塞不进标题；
// - nativeImage.createFromNamedImage() 只认 NSComputer 这类旧具名图，实测拿不到 SF Symbol（返回空图）；
//   所以图标只能由 tools/dump-menu-icons.swift 用同一套 AppKit 规格离线导成 PNG 瓦片。
// - 结论：图标和数字都只能作为像素进同一张图，整条状态项（含猫）由这里合成。
//
// 瓦片规格（tools/dump-menu-icons.swift 的产物，落 SharedAssets/menu-icons，assets/ 下软链引用）：
// - 每张瓦片高 = 菜单栏可视高 22pt，宽 = 该符号框宽 / 该字符 advance，基线已内建在瓦片里；
//   于是拼接只需从左到右依次 blit alpha，不用做任何文字基线运算。
// - 模板图只看 alpha，所以瓦片统一「rgb 全黑 + alpha 形状」，深浅色菜单栏由系统反色，
//   与 Swift 侧 img.isTemplate = true 走同一条渲染路径。
//
// Retina：实测 nativeImage 会忽略 PNG 的 pHYs（44px@144dpi 仍报 44pt），
// 唯一能把「同一张图的两倍像素」交给系统的方式是 @2x 同名兄弟文件约定，
// 因此合成后落盘 menubar-metrics.png(1x) + menubar-metrics@2x.png(2x) 再 createFromPath 读回
// （写进 userData，值没变就不重写，一秒最多一次 KB 级 IO）。
'use strict';

const fs = require('fs');
const path = require('path');

// 瓦片目录：assets/menu-icons → 软链到仓库根 SharedAssets/menu-icons（与 mac 原生版同源规格）
const TILE_DIR = path.join(__dirname, '..', '..', '..', 'assets', 'menu-icons');
// Swift 侧 btn.image 就是 22×22，合成图里猫也占 22pt 宽
const CAT_SIZE_PT = 22;
// 猫图与第一个指标之间的留白：Swift 由 NSStatusBarButton 自动排 image+attributedTitle，
// 间距不受我们控制，这里取肉眼接近的值（改这里即可整体对齐）
const CAT_GAP_PT = 3;
// 指标之间的间隔瓦片键（Swift 用「一个空格」连接，空格 advance 也来自同一套系统字体）
const SPACE_KEY = 'g-space';
// 数字（含 % K / 空格）整体下沉的点数：瓦片里的基线是按「行盒在 22pt 内垂直居中」算的
// （(22 - (ascent+descent))/2 + ascent = 15.54）。实测系统菜单栏文字的基线比它低 3pt
// （外接屏截图同一条菜单栏上对比：我们数字墨迹底边 y=29，系统时间文字底边 y=31）。
// 注意别拿 NSButtonCell.titleRect 当锚：它给的是上 2 / 下 5 的不对称边距（基线 14.47），
// 那是普通按钮的排版，状态项按钮不走这条路，照它改会越改越偏。
const GLYPH_DY_PT = 4;
// SF Symbol 图标单独的下沉量，与数字分开调：
// Swift 侧把 symbol 交给 NSTextAttachment，由 attachment cell 按原图尺寸在 bounds 内居中；
// 我们导瓦片时是 draw(in: 14×13 框) 拉伸填满，两种填法在垂直位置上并不完全等价，
// 所以图标与数字会各自偏一点（实机反馈：数字偏上、图标偏下），这里给两个独立旋钮。
const SYMBOL_DY_PT = 2;
// 落盘文件名不带 @2x 后缀时 Electron 才会把它当独立图读；合成结果则要吃的就是这个约定
const OUT_BASE = 'menubar-metrics.png';
const OUT_2X = 'menubar-metrics@2x.png';

const CHAR_KEYS = { '%': 'g-pct', K: 'g-K', '/': 'g-slash', ' ': SPACE_KEY };

/** 单字符 → 瓦片键（数字走 g-<digit>，其余查表；未知字符没有瓦片，调用方回落 Unicode 标题） */
function glyphKey(ch) {
  if (CHAR_KEYS[ch]) return CHAR_KEYS[ch];
  if (ch >= '0' && ch <= '9') return `g-${ch}`;
  return null;
}

/**
 * 纯函数：按 manifest 把 parts 排成「瓦片序列 + 总宽」（点坐标，不含 cat，cat 由调用方给起点）。
 * 任何需要的瓦片不在 manifest 里（素材没生成 / 出现没预料到的字符）都返回 null，交给上层回落。
 * @param {Array<{metric: string, text: string}>} parts
 * @param {{stripHeight: number, tiles: Object<string, {w: number}>}} manifest
 */
function layoutStrip(parts, manifest, opts = {}) {
  if (!manifest || !manifest.tiles || !Number.isFinite(manifest.stripHeight)) return null;
  const tilesHeight = manifest.stripHeight;
  const gapCat = opts.catGap === undefined ? CAT_GAP_PT : opts.catGap;
  const withCat = opts.withCat !== false;
  const spaceW = manifest.tiles[SPACE_KEY] ? manifest.tiles[SPACE_KEY].w : 0;
  const tiles = [];
  let x = 0;
  const dy = Number.isFinite(opts.glyphDy) ? opts.glyphDy : GLYPH_DY_PT;
  const sdy = Number.isFinite(opts.symbolDy) ? opts.symbolDy : SYMBOL_DY_PT;
  if (withCat) {
    // 猫是 22×22 占满整高的图，没有基线概念，不下沉
    tiles.push({ key: '@cat', x, w: CAT_SIZE_PT, dy: 0 });
    x += CAT_SIZE_PT + gapCat;
  }
  for (let i = 0; i < parts.length; i += 1) {
    const p = parts[i];
    if (i > 0 && spaceW) {
      tiles.push({ key: SPACE_KEY, x, w: spaceW, dy });
      x += spaceW;
    }
    const iconTile = manifest.tiles[p.metric];
    if (!iconTile) return null; // 该指标没有图标瓦片
    tiles.push({ key: p.metric, x, w: iconTile.w, dy: sdy });
    x += iconTile.w;
    for (const ch of String(p.text)) {
      const key = glyphKey(ch);
      const tile = key && manifest.tiles[key];
      if (!tile) return null; // 缺字形瓦片：整条不合成，回落到 Unicode 文字标题
      tiles.push({ key, x, w: tile.w, dy });
      x += tile.w;
    }
  }
  return { tiles, width: x, height: tilesHeight };
}

/**
 * 纯函数：把 src 瓦片的 alpha 以「over」叠进 dst RGBA 缓冲的 (dx,dy)。
 * 瓦片与猫都只有 alpha 有意义（rgb 全黑），所以 RGB 一律写 0，只合成 alpha 通道。
 * 越界自动裁剪（数值位数变化会让总宽变化，逐张瓦片按画布宽裁掉尾巴而不是崩）。
 */
function blitAlpha(dst, dstW, dstH, src, srcW, srcH, dx, dy) {
  for (let y = 0; y < srcH; y += 1) {
    const ty = dy + y;
    if (ty < 0 || ty >= dstH) continue;
    for (let x = 0; x < srcW; x += 1) {
      const tx = dx + x;
      if (tx < 0 || tx >= dstW) continue;
      const si = ((y * srcW) + x) * 4;
      const sa = src[si + 3];
      if (!sa) continue;
      const di = ((ty * dstW) + tx) * 4;
      const da = dst[di + 3];
      dst[di] = 0;
      dst[di + 1] = 0;
      dst[di + 2] = 0;
      dst[di + 3] = sa + Math.round((da * (255 - sa)) / 255);
    }
  }
}

/**
 * 纯函数：把「亮度即形状」的 RGBA 图转成「alpha 即形状」的模板图瓦片（RGB 归零）。
 * alpha_out = alpha_in × luminance/255，与 tools/dump-menu-icons.swift 导出瓦片时的归一化一致。
 */
function bakeLuminanceToAlpha(rgba) {
  const out = Buffer.alloc(rgba.length, 0);
  for (let i = 0; i < rgba.length; i += 4) {
    const lum = Math.round(0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2]);
    out[i + 3] = Math.round((rgba[i + 3] * lum) / 255);
  }
  return out;
}

/** 合成一条 scale 倍分辨率的画布（layout 用点坐标，瓦片位图由调用方按 scale 选好的 1x/2x 版本） */
function composeScale(layout, bitmaps, scale) {
  const width = layout.width * scale;
  const height = layout.height * scale;
  const buf = Buffer.alloc(width * height * 4, 0);
  for (const t of layout.tiles) {
    const bm = bitmaps[t.key];
    if (!bm) return null;
    blitAlpha(buf, width, height, bm.data, bm.width, bm.height, t.x * scale, Math.round((t.dy || 0) * scale));
  }
  return { buf, width, height };
}

/**
 * 顶栏合成图生成器。
 * @param {object} deps
 * @param {object} [deps.nativeImage]        electron 的 nativeImage（测试注入假实现）
 * @param {string} [deps.tileDir]            瓦片目录
 * @param {string} [deps.outDir]             合成结果落盘目录（userData）
 * @param {string} [deps.catPath]            猫图标路径（SharedAssets/MenuBarIcon.png）
 * @param {(msg: string) => void} [deps.warn]
 */
class MetricBarImage {
  constructor(deps = {}) {
    const electron = deps.nativeImage ? { nativeImage: deps.nativeImage } : require('electron');
    this.ni = deps.nativeImage || electron.nativeImage;
    this.tileDir = deps.tileDir || TILE_DIR;
    this.outDir = deps.outDir || path.join(electron.app.getPath('userData'), 'menubar');
    this.catPath = deps.catPath || path.join(__dirname, '..', '..', '..', 'assets', 'MenuBarIcon.png');
    this.warn = deps.warn || ((msg) => console.warn('[metric-bar-image]', msg));
    this.manifest = null;
    this.bitmaps = null; // key -> {data, width, height}（含 1x/2x 两套：key@1 / key@2）
    this.lastBuf = null;
    this.lastImage = null;
  }

  /** 懒加载 manifest + 全部瓦片位图；缺文件/缺 JSON 时返回 false（整条链路回落） */
  load() {
    if (this.bitmaps) return true;
    try {
      this.manifest = JSON.parse(fs.readFileSync(path.join(this.tileDir, 'manifest.json'), 'utf8'));
    } catch (e) {
      this.warn(`读不到 manifest.json（先跑 xcrun swift tools/dump-menu-icons.swift）：${e.message}`);
      return false;
    }
    const bitmaps = {};
    const keys = Object.keys(this.manifest.tiles || {});
    for (const key of keys) {
      for (const scale of [1, 2]) {
        const p = path.join(this.tileDir, `${key}.${scale}x.png`);
        const img = this.ni.createFromPath(p);
        if (!img || img.isEmpty()) {
          this.warn(`缺瓦片 ${key}.${scale}x.png，顶栏回落到 Unicode 文字图标`);
          return false;
        }
        const size = img.getSize();
        if (!size.width || size.width * size.height * 4 !== img.getBitmap().length) {
          this.warn(`瓦片 ${key}.${scale}x.png 尺寸异常 ${size.width}x${size.height}`);
          return false;
        }
        // 高必须正好是整条菜单栏高（基线已内建在瓦片里），否则拼出来会上下错位
        if (size.height !== this.manifest.stripHeight * scale) {
          this.warn(`瓦片 ${key}.${scale}x.png 高 ${size.height} 与 stripHeight ${this.manifest.stripHeight} 不符`);
          return false;
        }
        bitmaps[`${key}@${scale}`] = { data: img.getBitmap(), width: size.width, height: size.height };
      }
    }
    // 猫图标：现有共享素材缩到 22pt（2x 时缩 44px）。
    // 关键：MenuBarIcon.png 的 alpha 全是 255，形状完全靠「暗底 + 亮墨」的亮度表达
    //（系统按亮度生成模板图 mask 才正常）。而合成器只认 alpha，直接搬过去会把整个
    // 22×22 方框都当成墨 → 顶栏左边变成实心黑块。所以这里先把亮度烘进 alpha。
    for (const scale of [1, 2]) {
      const cat = this.ni.createFromPath(this.catPath).resize({ width: CAT_SIZE_PT * scale, height: CAT_SIZE_PT * scale });
      const size = cat.getSize();
      bitmaps[`@cat@${scale}`] = { data: bakeLuminanceToAlpha(cat.getBitmap()), width: size.width, height: size.height };
    }
    this.bitmaps = bitmaps;
    try {
      fs.mkdirSync(this.outDir, { recursive: true });
    } catch (e) {
      this.warn(`建不出 ${this.outDir}：${e.message}`);
      return false;
    }
    return true;
  }

  /** 取某个 scale 的瓦片位图，顺带校验点宽与 manifest 一致（防止素材与 manifest 不同步） */
  _bitmapAt(key, scale, manifestW) {
    const bm = this.bitmaps[`${key}@${scale}`];
    if (!bm) return null;
    if (bm.width !== manifestW * scale) return null;
    return bm;
  }

  /**
   * 生成整条状态项图。
   * @param {Array<{metric: string, text: string}>} parts 顶栏指标（computeTrayParts 的产物）
   * @returns {object|null} nativeImage（模板图）；null 表示不该由合成图接管（无指标 / 素材缺失 / 缺字形）
   */
  imageFor(parts) {
    if (!parts || !parts.length) return null;
    if (!this.load()) return null;
    const layout = layoutStrip(parts, this.manifest);
    if (!layout) return null;
    // 每步合成前校验瓦片齐备且宽度和 manifest 对得上
    const pairs = {};
    for (const t of layout.tiles) {
      const one = this._bitmapAt(t.key, 1, t.w);
      const two = this._bitmapAt(t.key, 2, t.w);
      if (!one || !two) {
        this.warn(`瓦片 ${t.key} 与 manifest 尺寸不一致（需重导素材）`);
        return null;
      }
      pairs[t.key] = { one, two };
    }
    const canvases = {};
    for (const scale of [1, 2]) {
      const scaled = {};
      for (const t of layout.tiles) scaled[t.key] = scale === 1 ? pairs[t.key].one : pairs[t.key].two;
      const c = composeScale(layout, scaled, scale);
      if (!c) return null;
      canvases[scale] = c;
    }
    // 数值没变就不重编码重落盘（每秒一次的调用里省下绝大部分 IO 与 PNG 压缩）
    if (this.lastBuf && this.lastBuf.equals(canvases[1].buf)) return this.lastImage;
    try {
      const p1 = path.join(this.outDir, OUT_BASE);
      const p2 = path.join(this.outDir, OUT_2X);
      fs.writeFileSync(p2, this.ni.createFromBitmap(canvases[2].buf, { width: canvases[2].width, height: canvases[2].height }).toPNG());
      const img1x = this.ni.createFromBitmap(canvases[1].buf, { width: canvases[1].width, height: canvases[1].height });
      fs.writeFileSync(p1, img1x.toPNG());
      // 读回 1x 路径：Electron 会连 @2x 兄弟一起装进图里（createFromPath 是唯一认 @2x 约定的入口）
      const composed = this.ni.createFromPath(p1);
      composed.setTemplateImage(true);
      this.lastBuf = canvases[1].buf;
      this.lastImage = composed;
      return composed;
    } catch (e) {
      this.warn(`合成落盘失败：${e.message}`);
      return null;
    }
  }
}

module.exports = {
  MetricBarImage, layoutStrip, blitAlpha, composeScale, glyphKey, bakeLuminanceToAlpha,
  CAT_SIZE_PT, CAT_GAP_PT, GLYPH_DY_PT, SYMBOL_DY_PT, SPACE_KEY, TILE_DIR,
};
