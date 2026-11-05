// src/main/custom-sprite-store.js
// 自定义宠物形象图存储：与 mac 版 Swift CustomSpriteStore 共用同一目录与同一落盘布局，
// 保证「升级/换壳不影响用户已设置的图片」，且两端设置的图互通。
// macOS 目录：~/Library/Application Support/DesktopPetForMacApp/CustomSprites（与 mac 版逐字节对齐）；
// Windows 无 mac 版，沿用 userData/CustomSprites。
// 布局契约（对齐 Swift 版，文件内容均为原始图片字节）：
//   local-<state>.img      本地直传图（优先级最高），配套 local-selections.json 记 {state: "1"}
//   cloud-<id>.img         AI 生成图共享缓存，配套 cloud-selections.json 记 {state: id}；
//                          空串 id = 显式恢复默认（会挡住 legacy 图透出）
//   cloud-states.json      图片 ID → 生成时所属状态（选中清单只记「当前用哪张」，归属要单独存）
//   sprite-failures.json   各状态最近一次生成失败记录（留服务端任务 ID 以便重试）
//   current.png / <state>.png  更早版本的历史上传，仅在清单没记该状态时兜底
// 状态 id 两端一致：focus / idel / sleep / pet / hide。
// 与 dialog / IPC 解耦，纯文件操作便于单测（tests 里 mock electron app.getPath）。
'use strict';

const fs = require('fs');
const path = require('path');
const { app } = require('electron');
const { allPetStateIds, isValidPetState } = require('./settings-service');
const { isDecodableImage, formatSize } = require('./image-meta');

// 允许的图片扩展名（与设置面板文件选择器 filters 保持一致，校验的是用户选的源文件）
const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']);
// 单图上限，与 mac 版 directUpload / upload 的 10 MB 口径一致（面板描述文案也写这个数）
const MAX_BYTES = 10 * 1024 * 1024;
// 落盘统一用 .img（内容仍是原格式字节），与 mac 版命名一致，跨端互相可读
const LOCAL_IMG_EXT = '.img';

const LOCAL_MANIFEST = 'local-selections.json';
const CLOUD_MANIFEST = 'cloud-selections.json';
const CLOUD_STATES_MANIFEST = 'cloud-states.json';
const FAILURES_MANIFEST = 'sprite-failures.json';

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
  if (stat.size > MAX_BYTES) return { ok: false, error: '图片过大，不得超过 10 MB' };
  const ext = path.extname(srcPath).toLowerCase();
  if (!IMAGE_EXTS.has(ext)) return { ok: false, error: '仅支持 PNG / JPG / GIF / WebP / BMP 图片' };
  // 对齐 mac 版 installLocalImage：解不开（扩展名对但内容不是图 / 尺寸超上限）不落盘，
  // 否则宠物窗拿到裂图只会一直空着。
  let buf;
  try {
    buf = fs.readFileSync(srcPath);
  } catch (e) {
    return { ok: false, error: `读取图片失败：${e.message}` };
  }
  if (!isDecodableImage(buf, MAX_BYTES)) return { ok: false, error: '图片格式无法识别或尺寸过大' };

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
    fs.writeFileSync(dest, buf);
    const manifest = localSelections(dir);
    manifest[state] = '1';
    writeJson(path.join(dir, LOCAL_MANIFEST), manifest);
    clearFailureFor(dir, state);
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
    return { ok: false, error: `更新清单失败：${e.message}` };
  }
  const file = findLocalFile(dir, state);
  if (file) {
    try {
      fs.unlinkSync(file);
    } catch (e) {
      return { ok: false, error: `删除失败：${e.message}` };
    }
  }
  clearFailureFor(dir, state);
  return { ok: true, state };
}

/** 各状态当前生效的自定义图文件：{ state: 绝对路径 | null }（含躲藏态，面板不展示但可上传） */
function snapshotFileMap() {
  const map = {};
  for (const id of allPetStateIds()) map[id] = effectiveFileFor(id);
  return map;
}

// ── 云端（AI 生成）图：落盘 / 缓存 / 状态归属 ────────────────

function cloudFileName(id) {
  return `cloud-${id}${LOCAL_IMG_EXT}`;
}

function localFileName(state) {
  return `local-${state}${LOCAL_IMG_EXT}`;
}

// 图片 ID → 生成时所属状态。cloud-selections 只记「当前用哪张」，
// 换图 / 删除后归属就丢了，所以单独存一份，历史图片才能长期按状态分类。
function cloudStatesMap(dir) {
  return readJson(path.join(dir || spriteDir(), CLOUD_STATES_MANIFEST));
}

