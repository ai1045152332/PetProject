// src/renderer/reminder-preload.js
// 提醒窗预加载：暴露关闭方法（点击关闭 → 通知主进程收起提醒并让宠物回 focus）
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('reminderAPI', {
  close: () => ipcRenderer.send('drink-water:dismiss'),
});
