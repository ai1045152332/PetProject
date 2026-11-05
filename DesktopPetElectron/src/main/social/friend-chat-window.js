// src/main/friend-chat-window.js
// 与某位好友的会话窗（移植 mac 版 UI/FriendChatWindow.swift）
// 两条入口：设置面板好友列表点「聊天」；心跳下发了好友留言时自动弹出。
// 行为对齐 mac 版：
//   · 同一时刻只保留一个会话窗；换人会话时旧窗静默关闭且不回填已读（没看的消息服务端会重投）
//   · 先把本次下发的留言即时上屏，再用服务端 history 整体替换；历史为空 / 拉取失败时保留本次留言，
//     避免出现「有未读却空窗」
//   · 本机刚发出去的消息乐观上屏，历史记录到了再接在末尾，等下次会话由历史校正
//   · 点 ✕ 关卡时把本次下发的消息 ID 上报已读（尽力而为，失败不影响本地）
// 网络调用走注入的 api（index.js 用 social-service 回填），本模块只管窗口与排版。
'use strict';

const path = require('path');
const { BrowserWindow, ipcMain } = require('electron');

let win = null;
let ipcRegistered = false;
let api = null;

// 当前会话上下文（换人会话时整体重建）
let friendPetNo = 0;
let friendDisplay = '';
let rows = [];        // 已上屏的会话行（归一化消息对象）
let optimistic = [];  // 已乐观上屏、但还没被服务端历史覆盖的本机消息
let unreadIDs = [];   // 本次下发、关卡时确认已读的消息 ID
let statusText = '';
let readConfirmed = false;      // 本窗已上报过已读（避免 ✕ 与 close 事件重复上报）
let suppressReadConfirm = false; // 换人静默关窗：不把没看完的消息误标已读
let refreshTimer = null;        // 窗口开着时定时刷新历史（让「已读」自己变成已读）

// 已读状态只在拉历史时更新，所以窗口开着必须周期性重拉；10s 一次，够快且不打扰
const REFRESH_MS = 10000;

/** 会话窗标题用的友方文案：无名时回退「宠物 #号」（与好友列表同一口径） */
function displayFor(name, petNo) {
  const n = String(name || '').trim();
  return n ? `${n} #${petNo}` : `宠物 #${petNo}`;
}

/**
 * 会话行 → 渲染层数据：对方在左、我方在右。
 * 我方判定沿用 mac 版口径：不是这位好友发的，就是本机发的（会话只有两方）。
 */
function toRenderRows(list, petNo) {
  return list.map((row) => ({
    mine: Number(row.fromPetNo) !== Number(petNo),
    text: String(row.text || ''),
    read: Number(row.readMs) > 0,
    ms: Number(row.sentMs) > 0 ? Number(row.sentMs) : 0,
  }));
}

/** 当前整页内容（渲染层加载完 invoke 拉一次，之后由 send 推增量） */
function snapshot() {
  return {
    title: `💬 ${friendDisplay}`,
    friendPetNo,
    rows: toRenderRows(rows, friendPetNo),
    status: statusText,
  };
}

function pushUpdate() {
  if (win && !win.isDestroyed()) win.webContents.send('friend-chat:show', snapshot());
}

function setStatus(text) {
  statusText = String(text || '');
  pushUpdate();
}

/**
 * 上报本次下发的消息已读（只报一次）。
 * 触发点有两个：点 ✕（常见路径）与窗口被系统关闭（Cmd+W / 退出应用）——
 * 之前只挂在 ✕ 上，用 Cmd+W 关窗时对方永远看不到已读。
 */
function confirmReadNow() {
  if (readConfirmed) return;
  readConfirmed = true;
  const ids = unreadIDs.slice();
  unreadIDs = [];
  if (ids.length && api && api.confirmRead) api.confirmRead(ids).catch(() => {});
}

/** 窗口开着时定时重拉历史：已读状态只在历史里，不刷新就永远停在「未读」 */
function startRefresh() {
  stopRefresh();
  refreshTimer = setInterval(() => {
    // 只在前台看的时候刷，避免后台窗口反复打服务端
    if (win && !win.isDestroyed() && win.isFocused()) loadHistory();
  }, REFRESH_MS);
  if (refreshTimer.unref) refreshTimer.unref();
}

