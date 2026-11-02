// src/main/custom-sprite-store.js
// 自定义宠物形象图存储：把用户上传的小猫图落到 userData/CustomSprites，
// 按状态命名 local-<state>.<ext>，与 mac 版 CustomSpriteStore 的本地上传布局对齐。
// 关键：userData 目录不会被 App 自动更新覆盖（更新只替换安装包内的 assets/Sprites 默认帧），
// 所以自定义形象上传后能跨版本保留。
// 与 dialog / IPC 解耦，纯文件操作便于单测（tests 里 mock app.getPath）。
'use strict';

const fs = require('fs');
const path = require('path');
const { app } = require('electron');
const { PET_STATES, isValidPetState } = require('./settings-service');

// 允许的图片扩展名（与设置面板文件选择器 filters 保持一致）
const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']);
// 单图上限，避免误选超大原图把 userData 撑爆
const MAX_BYTES = 8 * 1024 * 1024;

function spriteDir() {
  return path.join(app.getPath('userData'), 'CustomSprites');
}

function ensureDir() {
  const dir = spriteDir();
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

/** 找某状态当前已上传的文件（local-<state>.<ext>），没有则 null */
function findLocalFile(dir, state) {
  const prefix = `local-${state}.`;
  try {
    for (const name of fs.readdirSync(dir)) {
      if (name.startsWith(prefix)) return path.join(dir, name);
    }
  } catch (e) {
    // 目录还没建过 → 视为无自定义图
  }
  return null;
}

/**
 * 安装一张本地图片作为某状态的自定义形象：校验 → 清旧图 → 拷贝进 userData。
 * @param {string} state 形象 id（focus / idel / sleep / pet）
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
  const old = findLocalFile(dir, state);
  if (old) {
    try {
      fs.unlinkSync(old);
    } catch (e) {
      // 旧图删不掉不阻断，新图会另用扩展名落盘；下面拷贝前再兜一次
    }
  }
  const dest = path.join(dir, `local-${state}${ext}`);
  try {
    fs.copyFileSync(srcPath, dest);
  } catch (e) {
    return { ok: false, error: `保存失败：${e.message}` };
  }
  return { ok: true, state, file: dest };
}

/**
 * 清除某状态的自定义形象（回到内置帧动画）。文件不存在也视为成功。
 * @param {string} state
 */
function clearLocalImage(state) {
  if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
  const file = findLocalFile(spriteDir(), state);
  if (file) {
    try {
      fs.unlinkSync(file);
    } catch (e) {
      return { ok: false, error: `删除失败：${e.message}` };
    }
  }
  return { ok: true, state };
}

/** 各状态当前自定义图文件：{ state: 绝对路径 | null } */
function snapshotFileMap() {
  const dir = spriteDir();
  const map = {};
  for (const s of PET_STATES) map[s.id] = findLocalFile(dir, s.id);
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
  MAX_BYTES,
};
