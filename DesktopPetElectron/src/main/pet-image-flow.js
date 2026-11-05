// src/main/pet-image-flow.js
// 「宠物信息 → 自定义状态图片」的主进程流程编排（对标 mac 版 SettingsPanel 的 AI 生成 / 配额 / 历史图片处理）
// 把 mac 版散在 SettingsPanel 里的状态收在一处：
//   · busy：生成期间禁用上传/历史/AI 按钮，避免并发改写同一批图
//   · 配额：从服务端 library 取 generationLimit / generationRemaining 缓存，面板只读快照
//   · 状态文案：aiStatusLabel 的等价物（生成进度、结果、失败原因）
// 落盘一律走 custom-sprite-store（与 mac 版共用同一目录与清单布局），网络一律走 pet-image-service，
// 本模块不碰 BrowserWindow / dialog，index.js 负责把快照推给面板与历史窗。
'use strict';

const { pathToFileURL } = require('url');
const { panelPetStates, allPetStateIds, isValidPetState } = require('./settings-service');

/** 失败记录里缺服务端任务 ID 时没法重试（对齐 mac 版「请重新 AI 生成」） */
const NO_SERVER_ID = '该失败任务缺少服务端 ID，请重新 AI 生成';

/**
 * 创建图片流程实例。
 * @param {object} deps
 * @param {object} deps.service createPetImageService 的产物
 * @param {object} deps.sprites custom-sprite-store 模块（可注入替身，便于单测）
 * @param {() => void} [deps.onSpritesChanged] 本机图片内容/选中变化（让宠物窗换图）
 * @param {(snapshot: object) => void} [deps.onSnapshot] 快照变化（推给面板 / 历史窗）
 */
