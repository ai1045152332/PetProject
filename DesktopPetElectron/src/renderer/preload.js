// src/renderer/preload.js
// 通过 contextBridge 暴露安全 API 给渲染层（contextIsolation 开启）
// 拖拽 / 右键均由渲染层监鼠标事件后走 IPC（CSS drag 区会吞事件，见 pet.css），这里只做通信桥
'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('petAPI', {
  // 喝水提醒触发时专注动画从帧头重播（唤起注意）
  onDrinkWater: (callback) => {
    ipcRenderer.on('drink-water:show', () => callback());
  },
  // Todo 到期提醒：同样让专注动画从帧头重播（提醒卡由主进程另开窗口弹）
  onTodoReminder: (callback) => {
    ipcRenderer.on('todo:remind', () => callback());
  },
  // 设置面板切换形象（focus / idel / sleep / pet）→ 渲染层换帧目录
  onPetState: (callback) => {
    ipcRenderer.on('pet:state', (event, state) => callback(state));
  },
  // 自定义形象图：主进程推送 { state: fileURL | null }，有则静态显示该图，无则回退帧动画
  onPetSprite: (callback) => {
    ipcRenderer.on('pet:sprite', (event, map) => callback(map));
  },
  // 刚加载时主动拉一次当前自定义形象
  requestSpriteSnapshot: () => ipcRenderer.invoke('pet:sprite-snapshot'),
  // 内置帧数清单：主进程按 assets/Sprites 目录枚举后下发，渲染层据此循环（帧数不在代码里写死）
  requestFrameCounts: () => ipcRenderer.invoke('pet:frame-counts'),
  // 手动拖窗三件套：渲染层拿鼠标屏幕坐标，主进程按 offset 搬窗口（pet-window.js createDragController）
  dragStart: (x, y) => ipcRenderer.send('pet:drag-start', { x, y }),
  dragMove: (x, y) => ipcRenderer.send('pet:drag-move', { x, y }),
  dragEnd: () => ipcRenderer.send('pet:drag-end'),
  // 右键小猫 → 主进程弹原生右键菜单
  requestContextMenu: () => ipcRenderer.send('pet:context-menu'),
  // 双击小猫 → 主进程开 Todo 清单（对标 mac 版 CatView clickCount == 2）
  openTodoList: () => ipcRenderer.send('pet:open-todo'),
});
