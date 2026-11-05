// src/main/pet-image-service.js
// 云端宠物形象图客户端（移植 mac 版 Services/PetImageService.swift）
// 与后端 /api/pet-images/<action> 交互：列库、上传（单状态 / all 逐状态生成）、重试生成、
// 选中某状态用哪张、取图片字节。
// 鉴权体是可注入的加密信封 {code, deviceId, id, state}（与 mac 版 credentials 同字段），
// 上传走 multipart：auth 部分放加密信封，image 部分放原始字节。
// 与 social 接口不同：这里业务失败会回 HTTP 400/403/429/503，msg 仍是服务端文案，
// 所以非 200 也要先试着解出 msg，解不出来才回落「服务器请求失败」。
// 只有服务端激活码能用（本地快捷码 456 不绑码，拿不到生成配额）。
'use strict';

const fs = require('fs');
const path = require('path');
const access = require('../core/access-service');
const config = require('../core/config-store');
const info = require('../core/app-info');
const { encryptedEnvelope } = require('../core/crypto-envelope');
const { validateUploadImage, sanitizeFileName } = require('../core/image-meta');
const { allPetStateIds, isValidPetState } = require('../settings/settings-service');

const TIMEOUT_MS = 60000;          // 单次请求超时（对齐 mac 版 URLRequest timeoutInterval 60s）
const POLL_MS = 3000;              // 生成进度轮询间隔（对齐 mac 版 Task.sleep 3s）
const POLL_ROUNDS_SINGLE = 200;    // 单张图等待轮数上限
const POLL_ROUNDS_BATCH = 400;     // 整批（5 张）等待轮数上限
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

/** 生成本机没拿到图时的统一文案（对齐 mac 版 waitForGeneration 超时提示） */
const TIMEOUT_NOTICE = '等待生成超时，任务可能仍在服务器运行，请稍后打开历史图片查看。';

/** 生成阶段 → 界面文案（对齐 mac 版 PetImageRecord.stageLabel） */
function stageLabel(status) {
  switch (String(status || '')) {
    case 'beautifying': return '正在提取并美化宠物…';
    case 'animating': return '正在生成宠物动画帧…';
    case 'encoding': return '正在合成 GIF…';
    case 'failed': return '生成失败';
    default: return '可使用';
  }
}

function isReady(status) {
  const s = String(status || '');
  return s === '' || s === 'ready';
}

function isGenerating(status) {
  return ['beautifying', 'animating', 'encoding'].includes(String(status || ''));
}

/** 服务端图片记录归一化：{id,name,state,createdAt,status,error,isReady,isGenerating,stageLabel} */
function normalizeRecord(raw) {
  const id = String((raw && raw.id) || '');
  if (!id) return null;
  const status = raw && raw.status != null ? String(raw.status) : '';
  return {
    id,
    name: String((raw && raw.name) || ''),
    state: raw && raw.state != null ? String(raw.state) : '',
    createdAt: String((raw && raw.createdAt) || ''),
    status,
    error: raw && raw.error != null ? String(raw.error) : '',
    isReady: isReady(status),
    isGenerating: isGenerating(status),
    stageLabel: stageLabel(status),
  };
}

/**
 * 图片库归一化，重点是 selections（状态 → 图片 ID）：
 * 服务端没记逐状态 currentIds、只有共享 currentId 的老协议，才把共享图铺到每个状态；
 * 逐状态时代里缺某状态 = 服务端从没记录过它，绝不能拿空 currentId 伪造成「恢复默认」，
 * 否则升级会抹掉用户该状态的选图。服务端真正的显式恢复默认会留空串，照常透传。
 */
function normalizeLibrary(raw) {
  const src = raw || {};
  const images = (Array.isArray(src.images) ? src.images : []).map(normalizeRecord).filter(Boolean);
  const currentId = String(src.currentId || '');
  const hasPerState = src.currentIds && typeof src.currentIds === 'object';
  const selections = {};
  if (hasPerState) {
    for (const state of allPetStateIds()) {
      if (src.currentIds[state] !== undefined) selections[state] = String(src.currentIds[state] || '');
    }
  } else if (currentId) {
    for (const state of allPetStateIds()) selections[state] = currentId;
  }
  return {
    currentId,
    currentIds: hasPerState ? src.currentIds : null,
    selections,
    images,
    selectionVersion: Number(src.selectionVersion) || 0,
    // 整码共享的生命周期生成配额（服务端 omitempty：没返回就是 0/未设）
    generationLimit: Number(src.generationLimit) || 0,
    generationRemaining: Number(src.generationRemaining) || 0,
  };
}

/** 文件名 → multipart 里的 filename（去掉引号与换行，与服务端解析兼容） */
function fileNameOf(filePath) {
  return sanitizeFileName(path.basename(filePath));
}

