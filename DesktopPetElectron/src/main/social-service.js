// src/main/social-service.js
// 好友与宠物消息客户端（移植 mac 版 Services/FriendService.swift）
// 与后端 /api/social/<action> 交互：注册取宠物号、发好友申请、同意/拒绝、列好友、删好友、
// 发消息、确认已读、回看聊天记录。
// 请求体统一用服务端公钥加密信封（含 deviceId / petName 等字段），与激活码、云端图片同一条链路；
// 后端一律 HTTP 200，业务失败用信封 code≠0 + msg 回传，这里把它转成 { ok:false, error } 结果对象，
// 渲染层（设置面板 / 聊天窗）只判 ok 并展示 error 文案，不必各自 try/catch。
// 网络、地址、设备信息都可注入，与 IPC / 窗口解耦，便于单测。
'use strict';

const config = require('./config-store');
const info = require('./app-info');
const { encryptedEnvelope } = require('./crypto-envelope');

const TIMEOUT_MS = 12000;         // 单次请求超时（对齐 mac 版 URLSession 12s）
const PET_NO_KEY = 'petNo';       // 本机宠物号缓存（心跳响应或 register 接口写入）
const SHOWN_REQ_KEY = 'shownFriendRequestIDs'; // 已弹过卡的好友申请 ID（心跳每分钟下发，避免反复弹）
const SHOWN_KEEP = 200;           // 只保留最近 200 个 ID，避免无限增长
const MAX_MESSAGE_RUNES = 200;    // 单条消息字符上限（与服务端 maxMessageRunes 一致，先在本机拦）

/** 展示用文案：无名时回退「宠物 #号」（与 mac 版 PetFriend.display 一致） */
function displayFor(name, petNo) {
  const n = String(name || '').trim();
  return n ? `${n} #${petNo}` : `宠物 #${petNo}`;
}

/** JSON 数字统一取整数（数字/字符串都兼容，对齐 mac 版 intVal） */
function intVal(value) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.trunc(n) : 0;
}

/** 好友条目归一化：{ petNo, petName, display } */
function normalizeFriend(raw) {
  const petNo = intVal(raw && raw.petNo);
  if (petNo <= 0) return null;
  const petName = String((raw && raw.petName) || '');
  return { petNo, petName, display: displayFor(petName, petNo) };
}

/** 好友申请归一化：{ id, fromPetNo, fromName, display }（缺 id 或号无效的一律丢掉） */
function normalizeRequest(raw) {
  const id = String((raw && raw.id) || '');
  const fromPetNo = intVal(raw && raw.fromPetNo);
  if (!id || fromPetNo <= 0) return null;
  const fromName = String((raw && raw.fromName) || '');
  return { id, fromPetNo, fromName, display: displayFor(fromName, fromPetNo) };
}

/**
 * 聊天留痕归一化：{ id, fromPetNo, fromName, text, sentMs, readMs }
 * sentMs 为 0（含缺失）表示「没有时间」，气泡不显示时刻；readMs > 0 表示对方已读。
 */
function normalizeMessage(raw, myPetNo) {
  const fromPetNo = intVal(raw && raw.fromPetNo);
  const text = String((raw && raw.text) || '');
  if (fromPetNo <= 0 || !text) return null;
  return {
    id: String((raw && raw.id) || ''),
    fromPetNo,
    fromName: String((raw && raw.fromName) || ''),
    text,
    sentMs: intVal(raw && raw.sentMs),
    readMs: intVal(raw && raw.readMs),
    // 我方气泡：聊天窗按收发分侧用（对方号 == 本机号即自己发的）
    mine: myPetNo > 0 && fromPetNo === myPetNo,
  };
}

function normalizeList(raw, fn) {
  return (Array.isArray(raw) ? raw : []).map(fn).filter(Boolean);
}

/**
 * 创建好友服务实例。
 * @param {object} [deps]
 * @param {Function} [deps.fetch] 可注入 fetch（单测 / 代理用）
 * @param {() => string} [deps.baseUrl] 后端地址（默认读 config 的 serverBaseURL）
 * @param {() => string} [deps.deviceId] 设备 ID（默认 app-info.resolveDeviceId）
 * @param {() => string} [deps.petName] 宠物名（默认 app-info.petName，与心跳同源）
 * @param {(petNo: number) => void} [deps.onPetNo] 宠物号变化回调（面板刷新展示）
 * @param {Function} [deps.setTimer] 可注入定时器（超时用，单测）
 */
