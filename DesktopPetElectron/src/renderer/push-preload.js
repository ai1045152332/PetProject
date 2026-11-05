// src/renderer/push-preload.js
// 运营推送卡预加载：拉取本次内容 + 关闭
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pushAPI', {
  // 加载完主动拉一次（窗口复用时会再 send 一次增量）
  payload: () => ipcRenderer.invoke('push:payload'),
  onUpdate: (callback) => ipcRenderer.on('push:update', (event, payload) => callback(payload)),
  dismiss: () => ipcRenderer.send('push:dismiss'),
  // 视频播不了时的退路：把链接交给系统浏览器（主进程只放行 http/https）
  openExternal: (url) => ipcRenderer.send('push:open-external', url),
});