function stopRefresh() {
  if (refreshTimer) {
    clearInterval(refreshTimer);
    refreshTimer = null;
  }
}

/** 同一条消息的启发式判定：服务端历史没有本地乐观行的 id，只能按「同发送方 + 同文本 + 相邻时间」配对 */
function isSameMessage(historyRow, localRow) {
  if (!historyRow || !localRow) return false;
  if (String(historyRow.text) !== String(localRow.text)) return false;
  if (Number(historyRow.fromPetNo) !== Number(localRow.fromPetNo)) return false;
  const dt = Math.abs(Number(historyRow.sentMs || 0) - Number(localRow.sentMs || 0));
  return dt <= 120000; // 2 分钟容差：服务端 SentAt 与本地发送时刻不会差太多
}

/** 拉服务端聊天记录；失败或为空时保留本次下发的消息（旧服务端没有 history 接口也能用） */
async function loadHistory() {
  const target = friendPetNo;
  let res;
  try {
    res = await api.history(target);
  } catch (e) {
    res = { ok: false, error: e.message };
  }
  // 请求期间已经换人或关窗：结果直接丢弃
  if (!win || win.isDestroyed() || friendPetNo !== target) return;
  if (!res || !res.ok) {
    setStatus(`聊天记录拉取失败：${(res && res.error) || '未知错误'}`);
    return;
  }
  const history = Array.isArray(res.messages) ? res.messages : [];
  if (!history.length) {
    setStatus('暂时只显示本次收到的消息（服务端还没有可回看的历史）');
    return;
  }
  // 乐观行一旦在历史里出现同一条（拿到服务端 id）就丢掉本地副本，否则同一条会显示两遍
  optimistic = optimistic.filter((m) => !history.some((h) => isSameMessage(h, m)));
  rows = [...history, ...optimistic];
  pushUpdate();
}

function ensureIpc() {
  if (ipcRegistered) return;
  ipcRegistered = true;
  // 页面加载完主动拉一次内容（复用窗口时另有 friend-chat:show 增量）
  ipcMain.handle('friend-chat:payload', () => snapshot());
  // 发送：主进程调服务端，成功后乐观上屏（渲染层不自己插行，保持单一数据源）
  ipcMain.handle('friend-chat:send', async (event, payload) => {
    const text = String((payload && payload.text) || '').trim();
    if (!text) return { ok: false, error: '消息内容不能为空' };
    if (friendPetNo <= 0) return { ok: false, error: '还没确定要发给谁，请先从好友列表打开会话' };
    setStatus('发送中…');
    let res;
    try {
      res = await api.send(friendPetNo, text);
    } catch (e) {
      res = { ok: false, error: e.message };
    }
    if (!res || !res.ok) {
      setStatus(`发送失败：${(res && res.error) || '未知错误'}`);
      return res || { ok: false, error: '发送失败' };
    }
    const mine = {
      id: '',
      fromPetNo: api.myPetNo(),
      fromName: api.petName(),
      text,
      sentMs: Date.now(),
      readMs: 0,
    };
    rows.push(mine);
    optimistic.push(mine);
    setStatus('已发送，对方下次联网就能看到（通常 1 分钟内）');
    return { ok: true };
  });
  // 点 ✕：关窗（已读上报统一挂在窗口 close 事件上，任何关闭方式都覆盖）
  ipcMain.on('friend-chat:close', () => {
    closeFriendChat();
  });
}

function createWindow() {
  win = new BrowserWindow({
    // 与 mac 版会话窗同尺寸（380×620）：内容区固定高度，消息多了内部滚动
    width: 380,
    height: 620,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    alwaysOnTop: true,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    hasShadow: false,
    center: true,
    show: false,
    title: '好友消息',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, '..', '..', 'renderer', 'friend-chat-preload.js'),
    },
  });
  win.setAlwaysOnTop(true, 'screen-saver');
  win.loadFile(path.join(__dirname, '..', '..', 'renderer', 'friend-chat.html'));
  win.once('ready-to-show', () => {
    if (win && !win.isDestroyed()) win.show();
    startRefresh();
  });
  // 任何关闭方式（✕ / Cmd+W / 退出应用）都要把本次下发的消息标已读；
  // 换人会话的静默关闭由 suppressReadConfirm 挡掉（没看完的消息留给服务端重投）
  win.on('close', () => {
    stopRefresh();
    if (!suppressReadConfirm) confirmReadNow();
  });
  // 重新聚焦：立刻重拉一次，回到窗口就能看到对方是否已读
  win.on('focus', () => {
    if (friendPetNo > 0) loadHistory();
  });
  win.on('closed', () => {
    stopRefresh();
    win = null;
  });
}

