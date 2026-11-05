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

  // 菜单设置：宠物右键菜单项展示开关（主进程写盘，下次弹菜单即应用）
  setMenuItem: (key, visible) => ipcRenderer.invoke('settings:set-menu-item', { key, visible }),

  // 提醒设置：主动搭话开关、间隔与搭话内容（主进程校验并立即重挂周期定时器）
  setProactiveChat: (patch) => ipcRenderer.invoke('settings:set-proactive-chat', patch),
  // 「说一句」：不等周期定时器，主进程立刻跑一轮搭话（chatNow → 头顶气泡）
  testChat: () => ipcRenderer.invoke('settings:test-chat'),

  // 宠物信息：名称 / 形象
  setPetName: (name) => ipcRenderer.invoke('settings:set-pet-name', name),
  setPetState: (state) => ipcRenderer.invoke('settings:set-pet-state', state),
  // 主进程状态机改掉形象时回推（贴边躲藏 / 专注跟随 / 右键抚摸），面板的「当前状态」跟着实时更新
  onPetState: (callback) => {
    ipcRenderer.on('settings:pet-state', (event, payload) => callback(payload));
  },

  // 自定义形象图：列状态 / 选图上传 / 恢复默认
  listCustomSprites: () => ipcRenderer.invoke('settings:list-custom-sprite'),
  pickCustomSprite: (state) => ipcRenderer.invoke('settings:pick-custom-sprite', state),
  clearCustomSprite: (state) => ipcRenderer.invoke('settings:clear-custom-sprite', state),

  // 自定义状态图片（对标 mac 版 PetImageService + 历史图片窗）：
  // 网络与落盘都在主进程，面板只拿快照画配额/可用性，拿 ok+error 画结果
  petImageRefresh: () => ipcRenderer.invoke('pet-image:refresh'),
  petImageGenerateAll: () => ipcRenderer.invoke('pet-image:generate-all'),
  petImageOpenHistory: (state) => ipcRenderer.invoke('pet-image:open-history', { state }),
  // 生成阶段文案 / 配额 / 本机图片变化时主进程推整包快照（历史窗开着时随带列表数据）
  onPetImages: (callback) => {
    ipcRenderer.on('settings:pet-images', (event, snapshot) => callback(snapshot));
  },

  // 通用设置：宠物大小 / 开机自启 / 检查更新
  setPetScale: (scale) => ipcRenderer.invoke('settings:set-pet-scale', scale),
  setAutoLaunch: (enabled) => ipcRenderer.invoke('settings:set-auto-launch', enabled),
  checkUpdate: () => ipcRenderer.invoke('settings:check-update'),

  // 权限（校验码解锁）：解锁/清除都在主进程，面板只拿结果码回填提示
  unlockAccess: (code) => ipcRenderer.invoke('settings:unlock-access', code),
  clearAccess: () => ipcRenderer.invoke('settings:clear-access'),
  // 通用复制：渲染层写不了系统剪贴板，统一走主进程（微信号等）
  copyText: (text) => ipcRenderer.invoke('settings:copy-text', { text }),
  // 定时复核收回权限时主进程主动推一次（面板开着才能收到；下次打开走 load 兜底）
  onAccessChanged: (callback) => {
    ipcRenderer.on('settings:access-changed', (event, state) => callback(state));
  },

  // 每日天气提醒：写配置 + 预览（未解锁时主进程拒改/拒推）
  setWeatherReminder: (patch) => ipcRenderer.invoke('settings:set-weather-reminder', patch),
  previewWeather: () => ipcRenderer.invoke('settings:preview-weather'),

  // 好友消息：一次拉齐宠物号/好友/申请，以及加好友、同意/拒绝、删除、开会话窗
  // 网络调用全在主进程（加密信封 + 服务端文案），渲染层只判 ok 并展示 error
  socialSync: () => ipcRenderer.invoke('social:sync'),
  socialCopyPetNo: () => ipcRenderer.invoke('social:copy-pet-no'),
  socialAdd: (petNo) => ipcRenderer.invoke('social:add', { petNo }),
  socialDecide: (action, fromPetNo) => ipcRenderer.invoke('social:decide', { action, fromPetNo }),
  socialRemove: (petNo) => ipcRenderer.invoke('social:remove', { petNo }),
  socialOpenChat: (petNo, display) => ipcRenderer.invoke('social:open-chat', { petNo, display }),
  // 心跳拿到/刷新了宠物号时主进程推一次（面板开着才能收到；下次打开走 load 兜底）
  onPetNo: (callback) => {
    ipcRenderer.on('settings:pet-no', (event, payload) => callback(payload));
  },
  // 在申请卡上同意了申请：主进程直接把最新好友列表推回来，面板不必再跑一次网络
  onSocialChanged: (callback) => {
    ipcRenderer.on('settings:social-changed', (event, payload) => callback(payload));
  },

  close: () => ipcRenderer.send('settings:close'),
});
