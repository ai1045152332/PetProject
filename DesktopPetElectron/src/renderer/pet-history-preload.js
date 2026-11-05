// src/renderer/pet-history-preload.js
// 图片历史窗预加载：拉本机历史 + 应用/删除/重试/清除记录/在文件夹中显示
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('petHistoryAPI', {
  // 加载完主动拉一次整页数据（打开后本机文件变化由 pet-history:refresh 增量推回）
  payload: () => ipcRenderer.invoke('pet-history:payload'),
  onRefresh: (callback) => {
    ipcRenderer.on('pet-history:refresh', (event, snapshot) => callback(snapshot));
  },
  // 打开时定位的状态（= 宠物当前状态，对齐 mac 版 initialState）
  onFilter: (callback) => {
    ipcRenderer.on('pet-history:filter', (event, state) => callback(state));
  },
  apply: (key, state) => ipcRenderer.invoke('pet-history:apply', { key, state }),
  remove: (key) => ipcRenderer.invoke('pet-history:delete', { key }),
  retry: (state) => ipcRenderer.invoke('pet-history:retry', { state }),
  clearFailure: (state) => ipcRenderer.invoke('pet-history:clear-failure', { state }),
  reveal: (file) => ipcRenderer.send('pet-history:reveal', { file }),
  close: () => ipcRenderer.send('pet-history:close'),
});
