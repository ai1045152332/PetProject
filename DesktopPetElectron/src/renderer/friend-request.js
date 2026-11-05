// src/renderer/friend-request.js — 好友申请卡：填充申请人 + 同意 / 拒绝 / ✕
'use strict';

function lockButtons() {
  // 做出选择后主进程立刻关卡，但关窗是异步的：先禁用避免连点重复提交
  document.getElementById('acceptBtn').disabled = true;
  document.getElementById('rejectBtn').disabled = true;
}

function applyCard(card) {
  if (!card) return;
  if (card.title) document.getElementById('title').textContent = card.title;
  document.getElementById('text').textContent = `${card.display || ''} 想加你为好友`;
  document.getElementById('acceptBtn').disabled = false;
  document.getElementById('rejectBtn').disabled = false;
}

document.getElementById('close').addEventListener('click', () => {
  if (window.friendRequestAPI) window.friendRequestAPI.dismiss();
});

document.getElementById('acceptBtn').addEventListener('click', () => {
  if (!window.friendRequestAPI) return;
  lockButtons();
  window.friendRequestAPI.accept();
});

document.getElementById('rejectBtn').addEventListener('click', () => {
  if (!window.friendRequestAPI) return;
  lockButtons();
  window.friendRequestAPI.reject();
});

// 加载完主动拉一次；卡片被复用（连续收到新申请）时靠 send 增量刷新
if (window.friendRequestAPI) {
  window.friendRequestAPI.payload().then(applyCard).catch(() => {});
  window.friendRequestAPI.onShow(applyCard);
}