/**
 * 注入服务端能力（index.js 用 social-service 回填）。
 * @param {{history: Function, send: Function, confirmRead: Function, myPetNo: () => number, petName: () => string}} deps
 */
function setFriendChatAPI(deps) {
  api = deps;
  ensureIpc();
}

/**
 * 打开（或复用）与某位好友的会话窗。
 * @param {object} opts
 * @param {number} opts.petNo 好友宠物号
 * @param {string} [opts.display] 好友展示名（缺省按「宠物 #号」）
 * @param {Array} [opts.incoming] 本次下发的待展示消息（先即时上屏，随后由历史替换）
 * @param {string[]} [opts.unreadIds] incoming 对应的消息 ID，关卡时上报已读
 */
function openFriendChat({ petNo, display, incoming = [], unreadIds = [] } = {}) {
  if (!api) return null;
  const target = Number(petNo) || 0;
  if (target <= 0) return null;

  // 同一位好友已经开着：并入新消息并置顶，不重开、不丢用户正在输入的内容
  if (win && !win.isDestroyed() && friendPetNo === target) {
    absorb({ incoming, unreadIds });
    win.show();
    win.focus();
    return win;
  }
  // 换人会话：旧窗静默关掉（不回填已读，服务端稍后会重投）
  if (win && !win.isDestroyed()) closeFriendChat({ markRead: false });

  friendPetNo = target;
  friendDisplay = display || displayFor('', target);
  rows = Array.isArray(incoming) ? incoming.slice() : [];
  optimistic = [];
  unreadIDs = Array.isArray(unreadIds) ? unreadIds.filter(Boolean) : [];
  statusText = '';
  readConfirmed = false;
  createWindow();
  loadHistory();
  return win;
}

/** 同好友会话窗已开着又来了新消息：并入待展示行与待确认 ID */
function absorb({ incoming = [], unreadIds = [] }) {
  const known = new Set(rows.map((m) => m.id).filter(Boolean));
  for (const msg of incoming) {
    if (!msg || (msg.id && known.has(msg.id))) continue;
    rows.push(msg);
  }
  const knownIds = new Set(unreadIDs);
  unreadIDs.push(...unreadIds.filter((id) => id && !knownIds.has(id)));
  pushUpdate();
  loadHistory();
}

/**
 * 心跳下发的一批消息入口：可能混着好几位好友的留言，只打开最近一位的会话
 * （其余未确认已读的不会被丢掉，服务端到点会重投，届时再弹窗）。
 * @param {Array} messages 归一化后的消息数组（旧 → 新）
 * @returns {BrowserWindow|null} 弹出来的会话窗（没弹返回 null，供 index.js 让出置顶）
 */
function presentFriendMessages(messages) {
  const list = (Array.isArray(messages) ? messages : []).filter((m) => m && Number(m.fromPetNo) > 0);
  const latest = list[list.length - 1];
  if (!latest) return null;
  const group = list.filter((m) => Number(m.fromPetNo) === Number(latest.fromPetNo));
  return openFriendChat({
    petNo: latest.fromPetNo,
    display: displayFor(latest.fromName, latest.fromPetNo),
    incoming: group,
    unreadIds: group.map((m) => m.id).filter(Boolean),
  });
}

/**
 * 关掉会话窗。
 * @param {{markRead?: boolean}} [opts] markRead=false 用于换人会话的静默关闭（不误标已读）
 */
function closeFriendChat({ markRead = true } = {}) {
  suppressReadConfirm = !markRead;
  stopRefresh();
  if (win && !win.isDestroyed()) win.close();
  suppressReadConfirm = false;
  win = null;
  rows = [];
  optimistic = [];
  unreadIDs = [];
  friendPetNo = 0;
  statusText = '';
  readConfirmed = false;
}

function isFriendChatOpen() {
  return Boolean(win && !win.isDestroyed());
}

module.exports = {
  setFriendChatAPI,
  openFriendChat,
  presentFriendMessages,
  closeFriendChat,
  isFriendChatOpen,
  displayFor,
};