/** 只记首次归属：同一张图后来被应用到别的状态时，不改写它的「生成状态」 */
function recordCloudStates(pairs, dir) {
  const root = dir || ensureDir();
  const list = (Array.isArray(pairs) ? pairs : []).filter((p) => p && validID(p.id) && isValidPetState(p.state));
  if (!list.length) return false;
  const states = cloudStatesMap(root);
  let changed = false;
  for (const pair of list) {
    if (states[pair.id] !== undefined) continue;
    states[pair.id] = pair.state;
    changed = true;
  }
  if (changed) writeJson(path.join(root, CLOUD_STATES_MANIFEST), states);
  return changed;
}

function forgetCloudState(id, dir) {
  const root = dir || spriteDir();
  const states = cloudStatesMap(root);
  if (states[id] === undefined) return;
  delete states[id];
  writeJson(path.join(root, CLOUD_STATES_MANIFEST), states);
}

/**
 * 用服务端记录（每张图自带生成状态）补全本机缺失的归属，已有归属不被覆盖；
 * 只补本机真实存在的图片，避免把纯云端记录写进本机清单。
 * @param {Record<string,string>} records 图片 ID → 状态 id
 * @returns {boolean} 是否写入了新归属（界面据此决定要不要刷新列表）
 */
function mergeCloudStates(records) {
  const root = ensureDir();
  const pairs = [];
  for (const [id, state] of Object.entries(records || {})) {
    if (!isValidPetState(state)) continue;
    if (!fs.existsSync(path.join(root, cloudFileName(id)))) continue;
    pairs.push({ id, state });
  }
  const before = JSON.stringify(cloudStatesMap(root));
  recordCloudStates(pairs, root);
  return JSON.stringify(cloudStatesMap(root)) !== before;
}

/**
 * 批量落盘云端图并提交选中清单（对齐 mac 版 installCloudImages）：
 * 先把不可变的图片文件写好，再一次原子提交 cloud-selections；
 * 未知状态 id（如老服务端残留的 warn）跳过而不是报错；空串 id = 显式恢复默认。
 * @param {{selections: Record<string,string>, images: Record<string, Buffer>}} params
 */
function installCloudImages({ selections, images }) {
  const root = ensureDir();
  const manifestPath = path.join(root, CLOUD_MANIFEST);
  const merged = fs.existsSync(manifestPath) ? cloudSelections(root) : {};
  const known = {};
  for (const [state, id] of Object.entries(selections || {})) {
    if (!isValidPetState(state)) continue;
    const value = String(id == null ? '' : id);
    if (value && !validID(value)) return { ok: false, error: '图片标识不合法' };
    if (value) {
      const data = (images || {})[value];
      if (!isDecodableImage(data, MAX_BYTES)) return { ok: false, error: '图片内容无法识别' };
    }
    known[state] = value;
  }
  try {
    for (const [id, data] of Object.entries(images || {})) {
      if (!Object.values(known).includes(id)) continue;
      fs.writeFileSync(path.join(root, cloudFileName(id)), data);
    }
    Object.assign(merged, known);
    writeJson(manifestPath, merged);
  } catch (e) {
    return { ok: false, error: `保存失败：${e.message}` };
  }
  // 只有被单一状态引用的图才算「某状态生成」；被多状态共享的老图本就无状态归属，
  // 写成第一个状态会归类错误。
  const owners = {};
  const shared = new Set();
  for (const [state, id] of Object.entries(known)) {
    if (!id) continue;
    if (owners[id]) shared.add(id);
    else owners[id] = state;
  }
  recordCloudStates(
    Object.entries(owners)
      .filter(([id]) => !shared.has(id))
      .map(([id, state]) => ({ id, state })),
    root,
  );
  return { ok: true, selections: known };
}

/**
 * 落盘一张云端图并设为某状态选中图（同时清掉该状态的本机直传遮挡）。
 * @param {string} id 服务端图片 ID
 * @param {Buffer} data 图片字节
 * @param {string} state 形象 id
 */
function installCloudImage(id, data, state) {
  if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
  const res = installCloudImages({ selections: { [state]: id }, images: { [id]: data } });
  if (!res.ok) return res;
  const root = spriteDir();
  // 直传图优先级高于云端图：不清掉它，刚应用的 AI 图永远透不出来
  try {
    const local = localSelections(root);
    if (local[state] !== undefined) {
      delete local[state];
      writeJson(path.join(root, LOCAL_MANIFEST), local);
    }
    const old = findLocalFile(root, state);
    if (old) fs.unlinkSync(old);
  } catch (e) {
    // 清直传图失败不阻断：云端图已落盘，下次上传直传图仍可覆盖
  }
  clearFailureFor(root, state);
  return { ok: true, id, state };
}

