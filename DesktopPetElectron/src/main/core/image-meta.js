// src/main/image-meta.js
// 图片字节头解析：直接读 PNG / JPEG / GIF 的文件头拿宽高与格式，不引第三方图像库。
// 两处用到：
//   · custom-sprite-store 落盘前验图（对齐 mac 版 decodeAnimation：解得开、尺寸不超上限才收）
//   · pet-image-service 上传前验图（对齐 mac 版 validatedImageFile：大小 + 格式 + 像素上限）
// 只做「能不能解、有多大」的判定，不做解码渲染，因此不认识扩展名、只认字节魔数。
'use strict';

const MAX_SIDE = 8192;              // 单边像素上限（对齐 mac 版 decodeAnimation 的 w/h <= 8192）
const MAX_PIXELS = 40_000_000;      // 总像素上限（对齐 mac 版 40_000_000）
const MAX_GIF_FRAMES = 120;         // GIF 帧数上限（对齐 mac 版 count <= 120）
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024; // 单图上传/直传上限（对齐 mac 版 10 MB）

/**
 * 读图片字节头拿 { type, width, height, frames }。
 * type: 'png' | 'jpeg' | 'gif'；解不出来返回 null（调用方按「不是有效图片」处理）。
 * @param {Buffer} buf
 */
function readImageInfo(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 16) return null;

  // PNG：89 50 4E 47 0D 0A 1A 0A，紧跟 IHDR（长度 4 + "IHDR" 4 之后是宽 4 + 高 4，大端）
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
    if (buf.toString('ascii', 12, 16) !== 'IHDR') return null;
    return {
      type: 'png',
      width: buf.readUInt32BE(16),
      height: buf.readUInt32BE(20),
      frames: 1,
    };
  }

  // GIF：'GIF87a' / 'GIF89a'，逻辑屏幕描述符里宽高手势小端；帧数按 0x21 2F（Image Descriptor）扫
  if (buf.toString('ascii', 0, 3) === 'GIF' && buf[3] === 0x38) {
    const width = buf.readUInt16LE(6);
    const height = buf.readUInt16LE(8);
    return { type: 'gif', width, height, frames: countGifFrames(buf) };
  }

  // JPEG：FF D8 开头，后面按段扫描到 SOF0~SOF15（跳过 C4/C8/CC）取高宽
  if (buf[0] === 0xff && buf[1] === 0xd8) {
    let offset = 2;
    while (offset + 9 < buf.length) {
      if (buf[offset] !== 0xff) { offset += 1; continue; }
      const marker = buf[offset + 1];
      // 无长度字段的标记：填充字节 / 独立标记（EOI/SOI 等）
      if (marker === 0xff || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd9)) {
        offset += 2;
        continue;
      }
      const size = buf.readUInt16BE(offset + 2);
      if (size < 2) return null;
      // SOFn（含渐进式 C2）里：精度 1 字节 + 高 2 + 宽 2
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        return {
          type: 'jpeg',
          height: buf.readUInt16BE(offset + 5),
          width: buf.readUInt16BE(offset + 7),
          frames: 1,
        };
      }
      offset += 2 + size;
    }
    return null;
  }

  return null;
}

/** 数 GIF 帧：Image Descriptor（0x21 0x2F … 0x00）出现次数，尾部残缺也不炸 */
function countGifFrames(buf) {
  let frames = 0;
  for (let i = 0; i + 4 < buf.length; i += 1) {
    if (buf[i] === 0x21 && buf[i + 1] === 0x2f && buf[i + 2] === 0x09) {
      frames += 1;
      // 跳到该帧的数据子块末尾，避免把像素数据里的 0x21 2F 当新帧头
      let p = i + 3 + 9; // 描述符固定 9 字节：跳过局部色表再扫子块
      const packed = buf[i + 12] || 0;
      if (packed & 0x80) p += 3 * (1 << ((packed & 0x07) + 1));
      if (buf[p] === 0x09) p += 2; // 延迟 + 透明色标志
      while (p < buf.length && buf[p] !== 0x00) p += buf[p] + 1;
      i = p;
    }
  }
  return Math.max(1, frames);
}

