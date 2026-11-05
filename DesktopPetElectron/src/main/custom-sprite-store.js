// src/main/custom-sprite-store.js
// 自定义宠物形象图存储：与 mac 版 Swift CustomSpriteStore 共用同一目录与同一落盘布局，
// 保证「升级/换壳不影响用户已设置的图片」，且两端设置的图互通。
// macOS 目录：~/Library/Application Support/DesktopPetForMacApp/CustomSprites（与 mac 版逐字节对齐）；
// Windows 无 mac 版，沿用 userData/CustomSprites。
// 布局契约（对齐 Swift 版，文件内容均为原始图片字节）：
//   local-<state>.img      本地直传图（优先级最高），配套 local-selections.json 记 {state: "1"}
//   cloud-<id>.img         AI 生成图共享缓存，配套 cloud-selections.json 记 {state: id}；
//                          空串 id = 显式恢复默认（会挡住 legacy 图透出）
//   current.png / <state>.png  更早版本的历史上传，仅在清单没记该状态时兜底
// 状态 id 两端一致：focus / idel / sleep / pet / hide。
// 与 dialog / IPC 解耦，纯文件操作便于单测（tests 里 mock electron app.getPath）。
'use strict';

const fs = require('fs');
const path = require('path');
const { app } = require('electron');
const { allPetStateIds, isValidPetState } = require('./settings-service');

// 允许的图片扩展名（与设置面板文件选择器 filters 保持一致，校验的是用户选的源文件）
const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']);
// 单图上限，避免误选超大原图把存储目录撑爆
const MAX_BYTES = 8 * 1024 * 1024;
// 落盘统一用 .img（内容仍是原格式字节），与 mac 版命名一致，跨端互相可读
const LOCAL_IMG_EXT = '.img';

const LOCAL_MANIFEST = 'local-selections.json';
const CLOUD_MANIFEST = 'cloud-selections.json';

// 旧版 Electron 的存放位置（userData/CustomSprites），mac 版首次启用共用目录时从这里迁移
function legacyElectronDir() {
  return path.join(app.getPath('userData'), 'CustomSprites');
}

function spriteDir() {
  if (process.platform === 'darwin') {
    // appData 在 mac 即 ~/Library/Application Support，与 Swift 版 applicationSupportDirectory 同源
    return path.join(app.getPath('appData'), 'DesktopPetForMacApp', 'CustomSprites');
  }
  return legacyElectronDir();
}

// ── 旧版 userData 布局一次性迁移（仅 macOS；Windows 下两处同路径，无需迁移动作）──
let migrated = false;
function ensureMigration() {
  if (migrated) return;
  migrated = true;
  if (process.platform !== 'darwin') return;
  const from = legacyElectronDir();
  const to = spriteDir();
  if (from === to || !fs.existsSync(from)) return;
  fs.mkdirSync(to, { recursive: true });
  let names = [];
  try {
    names = fs.readdirSync(from);
  } catch (e) {
    return;
  }
  for (const name of names) {
    const src = path.join(from, name);
    try {
      if (!fs.statSync(src).isFile()) continue;
      // 旧布局 local-<state>.<ext> → 共用布局 local-<state>.img + 清单登记
      const m = /^local-([a-z]+)\.([a-z0-9]+)$/i.exec(name);
      if (m && isValidPetState(m[1]) && m[2].toLowerCase() !== 'img') {
        fs.copyFileSync(src, path.join(to, `local-${m[1]}${LOCAL_IMG_EXT}`));
        const manifest = readJson(path.join(to, LOCAL_MANIFEST));
        manifest[m[1]] = '1';
        writeJson(path.join(to, LOCAL_MANIFEST), manifest);
        continue;
      }
      const dest = path.join(to, name);
      if (!fs.existsSync(dest)) fs.copyFileSync(src, dest);
    } catch (e) {
      // 单个文件迁移失败不阻断，读侧还有旧目录兜底
    }
  }
}

