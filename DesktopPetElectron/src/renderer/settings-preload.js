// src/renderer/settings-preload.js
// 设置面板预加载：只暴露面板需要的读写接口（contextIsolation 开启）
'use strict';

const { contextBridge, ipcRenderer, systemPreferences } = require('electron');

/**
 * 面板配色要跟 mac 原生版一致：底板材质、文字分层、开关色都由系统外观决定，
 * 所以把「是否 macOS / 是否深色外观 / 系统强调色」透给渲染层去挂 CSS 变量。
 * systemPreferences 在非 macOS 上不存在，取值失败时统一走默认（浅色 + 蓝）。
 */
function readSystemTheme() {
  const isMac = process.platform === 'darwin';
  try {
    return {
      isMac,
      dark: isMac && systemPreferences.isDarkMode(),
      // '#rrggbb' 形式；跟随用户在「系统设置 → 外观 → 强调色」的选择
      accent: isMac ? systemPreferences.getAccentColor() : '',
    };
  } catch { return { isMac, dark: false, accent: '' }; }
}

contextBridge.exposeInMainWorld('settingsTheme', readSystemTheme());

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

  // 自定义形象图：列状态 / 选图上传 / 恢复默认
  listCustomSprites: () => ipcRenderer.invoke('settings:list-custom-sprite'),
  pickCustomSprite: (state) => ipcRenderer.invoke('settings:pick-custom-sprite', state),
  clearCustomSprite: (state) => ipcRenderer.invoke('settings:clear-custom-sprite', state),

  // 通用设置：宠物大小 / 开机自启 / 检查更新
  setPetScale: (scale) => ipcRenderer.invoke('settings:set-pet-scale', scale),
  setAutoLaunch: (enabled) => ipcRenderer.invoke('settings:set-auto-launch', enabled),
  checkUpdate: () => ipcRenderer.invoke('settings:check-update'),

  close: () => ipcRenderer.send('settings:close'),
});