/**
 * 创建云端图片服务。
 * @param {object} [deps]
 * @param {Function} [deps.fetch] 可注入 fetch
 * @param {() => string} [deps.baseUrl] 后端地址（默认读 config 的 serverBaseURL）
 * @param {() => string} [deps.deviceId] 设备 ID（默认 app-info.resolveDeviceId）
 * @param {() => string} [deps.code] 服务端激活码（默认 access.serverActivationCode）
 * @param {(ms: number) => Promise<void>} [deps.sleep] 可注入等待（轮询用，单测）
 */
function createPetImageService(deps = {}) {
  const doFetch = deps.fetch || fetch;
  const deviceId = () => (deps.deviceId ? deps.deviceId() : info.resolveDeviceId());
  const codeOf = () => (deps.code ? deps.code() : access.serverActivationCode());
  const sleep = deps.sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  const urlOf = (action) => {
    const base = String(deps.baseUrl ? deps.baseUrl() : config.get('serverBaseURL') || '').replace(/\/+$/, '');
    return `${base}/api/pet-images/${action}`;
  };

  /** 加密鉴权体（对齐 mac 版 credentials）：无码 / 无设备 / 本地加密失败都直接拒 */
  function credentials(id, state) {
    const code = codeOf();
    if (!code) {
      return { ok: false, error: '请先在通用设置中使用有效的服务端激活码解锁；本地快捷码不支持云端图片。' };
    }
    const id2 = deviceId();
    if (!id2 || id2 === 'unknown-device') return { ok: false, error: '无法识别当前设备' };
    const encrypted = encryptedEnvelope(JSON.stringify({ code, deviceId: id2, id: id || '', state: state || '' }));
    if (!encrypted) return { ok: false, error: '授权信息加密失败' };
    return { ok: true, body: encrypted, identity: code };
  }

  /** 统一收响应：非 200 也先解 msg（服务端业务失败就是走 400/403/429/503 + msg） */
  async function failureOf(res) {
    let msg = '';
    try {
      const json = await res.json();
      msg = (json && json.msg) || '';
    } catch (e) {
      // 响应体不是 JSON：走下面的兜底文案
    }
    return { ok: false, error: msg || '服务器请求失败' };
  }

  /**
   * 发一次加密 POST 并解出 JSON 响应体。
   * @param {string} action
   * @param {{id?: string, state?: string, file?: {path: string, data: Buffer}}} params
   */
  async function request(action, params = {}) {
    const auth = credentials(params.id, params.state);
    if (!auth.ok) return auth;
    // 请求期间激活码可能被清掉或换掉：记下发起时的身份，回来比对（对齐 mac 版 identity 校验）
    const identity = auth.identity;

    let init;
    if (params.file) {
      const boundary = `Pet-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
      const head = Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="auth"\r\n\r\n${auth.body}` +
        `\r\n--${boundary}\r\nContent-Disposition: form-data; name="image"; filename="${fileNameOf(params.file.path)}"\r\n` +
        'Content-Type: application/octet-stream\r\n\r\n',
      );
      const tail = Buffer.from(`\r\n--${boundary}--\r\n`);
      init = {
        method: 'POST',
        headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}` },
        body: Buffer.concat([head, params.file.data, tail]),
      };
    } else {
      init = {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: auth.body,
      };
    }

    let res;
    try {
      res = await doFetch(urlOf(action), { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
    } catch (e) {
      return { ok: false, error: `网络异常：${e.message}` };
    }
    if (res.status !== 200) return failureOf(res);
    if (identity !== codeOf()) return { ok: false, error: '授权已变化，请重试' };
    let json = null;
    try {
      json = await res.json();
    } catch (e) {
      return { ok: false, error: '响应解析失败' };
    }
    if (!json || Number(json.code) !== 0) {
      return { ok: false, error: (json && json.msg) || '操作失败' };
    }
    return { ok: true, data: json.data || {} };
  }

  /** 取原始图片字节（content 接口直接回二进制，不走 JSON 信封） */
  async function requestBytes(action, params = {}) {
    const auth = credentials(params.id, params.state);
    if (!auth.ok) return auth;
    const identity = auth.identity;
    let res;
    try {
      res = await doFetch(urlOf(action), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: auth.body,
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch (e) {
      return { ok: false, error: `网络异常：${e.message}` };
    }
    if (res.status !== 200) return failureOf(res);
    if (identity !== codeOf()) return { ok: false, error: '授权已变化，请重试' };
    try {
      return { ok: true, data: Buffer.from(await res.arrayBuffer()) };
    } catch (e) {
      return { ok: false, error: `图片读取失败：${e.message}` };
    }
  }

  /** 读文件并做上传前校验（对齐 mac 版 validatedImageFile） */
  function readValidated(filePath, allowsGif) {
    let data;
    try {
      data = fs.readFileSync(filePath);
    } catch (e) {
      return { ok: false, error: '图片文件不存在' };
    }
    const check = validateUploadImage(data, { allowsGif, maxBytes: MAX_UPLOAD_BYTES });
    if (!check.ok) return check;
    return { ok: true, data, name: fileNameOf(filePath) };
  }

  return {
    /** 是否有可用的服务端激活码（面板据此决定 AI 生成按钮可用性与描述文案） */
    hasCode: () => Boolean(codeOf()),

    /** 图片库（历史图片的云端记录与配额都来自这里） */
    async list() {
      const res = await request('list', {});
      return res.ok ? { ok: true, library: normalizeLibrary(res.data) } : res;
    },

    /** 把某张云端图设为某状态选中图（只改服务端记录，本机落盘由调用方决定） */
    async select(id, state) {
      if (!id) return { ok: false, error: '缺少图片 ID' };
      if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
      const res = await request('select', { id, state });
      return res.ok ? { ok: true, library: normalizeLibrary(res.data) } : res;
    },

    /** 重试一张生成失败的图（用它的服务端任务 ID） */
    async retry(id, state) {
      if (!id) return { ok: false, error: '该失败任务缺少服务端 ID，请重新 AI 生成' };
      if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
      const res = await request('retry', { id, state });
      return res.ok ? { ok: true, library: normalizeLibrary(res.data) } : res;
    },

    /**
     * 上传一张图：state 传具体形象 id 即单状态生成；传 'all' 即逐状态各生成一张（整批扣 1 次配额）。
     * @param {string} filePath 本机图片路径
     * @param {string} [state] 形象 id 或 'all'（缺省按当前选中态由服务端处理）
     */
    async upload(filePath, state = '') {
      const read = readValidated(filePath, false);
      if (!read.ok) return read;
      const target = state === 'all' ? 'all' : isValidPetState(state) ? state : '';
      const res = await request('upload', { state: target, file: { path: filePath, data: read.data } });
      return res.ok ? { ok: true, library: normalizeLibrary(res.data) } : res;
    },

    /** 上传一次、逐状态各生成一张（对齐 mac 版 uploadAllStates：state 固定 'all'） */
    uploadAllStates(filePath) {
      return this.upload(filePath, 'all');
    },

    /**
     * 取图片字节：本机已有缓存直接复用（历史图片离线可看的关键）。
     * @param {string} id 服务端图片 ID
     * @param {null|((id: string) => Buffer|null)} cacheGetter 本机缓存读取器
     */
    async image(id, cacheGetter) {
      if (!id) return { ok: false, error: '缺少图片 ID' };
      if (cacheGetter) {
        const cached = cacheGetter(id);
        if (cached && cached.length) return { ok: true, data: cached };
      }
      return requestBytes('content', { id });
    },

    /**
     * 等单张图生成结束：ready 返回库，failed 直接返回错误（对齐 mac 版单 id helper）。
     * @param {string} id
     * @param {object} initial 上传/重试刚返回的库
     * @param {(label: string) => void} [onStage] 阶段文案回调
     */
    async waitForSingle(id, initial, onStage) {
      let library = initial;
      for (let round = 0; round < POLL_ROUNDS_SINGLE; round += 1) {
        const item = (library.images || []).find((r) => r.id === id);
        if (!item) return { ok: false, error: '生成记录不存在' };
        if (item.isReady) return { ok: true, library, record: item };
        if (item.status === 'failed') return { ok: false, error: item.error || '生成失败，可在历史图片中重试', library };
        if (onStage) onStage(item.stageLabel);
        await sleep(POLL_MS);
        const res = await this.list();
        if (!res.ok) return res;
        library = res.library;
      }
      return { ok: false, error: TIMEOUT_NOTICE, library };
    },

    /**
     * 等整批图都离开生成中状态：与单张版不同，个别失败不报错，
     * 返回的库里带着每条记录自己的状态，调用方按状态分别落盘 / 记失败。
     * @param {string[]} ids
     * @param {object} initial
     * @param {(label: string) => void} [onStage]
     */
    async waitForBatch(ids, initial, onStage) {
      const wanted = new Set(Array.isArray(ids) ? ids : []);
      let library = initial;
      for (let round = 0; round < POLL_ROUNDS_BATCH; round += 1) {
        const pending = (library.images || []).filter((r) => wanted.has(r.id) && r.isGenerating);
        if (!pending.length) return { ok: true, library };
        if (onStage) onStage((pending[0] && pending[0].stageLabel) || '正在逐状态生成…');
        await sleep(POLL_MS);
        const res = await this.list();
        if (!res.ok) return res;
        library = res.library;
      }
      return { ok: false, error: TIMEOUT_NOTICE, library };
    },
  };
}

module.exports = {
  createPetImageService,
  normalizeLibrary,
  normalizeRecord,
  stageLabel,
  isReady,
  isGenerating,
  fileNameOf,
  TIMEOUT_NOTICE,
  POLL_MS,
  MAX_UPLOAD_BYTES,
};