/** 预览或应用某张云端图后落盘：重开历史图片直接读本地，免一次远程取图 */
function cacheCloudImage(id, data) {
  if (!validID(id) || !Buffer.isBuffer(data) || !data.length) return false;
  const root = ensureDir();
  const file = path.join(root, cloudFileName(id));
  if (fs.existsSync(file)) return true;
  try {
    fs.writeFileSync(file, data);
    return true;
  } catch (e) {
    console.warn(`[custom-sprite] 缓存云端图片失败: ${e.message}`);
    return false;
  }
}

/** 读本机已缓存的云端图；命中则预览/应用都不走网络 */
function cachedCloudImage(id) {
  if (!validID(id)) return null;
  const file = path.join(spriteDir(), cloudFileName(id));
  try {
    return fs.existsSync(file) ? fs.readFileSync(file) : null;
  } catch (e) {
    return null;
  }
}

// ── 本机图片历史（数据源完全在本机，服务端只负责生成与存储）──────

/** 唯一标识：云端图 cloud:<图片ID>，直接上传图 local:<状态> */
function cloudKey(id) {
  return `cloud:${id}`;
}

function directKey(state) {
  return `local:${state}`;
}

function cloudIDFromKey(key) {
  const s = String(key || '');
  if (!s.startsWith('cloud:')) return null;
  const id = s.slice('cloud:'.length);
  return validID(id) ? id : null;
}

function directStateFromKey(key) {
  const s = String(key || '');
  if (!s.startsWith('local:')) return null;
  const state = s.slice('local:'.length);
  return isValidPetState(state) ? state : null;
}

/** 某状态是否存着本地直传图（面板用它把按钮变成「● 直接上传」） */
function hasLocalImage(state) {
  const root = spriteDir();
  if (!isValidPetState(state)) return false;
  if (localSelections(root)[state] === undefined) return false;
  return fs.existsSync(path.join(root, localFileName(state)));
}

/** 某状态当前是否有非内置图生效（直传 / 云端 / legacy 任一） */
function hasCustomImage(state) {
  return Boolean(effectiveFileFor(state));
}

/**
 * 枚举本机全部图片：AI 生成下载的 cloud-<id>.img + 直接上传的 local-<state>.img。
 * 返项按修改时间倒序，每项：
 *   { key, isDirect, file, modifiedMs, size, sizeText, boundState, selectedStates }
 * boundState：直传图固定绑定状态；AI 图取「生成状态」，老图未记录时按当前唯一选中回填。
 */
function localImages() {
  const root = spriteDir();
  let names = [];
  try {
    names = fs.readdirSync(root);
  } catch (e) {
    return [];
  }
  const cloud = cloudSelections(root);
  const local = localSelections(root);
  const ownership = cloudStatesMap(root);
  const backfilled = [];
  const items = [];
  for (const name of names) {
    if (!name.endsWith(LOCAL_IMG_EXT)) continue;
    const file = path.join(root, name);
    let stat;
    try {
      if (!fs.statSync(file).isFile()) continue;
      stat = fs.statSync(file);
    } catch (e) {
      continue;
    }
    const base = name.slice(0, -LOCAL_IMG_EXT.length);
    if (name.startsWith('cloud-')) {
      if (!validID(base)) continue;
      const selectedStates = allPetStateIds().filter((s) => cloud[s] === base);
      let boundState = ownership[base];
      if (!isValidPetState(boundState)) boundState = null;
      // 老版本没记生成状态：唯一被一个状态选中才是可靠线索，回填一次后永久归类
      if (!boundState && selectedStates.length === 1) {
        boundState = selectedStates[0];
        backfilled.push({ id: base, state: boundState });
      }
      items.push({
        key: cloudKey(base),
        isDirect: false,
        id: base,
        file,
        modifiedMs: stat.mtimeMs,
        size: stat.size,
        sizeText: formatSize(stat.size),
        boundState,
        selectedStates,
      });
    } else if (name.startsWith('local-')) {
      const state = base;
      if (!isValidPetState(state)) continue;
      items.push({
        key: directKey(state),
        isDirect: true,
        id: '',
        file,
        modifiedMs: stat.mtimeMs,
        size: stat.size,
        sizeText: formatSize(stat.size),
        boundState: state,
        selectedStates: local[state] !== undefined ? [state] : [],
      });
    }
  }
  recordCloudStates(backfilled, root);
  return items.sort((a, b) => b.modifiedMs - a.modifiedMs);
}

/**
 * 用本机图片的周知标识切换某状态的选中图（纯本地，不请求服务端）。
 * 文件缺失时把该状态回退为内置默认图并报错（对齐 mac 版 selectLocalImage）。
 */
