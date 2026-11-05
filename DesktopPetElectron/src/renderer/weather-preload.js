// src/renderer/weather-preload.js
// 天气窗预加载：拉当前内容 + 接收推送 + 关闭 + 按城市查询（网络都在主进程）
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('weatherAPI', {
  // 加载完主动拉一次（打开即「本地天气加载中」），主进程每次查到都 send 推新内容
  payload: () => ipcRenderer.invoke('weather:payload'),
  onUpdate: (callback) => {
    ipcRenderer.on('weather:update', (event, content) => callback(content));
  },
  dismiss: () => ipcRenderer.send('weather:dismiss'),
  query: (city) => ipcRenderer.invoke('weather:query-city', city),
});
