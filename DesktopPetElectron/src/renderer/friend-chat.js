// src/renderer/friend-chat.js — 好友会话窗：渲染聊天记录 + 输入回复 + ✕ 关闭（关闭后对方看到已读）
// 渲染口径对齐 mac 版：对方气泡在左、我方在右；我方气泡追加「已读 / 未读」；
// 时间当天只显示 HH:MM，跨天补「M月D日」；没有时刻（ms=0）则整段元信息不显示。
'use strict';

let sending = false;

function esc(value) {
  return String(value == null ? '' : value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function timeText(ms) {
  if (!ms) return '';
  const d = new Date(ms);
  const pad = (n) => (n < 10 ? '0' : '') + n;
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (d.toDateString() === new Date().toDateString()) return hm;
  return `${d.getMonth() + 1}月${d.getDate()}日 ${hm}`;
}

function renderThread(snapshot) {
  const el = document.getElementById('thread');
  const rows = (snapshot && Array.isArray(snapshot.rows)) ? snapshot.rows : [];
  if (!rows.length) {
    el.innerHTML = '<div class="empty">还没有聊天记录，发第一条打个招呼吧～</div>';
    return;
  }
  el.innerHTML = rows.map((row) => {
    let meta = timeText(row.ms);
    if (row.mine) meta += (meta ? ' · ' : '') + (row.read ? '已读' : '未读');
    return `<div class="row${row.mine ? ' mine' : ''}">`
      + `<div class="bubble">${esc(row.text)}</div>`
      + (meta ? `<div class="meta">${esc(meta)}</div>` : '')
      + '</div>';
  }).join('');
  el.scrollTop = el.scrollHeight;
}

function applySnapshot(snapshot) {
  if (!snapshot) return;
  if (snapshot.title) document.getElementById('title').textContent = snapshot.title;
  // 标题形如「💬 小花 #12345」，输入框占位只取好友展示名
  const display = String(snapshot.title || '').replace(/^💬\s*/, '') || '好友';
  document.getElementById('chatInput').placeholder = `回复 ${display}…`;
  document.getElementById('status').textContent = snapshot.status
    || '看完点 ✕ 关闭（关闭后对方能看到已读）';
  renderThread(snapshot);
  sending = false;
  document.getElementById('sendBtn').disabled = false;
}

async function sendChat() {
  const input = document.getElementById('chatInput');
  const text = (input.value || '').trim();
  if (!text || sending || !window.friendChatAPI) return;
  sending = true;
  document.getElementById('sendBtn').disabled = true;
  // 先清空输入框：主进程要发一阵子，这期间用户能接着写下一条
  input.value = '';
  const res = await window.friendChatAPI.send(text).catch(() => null);
  if (!res || !res.ok) {
    // 发送失败时内容已丢，回填输入框方便直接重发
    input.value = text;
    sending = false;
    document.getElementById('sendBtn').disabled = false;
    return;
  }
  // 成功路径由主进程推 friend-chat:show 增量（乐观上屏 + 状态行）
}

document.getElementById('sendBtn').addEventListener('click', sendChat);
document.getElementById('chatInput').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault();
    sendChat();
  }
});
document.getElementById('close').addEventListener('click', () => {
  if (window.friendChatAPI) window.friendChatAPI.close();
});

if (window.friendChatAPI) {
  window.friendChatAPI.payload().then(applySnapshot).catch(() => {});
  window.friendChatAPI.onShow(applySnapshot);
}
