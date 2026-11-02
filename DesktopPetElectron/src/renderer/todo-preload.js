// src/renderer/todo-preload.js
// Todo 清单窗预加载：只开通信桥（列表读写 / 关闭 / 主进程推送刷新）
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('todoAPI', {
  // 页面加载完主动拉一次当前待办（避免「主进程先 send、页面后挂监听」丢首帧）
  fetchList: () => ipcRenderer.invoke('todo:list-fetch'),
  // 新增：due 为 epoch 秒，null 表示不设提醒；返回最新全量列表
  add: (text, due) => ipcRenderer.invoke('todo:add', { text, due }),
  // 删除：同样回传最新全量列表，渲染层不自己改状态
  remove: (id) => ipcRenderer.invoke('todo:delete', id),
  close: () => ipcRenderer.send('todo:close'),
  // 主进程侧数据变化（到期标记 / 其它入口增删）→ 刷新列表
  onList: (callback) => {
    ipcRenderer.on('todo:list', (event, items) => callback(items));
  },
});