function createSocialService(deps = {}) {
  const doFetch = deps.fetch || fetch;
  const deviceId = () => (deps.deviceId ? deps.deviceId() : info.resolveDeviceId());
  const petName = () => (deps.petName ? deps.petName() : info.petName());
  const urlOf = (action) => {
    const base = String(deps.baseUrl ? deps.baseUrl() : config.get('serverBaseURL') || '').replace(/\/+$/, '');
    return `${base}/api/social/${action}`;
  };

  /**
   * 构造并发送一个加密 POST：返回响应里的 data 字典。
   * 失败（本地加密、网络、HTTP 非 200、响应解析、业务 code≠0）统一回 { ok:false, error }。
   */
  async function post(action, payload = {}) {
    const id = deviceId();
    if (!id || id === 'unknown-device') return { ok: false, error: '无法识别当前设备' };
    const body = JSON.stringify({ ...payload, deviceId: id, petName: petName(), hostname: info.hostname() });
    const encrypted = encryptedEnvelope(body);
    if (!encrypted) return { ok: false, error: '本地加密失败' };

    let res;
    try {
      res = await doFetch(urlOf(action), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: encrypted,
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch (e) {
      return { ok: false, error: `网络异常：${e.message}` };
    }
    if (res.status !== 200) return { ok: false, error: '服务器请求失败' };
    let json = null;
    try {
      json = await res.json();
    } catch (e) {
      return { ok: false, error: '响应解析失败' };
    }
    if (!json || intVal(json.code) !== 0) {
      return { ok: false, error: (json && json.msg) || '操作失败' };
    }
    return { ok: true, data: json.data || {} };
  }

  /** 写入宠物号：仅在有效且变化时落盘并广播（对齐 mac 版 setMyPetNo） */
  function setMyPetNo(value) {
    const petNo = intVal(value);
    if (petNo <= 0 || petNo === myPetNo()) return petNo;
    config.set(PET_NO_KEY, petNo);
    if (deps.onPetNo) deps.onPetNo(petNo);
    return petNo;
  }

  function myPetNo() {
    return intVal(config.get(PET_NO_KEY));
  }

  return {
    myPetNo,
    setMyPetNo,

    /** 注册/刷新本机宠物号（设备从未心跳时也能即时拿到） */
    async register() {
      const res = await post('register', {});
      if (!res.ok) return res;
      return { ok: true, petNo: setMyPetNo(res.data.petNo) };
    },

    /** 拉好友列表 */
    async listFriends() {
      const res = await post('list', {});
      if (!res.ok) return res;
      return { ok: true, friends: normalizeList(res.data.friends, normalizeFriend) };
    },

    /**
     * 发起好友申请（需对方同意）。status=pending 等对方同意，mutual 已互为好友。
     * @param {number} petNo 对方宠物号
     */
    async addFriend(petNo) {
      const target = intVal(petNo);
      if (target <= 0) return { ok: false, error: '请输入正确的宠物号' };
      const res = await post('add', { petNo: target });
      if (!res.ok) return res;
      return {
        ok: true,
        status: String(res.data.status || 'pending'),
        notice: String(res.data.status) === 'mutual' ? '你们已互为好友' : '申请已发出，对方同意后你们就是好友了',
        friends: normalizeList(res.data.friends, normalizeFriend),
      };
    },

    /** 拉发给本机、待处理的好友申请（同意/拒绝前一直保留） */
    async pendingRequests() {
      const res = await post('requests', {});
      if (!res.ok) return res;
      return { ok: true, requests: normalizeList(res.data.requests, normalizeRequest) };
    },

    /**
     * 一次拉齐设置面板「好友消息」区要用的数据：宠物号 + 好友列表 + 待处理申请。
     * 取号失败就算了（心跳迟早会补上），好友拉不到才整块报错；
     * 申请失败不阻断好友列表（旧服务端可能还没这个接口），与 mac 版 loadSocial 同口径。
     */
    async syncAll() {
      const reg = await this.register().catch(() => ({ ok: false }));
      const friends = await this.listFriends();
      if (!friends.ok) return { ...friends, petNo: this.myPetNo(), requests: [] };
      const reqs = await this.pendingRequests().catch(() => ({ ok: false, requests: [] }));
      return {
        ok: true,
        petNo: this.myPetNo(),
        friends: friends.friends,
        requests: reqs.ok ? reqs.requests : [],
        // 注册取号失败时给出原因（面板靠它说明「为什么还没号」）
        error: reg.error || '',
      };
    },

    /** 同意某宠物号的申请：成功后双方互为好友 */
    async acceptRequest(fromPetNo) {
      return this.decideRequest('accept', fromPetNo);
    },

    /** 拒绝对方的申请（不建立好友关系） */
    async rejectRequest(fromPetNo) {
      return this.decideRequest('reject', fromPetNo);
    },

    async decideRequest(action, fromPetNo) {
      const target = intVal(fromPetNo);
      if (target <= 0) return { ok: false, error: '宠物号无效' };
      const res = await post(action, { petNo: target });
      if (!res.ok) return res;
      return { ok: true, friends: normalizeList(res.data.friends, normalizeFriend) };
    },

    /** 删好友（双向解除，并清掉双方间的待处理申请） */
    async removeFriend(petNo) {
      const target = intVal(petNo);
      if (target <= 0) return { ok: false, error: '宠物号无效' };
      const res = await post('remove', { petNo: target });
      if (!res.ok) return res;
      return { ok: true, friends: normalizeList(res.data.friends, normalizeFriend) };
    },

    /** 给好友发消息（落到对方云端收件箱，等其下次心跳拉取展示） */
    async sendMessage(toPetNo, text) {
      const target = intVal(toPetNo);
      if (target <= 0) return { ok: false, error: '宠物号无效' };
      const content = String(text || '').trim();
      if (!content) return { ok: false, error: '消息内容不能为空' };
      if ([...content].length > MAX_MESSAGE_RUNES) {
        return { ok: false, error: `消息过长（最多 ${MAX_MESSAGE_RUNES} 字）` };
      }
      return post('send', { petNo: target, text: content });
    },

    /** 拉与某位好友的最近聊天记录（旧 → 新）；服务端要求双方已互加好友 */
    async conversationHistory(petNo) {
      const target = intVal(petNo);
      if (target <= 0) return { ok: false, error: '宠物号无效' };
      const res = await post('history', { petNo: target });
      if (!res.ok) return res;
      const mine = myPetNo();
      return { ok: true, messages: normalizeList(res.data.messages, (m) => normalizeMessage(m, mine)) };
    },

    /** 看完消息关卡时确认已读（尽力而为：失败不影响本地，服务端到点会重投） */
    async confirmRead(ids) {
      const list = (Array.isArray(ids) ? ids : []).map((id) => String(id || '')).filter(Boolean);
      if (!list.length) return { ok: true, marked: 0 };
      const res = await post('read', { ids: list });
      return res.ok ? { ok: true, marked: intVal(res.data.marked) } : res;
    },

    /**
     * 心跳响应里的 messages / requests 归一化（字段与 /api/social 同一套）。
     * @returns {{messages: Array, requests: Array}}
     */
    parseDelivery(data) {
      const src = data || {};
      const mine = myPetNo();
      return {
        messages: normalizeList(src.messages, (m) => normalizeMessage(m, mine)),
        requests: normalizeList(src.requests, normalizeRequest),
      };
    },

    /**
     * 记录已弹过卡的申请 ID，返回其中尚未弹过的（首次见到的才需要弹卡）。
     * 对齐 mac 版 markRequestsShown：只保留最近 200 个 ID。
     */
    markRequestsShown(requests) {
      const shown = Array.isArray(config.get(SHOWN_REQ_KEY)) ? config.get(SHOWN_REQ_KEY).map(String) : [];
      const seen = new Set(shown);
      const fresh = [];
      for (const req of Array.isArray(requests) ? requests : []) {
        if (!req || !req.id || seen.has(req.id)) continue;
        fresh.push(req);
        seen.add(req.id);
        shown.push(req.id);
      }
      if (fresh.length) config.set(SHOWN_REQ_KEY, shown.slice(-SHOWN_KEEP));
      return fresh;
    },
  };
}

module.exports = {
  createSocialService,
  displayFor,
  normalizeFriend,
  normalizeRequest,
  normalizeMessage,
  PET_NO_KEY,
  SHOWN_REQ_KEY,
  MAX_MESSAGE_RUNES,
};