function createPetImageFlow(deps) {
  const { service, sprites } = deps;
  const onSpritesChanged = deps.onSpritesChanged || (() => {});
  const onSnapshot = deps.onSnapshot || (() => {});

  let busy = false;
  let quotaLimit = 0;
  let quotaRemaining = 0;
  let statusText = '';
  let historyVisible = false;

  /** 状态 id → 中文名（历史窗与状态文案都要用，统一在这里出，渲染层不再自己翻译） */
  const stateLabels = {};
  for (const item of panelPetStates()) stateLabels[item.id] = item.label;

  /** 历史图片条目 → 渲染层数据（带 file:// 预览地址与归类文案） */
  function toRenderItem(item) {
    return {
      key: item.key,
      isDirect: item.isDirect,
      id: item.id,
      url: pathToFileURL(item.file).toString(),
      file: item.file,
      modifiedMs: item.modifiedMs,
      sizeText: item.sizeText,
      boundState: item.boundState || '',
      boundLabel: item.boundState ? stateLabels[item.boundState] || item.boundState : '',
      selectedStates: item.selectedStates || [],
      selectedLabels: (item.selectedStates || []).map((s) => stateLabels[s] || s),
      title: item.isDirect
        ? '📷 直接上传'
        : item.boundState ? '🪄 AI 生成' : '🪄 未归属',
      subtitle: `${formatTime(item.modifiedMs)} · ${item.sizeText}`,
    };
  }

  /** 各状态是否可用「恢复默认」（本机有直传图或当前生效着自定义图） */
  function resetAvailability() {
    const out = {};
    for (const id of allPetStateIds()) {
      out[id] = {
        hasLocal: sprites.hasLocalImage(id),
        hasCustom: sprites.hasCustomImage(id),
      };
    }
    return out;
  }

  /** 面板与历史窗共用的快照 */
  function snapshot() {
    return {
      busy,
      hasCode: service.hasCode(),
      quotaLimit,
      quotaRemaining,
      status: statusText,
      stateLabels,
      states: panelPetStates(),
      availability: resetAvailability(),
      // 只在历史窗开着时枚举目录：面板每次快照都扫盘没必要
      history: historyVisible ? historySnapshot() : null,
    };
  }

  /** 本机图片历史（完全读本地文件，打开面板不走网络） */
  function historySnapshot() {
    const failures = sprites.failures();
    return {
      items: sprites.localImages().map(toRenderItem),
      failures: Object.entries(failures)
        .filter(([state]) => isValidPetState(state))
        .map(([state, record]) => ({
          state,
          label: stateLabels[state] || state,
          serverID: (record && record.serverID) || '',
          message: (record && record.message) || '生成失败',
          at: Number(record && record.at) || 0,
          timeText: formatTime(Number(record && record.at) || 0),
          taskText: record && record.serverID ? String(record.serverID).slice(0, 8) : '无',
        })),
    };
  }

  function publish() {
    onSnapshot(snapshot());
    return snapshot();
  }

  function setStatus(text) {
    statusText = String(text || '');
    publish();
  }

  function applyQuota(library) {
    if (!library) return;
    quotaLimit = Number(library.generationLimit) || 0;
    quotaRemaining = Number(library.generationRemaining) || 0;
  }

  /**
   * 用当前激活码刷新剩余生成次数（仅在有码且空闲时发起，避免与图片同步互扰）。
   * 面板打开宠物信息区时调一次。
   */
  async function refreshQuota() {
    if (!service.hasCode() || busy) return snapshot();
    const res = await service.list();
    if (res.ok) applyQuota(res.library);
    return publish();
  }

  /**
   * 用服务端记录补全本机缺失的图片归属（老版本 AI 图本机没记生成状态）。
   * 不阻塞面板打开，失败就保持离线。
   */
  async function backfillOwnership() {
    if (!service.hasCode()) return snapshot();
    const res = await service.list();
    if (!res.ok) return snapshot();
    const records = {};
    for (const record of res.library.images) {
      if (record.state && isValidPetState(record.state)) records[record.id] = record.state;
    }
    // 只在有图可补时刷一次，否则别把用户的旧选择推成「变化」
    if (!sprites.mergeCloudStates(records)) return snapshot();
    return publish();
  }

  /**
   * 直接上传：原图（含 GIF 动图）仅存本机，不需要激活码、不占生成配额、即时生效。
   * @param {string} state 形象 id
   * @param {string} filePath 用户选中的图片路径
   */
  function uploadLocal(state, filePath) {
    const res = sprites.installLocalImage(state, filePath);
    if (!res.ok) return res;
    onSpritesChanged();
    setStatus(`已更新${stateLabels[state] || state}状态图片（仅本机）`);
    return res;
  }

  /** 恢复内置默认图：清掉该状态的直传图与选中标识（纯本地，不碰服务端） */
  function restoreDefault(state) {
    const res = sprites.clearLocalImage(state);
    if (!res.ok) return res;
    onSpritesChanged();
    setStatus(`已恢复${stateLabels[state] || state}状态的默认图片`);
    return res;
  }

  /**
   * AI 生成所有状态：一张照片上传一次，服务端逐状态各生成一张，整批只扣 1 次配额。
   * 结果直接落本机并本地生效，之后历史与选中都不再依赖服务端记录；
   * 本机没拿到图即视为生成失败，记下任务 ID 以便在历史图片里重试。
   * @param {string} filePath 用户选中的照片路径
   */
  async function generateAllStates(filePath) {
    if (!service.hasCode()) return { ok: false, error: unlockNotice() };
    if (quotaLimit > 0 && quotaRemaining <= 0) {
      setStatus('AI 生成次数已用完，请更换激活码或联系管理员');
      return { ok: false, error: statusText };
    }
    if (busy) return { ok: false, error: '正在处理图片，请稍候' };

    busy = true;
    setStatus('正在上传照片…');
    // 本批任务：服务端生成记录 ID → 状态，供落盘与失败重试使用
    const batch = new Map();
    try {
      const uploaded = await service.uploadAllStates(filePath);
      if (!uploaded.ok) throw new Error(uploaded.error);
      applyQuota(uploaded.library);
      // 同设备此刻不会有并发生成，因此刚返回的生成中记录即为本批全部状态
      for (const record of uploaded.library.images) {
        if (record.isGenerating && isValidPetState(record.state)) batch.set(record.id, record.state);
      }
      if (!batch.size) throw new Error('未返回生成记录');

      setStatus('正在逐状态生成…');
      const waited = await service.waitForBatch([...batch.keys()], uploaded.library, (label) => setStatus(label));
      applyQuota(waited.library);
      const library = waited.library || uploaded.library;

      let applied = 0;
      let failed = 0;
      for (const [id, state] of batch) {
        const record = (library.images || []).find((r) => r.id === id);
        if (!record || !record.isReady) {
          failed += 1;
          sprites.recordFailure(state, id, (record && record.error) || '未取到图片');
          continue;
        }
        const image = await service.image(id, (cid) => sprites.cachedCloudImage(cid));
        if (!image.ok || !image.data || !image.data.length) {
          failed += 1;
          sprites.recordFailure(state, id, (image && image.error) || '未取到图片');
          continue;
        }
        const installed = sprites.installCloudImage(id, image.data, state);
        if (installed.ok) applied += 1;
        else {
          failed += 1;
          sprites.recordFailure(state, id, installed.error);
        }
      }
      onSpritesChanged();
      setStatus(failed === 0
        ? `已为全部 ${applied} 个状态各生成一张并应用`
        : `已应用 ${applied} 个状态，${failed} 个失败（可在历史图片重试）`);
      return { ok: true, applied, failed };
    } catch (e) {
      // 上传或等待失败：本批已知状态全部记为失败，保留任务 ID 便于重试
      for (const [id, state] of batch) sprites.recordFailure(state, id, e.message);
      setStatus(`生成失败：${e.message}`);
      return { ok: false, error: e.message };
    } finally {
      busy = false;
      publish();
    }
  }

  /**
   * 重试某状态的失败生成：用记录里的服务端任务 ID 重新生成，成功后落盘并选中。
   * @param {string} state 形象 id
   */
  async function retryGeneration(state) {
    if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
    const record = sprites.failures()[state];
    if (!record) {
      setStatus(`${stateLabels[state] || state}状态没有失败记录`);
      return { ok: false, error: statusText };
    }
    if (!service.hasCode()) return { ok: false, error: unlockNotice() };
    const serverID = String(record.serverID || '');
    if (!serverID) {
      setStatus(NO_SERVER_ID);
      return { ok: false, error: NO_SERVER_ID };
    }
    if (busy) return { ok: false, error: '正在处理图片，请稍候' };

    busy = true;
    setStatus('正在重试生成，请稍候…');
    try {
      const retried = await service.retry(serverID, state);
      if (!retried.ok) throw new Error(retried.error);
      applyQuota(retried.library);
      const waited = await service.waitForSingle(serverID, retried.library, (label) => setStatus(label));
      if (!waited.ok) throw new Error(waited.error);
      const image = await service.image(serverID, (cid) => sprites.cachedCloudImage(cid));
      if (!image.ok || !image.data || !image.data.length) throw new Error(image.error || '未取到图片');
      const installed = sprites.installCloudImage(serverID, image.data, state);
      if (!installed.ok) throw new Error(installed.error);
      onSpritesChanged();
      setStatus(`已重新生成并应用到${stateLabels[state] || state}状态`);
      return { ok: true, state };
    } catch (e) {
      sprites.recordFailure(state, serverID, e.message);
      setStatus(`重试失败：${e.message}`);
      return { ok: false, error: e.message };
    } finally {
      busy = false;
      publish();
    }
  }

  /** 历史窗：把某张本机图片应用到某状态（纯本地切清单，不请求服务端） */
  function applyHistoryImage(key, state) {
    const res = sprites.selectLocalImage(key, state);
    if (!res.ok) {
      // 文件缺失时存储层已经把该状态回退成默认图，照样要刷一次宠物窗
      onSpritesChanged();
      setStatus((res && res.error) || '应用失败');
      publish();
      return res;
    }
    onSpritesChanged();
    setStatus(`已将本机图片应用到${stateLabels[state] || state}状态`);
    return res;
  }

  /** 历史窗：删除一张本机图片（正被选中的状态回退默认图） */
  function deleteHistoryImage(key) {
    const res = sprites.removeLocalImageByKey(key);
    if (!res.ok) return res;
    onSpritesChanged();
    setStatus('已删除本机图片，被影响的状态已恢复默认图');
    publish();
    return res;
  }

  /** 历史窗：清除某状态的失败记录（不动图片） */
  function clearHistoryFailure(state) {
    const res = sprites.clearFailure(state);
    if (!res.ok) return res;
    setStatus(`已清除${stateLabels[state] || state}状态的失败记录`);
    publish();
    return res;
  }

  return {
    snapshot,
    publish,
    historySnapshot,
    setStatus,
    isBusy: () => busy,
    refreshQuota,
    backfillOwnership,
    uploadLocal,
    restoreDefault,
    generateAllStates,
    retryGeneration,
    applyHistoryImage,
    deleteHistoryImage,
    clearHistoryFailure,
    /** 历史窗开着与否：只在开着时才随带历史数据，省得每次快照都枚举目录 */
    setHistoryVisible(visible) {
      historyVisible = Boolean(visible);
      return snapshot();
    },
    stateLabels,
  };
}

/** 未解锁时的统一引导文案（对齐 mac 版 showSpriteUnlockHint 的正文） */
function unlockNotice() {
  return '请在「通用设置 → 权限」输入有效的服务端激活码；AI 生成与重试生成需要它，直接上传、本机历史与本地切图不受影响。';
}

/** 时间戳 → 「MM-dd HH:mm」（与 mac 版 formatDate 一致） */
function formatTime(ms) {
  const n = Number(ms) || 0;
  if (!n) return '未知时间';
  const d = new Date(n);
  const pad = (v) => String(v).padStart(2, '0');
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

module.exports = { createPetImageFlow, unlockNotice, formatTime, NO_SERVER_ID };
