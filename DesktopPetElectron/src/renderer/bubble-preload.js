// src/renderer/bubble-preload.js
// 气泡窗预加载：只暴露「取台词 / 收更新 / 收淡出 / 回报尺寸 / 点掉气泡」五条通道
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('bubbleAPI', {
  // 加载完主动拉一次当前台词（窗口复用时主进程再 send 增量，避开时序问题）
  payload: () => ipcRenderer.invoke('bubble:payload'),
  onUpdate: (callback) => {
    ipcRenderer.on('bubble:update', (event, text) => callback(text));
  },
  onLeave: (callback) => {
    ipcRenderer.on('bubble:leave', () => callback());
  },
  // 内容排版后的尺寸：主进程据此把气泡贴到猫头顶并显形
  reportSize: (width, height) => ipcRenderer.send('bubble:resize', { width, height }),
  dismiss: () => ipcRenderer.send('bubble:dismiss'),
});
