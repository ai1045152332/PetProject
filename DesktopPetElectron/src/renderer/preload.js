// src/renderer/preload.js
// 通过 contextBridge 暴露安全 API 给渲染层（contextIsolation 开启）
// 拖拽 / 右键均由渲染层监鼠标事件后走 IPC（CSS drag 区会吞事件，见 pet.css），这里只做通信桥
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
  // 手动拖窗三件套：渲染层拿鼠标屏幕坐标，主进程按 offset 搬窗口（pet-window.js createDragController）
  dragStart: (x, y) => ipcRenderer.send('pet:drag-start', { x, y }),
  dragMove: (x, y) => ipcRenderer.send('pet:drag-move', { x, y }),
  dragEnd: () => ipcRenderer.send('pet:drag-end'),
  // 右键小猫 → 主进程弹原生右键菜单
  requestContextMenu: () => ipcRenderer.send('pet:context-menu'),
});
