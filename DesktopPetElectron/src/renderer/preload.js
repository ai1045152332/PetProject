// src/renderer/preload.js
// 通过 contextBridge 暴露安全 API 给渲染层（contextIsolation 开启）
// 拖拽用 CSS -webkit-app-region 实现，无需 IPC；这里只做喝水提醒通信
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('petAPI', {
  // 主进程触发提醒 → 渲染层回调（专注动画从头播放唤起注意）
  onDrinkWater: (callback) => {
    ipcRenderer.on('drink-water:show', () => callback());
  },
  // 设置面板切换形象（focus / idel / sleep / pet）→ 渲染层换帧目录
  onPetState: (callback) => {
    ipcRenderer.on('pet:state', (event, state) => callback(state));
  },
});
