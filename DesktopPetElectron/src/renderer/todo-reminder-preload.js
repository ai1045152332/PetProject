// src/renderer/todo-reminder-preload.js
// Todo 到期提醒卡预加载：拉取卡片内容 + 关闭（点 ✕ 才消失）/ 完成（删待办停提醒）
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('todoReminderAPI', {
  // 加载完主动拉一次内容；窗口被复用时主进程再 send 一次增量
  payload: () => ipcRenderer.invoke('todo-reminder:payload'),
  onShow: (callback) => {
    ipcRenderer.on('todo-reminder:show', (event, card) => callback(card));
  },
  dismiss: () => ipcRenderer.send('todo-reminder:dismiss'),
  complete: (id) => ipcRenderer.send('todo-reminder:complete', id),
});
