// src/renderer/friend-chat-preload.js
// 好友会话窗预加载：拉取会话内容 + 发送 + 点 ✕ 关闭（关闭时主进程上报已读）
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('friendChatAPI', {
  // 加载完主动拉一次整页内容；复用窗口（同好友追加新消息）时靠 send 增量刷新
  payload: () => ipcRenderer.invoke('friend-chat:payload'),
  onShow: (callback) => {
    ipcRenderer.on('friend-chat:show', (event, snapshot) => callback(snapshot));
  },
  send: (text) => ipcRenderer.invoke('friend-chat:send', { text }),
  close: () => ipcRenderer.send('friend-chat:close'),
});
