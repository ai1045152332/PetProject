// src/renderer/todo-reminder.js — 到期提醒卡：填充内容 + ✕ 关闭 / ✅ 完成（点 ✕ 前常驻）
'use strict';

let currentId = null; // 当前卡片对应的待办 id，「完成」按钮据此删除

function applyCard(card) {
  if (!card) return;
  currentId = card.id || null;
  if (card.title) document.getElementById('title').textContent = card.title;
  document.getElementById('text').textContent = card.text || '';
  const sub = document.getElementById('subtitle');
  sub.textContent = card.subtitle || '';
  sub.style.display = card.subtitle ? '' : 'none';
}

document.getElementById('close').addEventListener('click', () => {
  if (window.todoReminderAPI) window.todoReminderAPI.dismiss();
});

// 确认完成：删除该待办（主进程落盘）并收起卡片，逾期提醒随即停止
document.getElementById('doneBtn').addEventListener('click', () => {
  if (window.todoReminderAPI) window.todoReminderAPI.complete(currentId);
});

// 加载完主动拉一次；窗口被复用（连续多条到期）时靠 send 增量刷新
if (window.todoReminderAPI) {
  window.todoReminderAPI.payload().then(applyCard).catch(() => {});
  window.todoReminderAPI.onShow(applyCard);
}
