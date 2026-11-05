// src/renderer/alert-preload.js
// 提示卡预加载：拉取内容 + 按钮回传 + 高度上报（自适应免滚动条）
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('appAlertAPI', {
  payload: () => ipcRenderer.invoke('alert:payload'),
  click: (index) => ipcRenderer.invoke('alert:button', index),
  // 渲染完把卡片真实高度报给主进程调整窗口
  resize: (height) => ipcRenderer.send('alert:resize', height),
});