function ensureDir() {
  ensureMigration();
  const dir = spriteDir();
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// ── 清单读写（损坏/缺失一律视作空对象，绝不炸掉宠物显示）──
function readJson(file) {
  try {
    const obj = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (obj && typeof obj === 'object' && !Array.isArray(obj)) return obj;
  } catch (e) {
    // 无清单或解析失败
  }
  return {};
}

function writeJson(file, obj) {
  fs.writeFileSync(file, JSON.stringify(obj));
}

function localSelections(root) {
  return readJson(path.join(root, LOCAL_MANIFEST));
}

function cloudSelections(root) {
  return readJson(path.join(root, CLOUD_MANIFEST));
}

// 图片 ID 会拼进本机文件名，必须挡掉路径分隔符与前导点（对齐 Swift 版 validID）；
// 兼容两代服务端格式：纯 32 位十六进制，以及“可读名-8 位十六进制”（如 my_cat-1a2b3c4d）。
// 清单由 mac 版 App 或本模块写入，两端都可能带 ID，校验不能省。
function validID(id) {
  if (typeof id !== 'string' || id.length === 0 || id.length > 96) return false;
  if (id.startsWith('.')) return false;
  if (!/^[\p{L}\p{N}_-]+$/u.test(id)) return false;
  if (id.length === 32 && /^[0-9a-f]+$/.test(id)) return true;
  const dash = id.lastIndexOf('-');
  if (dash <= 0) return false;
  const suffix = id.slice(dash + 1);
  return suffix.length === 8 && /^[0-9a-f]{8}$/.test(suffix);
}

/** legacy 兜底：更早版本的历史上传（共享 current.png 优先，其次单状态 <state>.png） */
function legacyFileFor(root, state) {
  for (const name of ['current.png', `${state}.png`]) {
    const f = path.join(root, name);
    if (fs.existsSync(f)) return f;
  }
  return null;
}

/** 找某状态当前的本地直传文件：优先共用命名 local-<state>.img，兼容旧扩展名残留 */
function findLocalFile(dir, state) {
  const img = path.join(dir, `local-${state}${LOCAL_IMG_EXT}`);
  if (fs.existsSync(img)) return img;
  const prefix = `local-${state}.`;
  try {
    for (const name of fs.readdirSync(dir)) {
      if (name.startsWith(prefix) && !name.endsWith('.json')) return path.join(dir, name);
    }
  } catch (e) {
    // 目录还没建过 → 视为无自定义图
  }
  return null;
}

/**
 * 解析某状态当前生效的自定义图文件（完整复刻 mac 版 loadAnimation 优先级）：
 * local 直传（清单登记且文件在） > cloud 选中图（清单记 id，空串=显式默认，非法/缺失=无图）
 * > legacy 历史上传 > null（内置帧动画）。
 */
function effectiveFileFor(state) {
  ensureMigration();
  const root = spriteDir();
  if (!fs.existsSync(root)) return null;
  // 1. 本地直传优先级最高：清单里有登记且文件真实存在
  if (localSelections(root)[state] !== undefined) {
    const img = path.join(root, `local-${state}${LOCAL_IMG_EXT}`);
    if (fs.existsSync(img)) return img;
    // 文件缺失则继续往下走云端（对齐 mac 版：直传遮挡不成立时回退云端图）
  }
  // 2. 云端清单存在：记 id 用云端图；空串 = 显式恢复默认（必须挡住 legacy 透出）
  if (fs.existsSync(path.join(root, CLOUD_MANIFEST))) {
    const sel = cloudSelections(root);
    if (sel[state] !== undefined) {
      const id = sel[state];
      if (!id || !validID(id)) return null;
      const f = path.join(root, `cloud-${id}${LOCAL_IMG_EXT}`);
      return fs.existsSync(f) ? f : null;
    }
    return legacyFileFor(root, state);
  }
  // 3. 没有任何云端清单：读更早版本的历史上传
  return legacyFileFor(root, state);
}

/**
 * 安装一张本地图片作为某状态的自定义形象：校验 → 拷贝为 local-<state>.img → 清单登记。
 * 与 mac 版 installLocalImage 同布局，之后打开 mac 版 App 也能直接用上这张图。
 * @param {string} state 形象 id（focus / idel / sleep / pet / hide）
 * @param {string} srcPath 用户选中的图片绝对路径
 * @returns {{ok: true, state: string, file: string} | {ok: false, error: string}}
 */
function installLocalImage(state, srcPath) {
  if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
  let stat;
  try {
    stat = fs.statSync(srcPath);
  } catch (e) {
    return { ok: false, error: '图片文件不存在' };
  }
  if (!stat.isFile()) return { ok: false, error: '请选择图片文件' };
  if (stat.size > MAX_BYTES) return { ok: false, error: '图片过大（上限 8MB）' };
  const ext = path.extname(srcPath).toLowerCase();
  if (!IMAGE_EXTS.has(ext)) return { ok: false, error: '仅支持 PNG / JPG / GIF / WebP / BMP 图片' };

  const dir = ensureDir();
  // 清掉旧扩展名残留（更早 Electron 版本写的 local-<state>.<ext>），保持目录里只有一份
  const old = findLocalFile(dir, state);
  if (old && old !== path.join(dir, `local-${state}${LOCAL_IMG_EXT}`)) {
    try {
      fs.unlinkSync(old);
    } catch (e) {
      // 删旧图失败不阻断，新图按共用命名落盘后旧文件自然失效
    }
  }
  const dest = path.join(dir, `local-${state}${LOCAL_IMG_EXT}`);
  try {
    fs.copyFileSync(srcPath, dest);
    const manifest = localSelections(dir);
    manifest[state] = '1';
    writeJson(path.join(dir, LOCAL_MANIFEST), manifest);
  } catch (e) {
    return { ok: false, error: `保存失败：${e.message}` };
  }
  return { ok: true, state, file: dest };
}

/**
 * 清除某状态的自定义形象（回到内置帧动画）。语义对齐 mac 版 restoreDefault：
 * 删直传图与登记；若云端清单存在则把该状态写成空串（显式默认，挡住 legacy 透出）。
 * 文件不存在也视为成功。
 * @param {string} state
 */
function clearLocalImage(state) {
  if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
  const dir = ensureDir();
  try {
    // 对齐 mac 版 restoreDefault：无条件提交两份清单；云端清单里写空串 = 显式默认，
    // 既挡住 legacy 图透出，也让 mac 版识别到“本机已表达过选择”而不被服务端记录覆盖。
    const cloud = cloudSelections(dir);
    cloud[state] = '';
    writeJson(path.join(dir, CLOUD_MANIFEST), cloud);
    const local = localSelections(dir);
    delete local[state];
    writeJson(path.join(dir, LOCAL_MANIFEST), local);
  } catch (e) {
    return { ok: false, error: `更新清单失败：${e.message}` }
  }
  const file = findLocalFile(dir, state);
  if (file) {
    try {
      fs.unlinkSync(file);
    } catch (e) {
      return { ok: false, error: `删除失败：${e.message}` };
    }
  }
  return { ok: true, state };
}

/** 各状态当前生效的自定义图文件：{ state: 绝对路径 | null }（含躲藏态，面板不展示但可上传） */
function snapshotFileMap() {
  const map = {};
  for (const id of allPetStateIds()) map[id] = effectiveFileFor(id);
  return map;
}

/** 各状态是否已自定义（设置面板展示用）：{ state: boolean } */
function statusMap() {
  const files = snapshotFileMap();
  const out = {};
  for (const id of Object.keys(files)) out[id] = Boolean(files[id]);
  return out;
}

module.exports = {
  spriteDir,
  installLocalImage,
  clearLocalImage,
  snapshotFileMap,
  statusMap,
  validID,
  MAX_BYTES,
};