function selectLocalImage(key, state) {
  if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
  const root = ensureDir();
  const cloud = cloudSelections(root);
  const local = localSelections(root);
  const id = cloudIDFromKey(key);
  const bound = directStateFromKey(key);
  if (id) {
    const file = path.join(root, cloudFileName(id));
    if (!fs.existsSync(file)) {
      cloud[state] = '';
      commitSelections(root, cloud, local);
      return { ok: false, error: '本机图片文件已不存在，该状态已恢复默认图' };
    }
    cloud[state] = id;
    delete local[state];
    recordCloudStates([{ id, state }], root);
  } else if (bound) {
    if (bound !== state) {
      return { ok: false, error: `直接上传的图片只适用于该状态，不能应用到${state}` };
    }
    const file = path.join(root, localFileName(bound));
    if (!fs.existsSync(file)) {
      delete local[state];
      commitSelections(root, cloud, local);
      return { ok: false, error: '本机图片文件已不存在，该状态已恢复默认图' };
    }
    local[state] = '1';
    cloud[state] = '';
  } else {
    return { ok: false, error: '无法识别的图片标识' };
  }
  commitSelections(root, cloud, local);
  clearFailureFor(root, state);
  return { ok: true, key, state };
}

/**
 * 删除一张本机图片；若它正被某些状态选中，这些状态回退为内置默认图。
 * @param {string} key cloud:<id> 或 local:<state>
 */
function removeLocalImageByKey(key) {
  const root = ensureDir();
  const id = cloudIDFromKey(key);
  const state = directStateFromKey(key);
  if (id) {
    const cloud = cloudSelections(root);
    for (const [s, value] of Object.entries(cloud)) {
      if (value === id) cloud[s] = '';
    }
    commitSelections(root, cloud, localSelections(root));
    try {
      fs.unlinkSync(path.join(root, cloudFileName(id)));
    } catch (e) {
      // 文件已不在也视为删成（清单已先提交，不会再把这图透出来）
    }
    forgetCloudState(id, root);
    return { ok: true, key };
  }
  if (state) return clearLocalImage(state);
  return { ok: false, error: '无法识别的图片标识' };
}

/** 本机是否已表达过图片选择（清单文件存在即算）：首次用服务端记录恢复时不能覆盖它 */
function hasAnySelection() {
  const root = spriteDir();
  return (
    fs.existsSync(path.join(root, CLOUD_MANIFEST)) ||
    fs.existsSync(path.join(root, LOCAL_MANIFEST))
  );
}

// ── 生成失败记录：本机没图片文件即视为失败，留服务端任务 ID 以便重试 ──

function failures(dir) {
  return readJson(path.join(dir || spriteDir(), FAILURES_MANIFEST));
}

/** 记一次某状态的生成失败（serverID 可为空，空则无法重试只能重新生成） */
function recordFailure(state, serverID, message) {
  if (!isValidPetState(state)) return false;
  const root = ensureDir();
  const all = failures(root);
  all[state] = {
    serverID: serverID ? String(serverID) : '',
    message: String(message || '生成失败'),
    at: Date.now(),
  };
  try {
    writeJson(path.join(root, FAILURES_MANIFEST), all);
    return true;
  } catch (e) {
    return false;
  }
}

function clearFailureFor(dir, state) {
  const root = dir || spriteDir();
  const all = failures(root);
  if (all[state] === undefined) return false;
  delete all[state];
  try {
    writeJson(path.join(root, FAILURES_MANIFEST), all);
    return true;
  } catch (e) {
    return false;
  }
}

/** 清除某状态的失败记录（历史图片里的「清除记录」） */
function clearFailure(state) {
  if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
  clearFailureFor(ensureDir(), state);
  return { ok: true, state };
}

/** 两份选中清单一次提交（对齐 mac 版 commit：先建目录再写盘） */
function commitSelections(root, cloud, local) {
  fs.mkdirSync(root, { recursive: true });
  writeJson(path.join(root, CLOUD_MANIFEST), cloud);
  writeJson(path.join(root, LOCAL_MANIFEST), local);
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
  // 云端（AI 生成）图
  installCloudImage,
  installCloudImages,
  cacheCloudImage,
  cachedCloudImage,
  mergeCloudStates,
  cloudStatesMap,
  // 选中与可用性判定
  hasLocalImage,
  hasCustomImage,
  hasAnySelection,
  // 本机图片历史
  localImages,
  selectLocalImage,
  removeLocalImageByKey,
  cloudKey,
  directKey,
  cloudIDFromKey,
  directStateFromKey,
  // 生成失败记录
  failures,
  recordFailure,
  clearFailure,
};
