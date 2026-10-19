// src/renderer/preload.js
// 通过 contextBridge 暴露安全 API 给渲染层（contextIsolation 开启）
// 拖拽用 CSS -webkit-app-region 实现，无需 IPC；这里只做喝水提醒通信
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('petAPI', {
  // 主进程触发提醒 → 渲染层回调（切到 warn）
  onDrinkWater: (callback) => {
    ipcRenderer.on('drink-water:show', () => callback());
  },
  // 提醒关闭 → 渲染层回到 focus
  onDrinkWaterReset: (callback) => {
    ipcRenderer.on('drink-water:reset', () => callback());
  },
});
