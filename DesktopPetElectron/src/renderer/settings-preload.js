// src/renderer/settings-preload.js
// 设置面板预加载：只暴露面板需要的读写接口（contextIsolation 开启）
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('settingsAPI', {
  // 读取全部分区的当前状态（提醒 / 宠物 / 通用）
  load: () => ipcRenderer.invoke('settings:load'),

  // 提醒设置：写入间隔（主进程校验并立即重启提醒调度）
  setInterval: (minutes) => ipcRenderer.invoke('settings:set-interval', minutes),
  // 立即弹一次提醒，便于确认效果
  testReminder: () => ipcRenderer.send('settings:test-reminder'),

  // 宠物信息：名称 / 形象
  setPetName: (name) => ipcRenderer.invoke('settings:set-pet-name', name),
  setPetState: (state) => ipcRenderer.invoke('settings:set-pet-state', state),

  // 通用设置：宠物大小 / 开机自启 / 检查更新
  setPetScale: (scale) => ipcRenderer.invoke('settings:set-pet-scale', scale),
  setAutoLaunch: (enabled) => ipcRenderer.invoke('settings:set-auto-launch', enabled),
  checkUpdate: () => ipcRenderer.invoke('settings:check-update'),

  close: () => ipcRenderer.send('settings:close'),
});
