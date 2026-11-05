// src/renderer/news-preload.js
// 热点新闻卡预加载：拉列表 + 关闭 + 外部链接交给主进程 shell 打开
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('newsAPI', {
  // 加载完主动拉一次（窗口复用时主进程再 send 一次增量，避开「先 send 后挂监听」时序问题）
  items: () => ipcRenderer.invoke('news:payload'),
  onUpdate: (callback) => {
    ipcRenderer.on('news:update', (event, items) => callback(items));
  },
  dismiss: () => ipcRenderer.send('news:dismiss'),
  openLink: (url) => ipcRenderer.send('news:open-link', url),
});
