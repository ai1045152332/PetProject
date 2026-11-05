// src/renderer/friend-request-preload.js
// 好友申请卡预加载：拉取卡片内容 + 同意 / 拒绝 / ✕ 关闭
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('friendRequestAPI', {
  // 加载完主动拉一次内容；卡片被复用（连续收到新申请）时靠 send 增量刷新
  payload: () => ipcRenderer.invoke('friend-request:payload'),
  onShow: (callback) => {
    ipcRenderer.on('friend-request:show', (event, card) => callback(card));
  },
  accept: () => ipcRenderer.send('friend-request:accept'),
  reject: () => ipcRenderer.send('friend-request:reject'),
  dismiss: () => ipcRenderer.send('friend-request:dismiss'),
});