/** 只确认「像张图」的魔数：WebP / BMP / ICO 渲染进程显示得开，但本机解不了尺寸 */
function hasOtherImageMagic(buf) {
  if (buf[0] === 0x42 && buf[1] === 0x4d) return true; // BMP 'BM'
  if (buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') return true;
  return buf[0] === 0x00 && buf[1] === 0x00 && buf[2] === 0x01; // ICO
}

/**
 * 判断一段字节是不是一张「本机用得了」的图：格式认、尺寸不超上限。
 * 对齐 mac 版 decodeAnimation 的准入门槛（解不开就不落盘，免得宠物显示成裂图）。
 * PNG / JPEG / GIF 按 mac 同口径卡边长、总像素与 GIF 帧数；
 * WebP / BMP / ICO 只卡魔数与体积（不引第三方库解不了尺寸，交给渲染层按原生能力显示）。
 * @param {Buffer} buf
 * @param {number} [maxBytes] 体积上限（默认不限，落盘时按存储自己的上限另判）
 * @returns {boolean}
 */
function isDecodableImage(buf, maxBytes = 0) {
  if (!Buffer.isBuffer(buf) || buf.length < 16) return false;
  if (maxBytes && buf.length > maxBytes) return false;
  const info = readImageInfo(buf);
  if (!info) return hasOtherImageMagic(buf);
  if (info.width <= 0 || info.height <= 0) return false;
  if (info.width > MAX_SIDE || info.height > MAX_SIDE) return false;
  if (Number(info.width) * Number(info.height) > MAX_PIXELS) return false;
  if (info.type === 'gif' && info.frames > MAX_GIF_FRAMES) return false;
  return true;
}

/**
 * 上传前校验（对齐 mac 版 validatedImageFile）：大小 + 格式白名单 + 像素上限。
 * @param {Buffer} buf 图片字节
 * @param {{allowsGif?: boolean, maxBytes?: number}} [opts]
 * @returns {{ok: true, info: object} | {ok: false, error: string}}
 */
function validateUploadImage(buf, opts = {}) {
  const allowsGif = Boolean(opts.allowsGif);
  const maxBytes = opts.maxBytes || MAX_UPLOAD_BYTES;
  if (!Buffer.isBuffer(buf) || !buf.length) {
    return { ok: false, error: allowsGif ? '请选择有效的 PNG/JPEG/GIF 图片，像素不得超过 4000 万' : '请选择有效的 PNG/JPEG 图片，像素不得超过 4000 万' };
  }
  if (buf.length > maxBytes) return { ok: false, error: '图片不得超过 10 MB' };
  const info = readImageInfo(buf);
  if (!info || (info.type === 'gif' && !allowsGif)) {
    return { ok: false, error: allowsGif ? '请选择有效的 PNG/JPEG/GIF 图片，像素不得超过 4000 万' : '请选择有效的 PNG/JPEG 图片，像素不得超过 4000 万' };
  }
  if (info.width <= 0 || info.height <= 0 || Number(info.width) * Number(info.height) > MAX_PIXELS) {
    return { ok: false, error: allowsGif ? '请选择有效的 PNG/JPEG/GIF 图片，像素不得超过 4000 万' : '请选择有效的 PNG/JPEG 图片，像素不得超过 4000 万' };
  }
  return { ok: true, info };
}

/** 文件名清洗（对齐 mac 版：多部分表单的 filename 里不能带引号与换行） */
function sanitizeFileName(name) {
  return String(name || 'image')
    .replace(/"/g, '_')
    .replace(/\r/g, '_')
    .replace(/\n/g, '_');
}

/** 字节数 → 「1.2 MB」这类可读文案（历史图片列表用） */
function formatSize(bytes) {
  const n = Number(bytes) || 0;
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

module.exports = {
  readImageInfo,
  isDecodableImage,
  hasOtherImageMagic,
  validateUploadImage,
  sanitizeFileName,
  formatSize,
  MAX_SIDE,
  MAX_PIXELS,
  MAX_GIF_FRAMES,
  MAX_UPLOAD_BYTES,
};
