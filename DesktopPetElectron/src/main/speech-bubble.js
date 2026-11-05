// src/main/speech-bubble.js
// 宠物头顶的对话气泡窗（对标 mac 版 FloatingWindow.showFeedBubble / repositionSpeechBubble / dismissSpeechBubble）
// 所有「小猫说话」的台词都从这里出：弹入 → 悬浮 hold 秒 → 淡出关闭，期间跟随宠物窗移动。
// 与 mac 版的差异只在实现手段：
//   · 悬浮期的轻微上下浮动交给渲染层 CSS 动画，主进程不做逐帧 setPosition（省掉 30fps 的定时器）
//   · 气泡尺寸由渲染层量完文字后回报（mac 版由 SpeechBubbleView 直接给出 frame.size）
//   · 停留时长沿用 mac 版 catSay 的规则：按文案长度自适应，4s ～ 18s
// 单例复用：同一时刻只有一颗气泡，新台词直接换掉旧内容并重置计时。
'use strict';

const path = require('path');
const { BrowserWindow, screen } = require('electron');

const MAX_WIDTH = 240;      // 气泡最大宽度（对齐 mac 版矢量模式：180 文字区 + 左右各 18 内边距 + 描边）
const FALLBACK_HEIGHT = 96; // 渲染层还没回报尺寸时的兜底盒高
const FOLLOW_INTERVAL = 120; // 跟随宠物窗的轮询间隔（ms）：拖动时气泡同步挪动
const FADE_MS = 1000;       // 淡出时长（mac 版 catSay 传 fade: 1.0）

/** 停留时长按文案长度自适应（对齐 Swift：min(18, max(4, 字数 * 0.6)) 秒） */
function holdMsFor(text) {
  const len = String(text || '').length;
  return Math.round(Math.min(18, Math.max(4, len * 0.6)) * 1000);
}

/**
 * 把气泡夹在宠物所在显示器的工作区内（不让它探出屏幕或顶进菜单栏/任务栏）。
 * @param {{x:number,y:number,width:number,height:number}} bounds 气泡当前位置与尺寸
 * @param {Electron.Rectangle} area 工作区
 */
function clampToBounds(bounds, area) {
  const x = Math.min(
    Math.max(bounds.x, area.x + 4),
    Math.max(area.x + 4, area.x + area.width - bounds.width - 4),
  );
  const y = Math.min(Math.max(bounds.y, area.y + 4), area.y + area.height - bounds.height);
  return { x, y, width: bounds.width, height: bounds.height };
}

/**
 * 创建气泡管理器。
 * @param {object} deps
 * @param {() => Electron.BrowserWindow|null} deps.getPetWindow 宠物窗（用于定位与「猫没显示就不冒泡」）
 * @param {Function} [deps.setSize] 可注入「按内容算尺寸」以便单测（默认直接采用渲染层回报值）
 * @param {Function} [deps.setTimer] 可注入定时器（单测用）
 * @param {Function} [deps.clearTimer] 可注入取消定时器（单测用）
 */
function createSpeechBubble(deps = {}) {
  let win = null;
  let followTimer = null;
  let hideTimer = null;
  let fadeTimer = null;
  let lastSize = { width: MAX_WIDTH, height: FALLBACK_HEIGHT };
  let currentText = '';

  /** 悬浮期间跟着宠物窗挪位置（mac 版 startSpeechBubbleFollow） */
  function reposition() {
    if (!win || win.isDestroyed()) return;
    const pet = deps.getPetWindow && deps.getPetWindow();
    if (!pet || pet.isDestroyed() || !pet.isVisible()) return;
    const petBounds = pet.getBounds();
    const size = win.getSize();
    // 水平居中于宠物头顶，尾巴尖轻搭猫头（mac 版：y = catFrame.maxY - 4，屏幕坐标相反故取 top - h - 4）
    const desired = {
      x: Math.round(petBounds.x + petBounds.width / 2 - size[0] / 2),
      y: petBounds.y - size[1] - 4,
      width: size[0],
      height: size[1],
    };
    const area = screen.getDisplayMatching(petBounds).workArea;
    win.setBounds(clampToBounds(desired, area));
  }

  function startFollow() {
    if (followTimer) return;
    followTimer = setInterval(reposition, FOLLOW_INTERVAL);
    if (typeof followTimer.unref === 'function') followTimer.unref();
  }

  function stopFollow() {
    if (followTimer) clearInterval(followTimer);
    followTimer = null;
  }

  /** 立即收起气泡（不淡出）：宠物隐藏 / 退出时用 */
  function dismiss() {
    const clear = deps.clearTimer || clearTimeout;
    if (hideTimer) clear(hideTimer);
    if (fadeTimer) clear(fadeTimer);
    hideTimer = fadeTimer = null;
    stopFollow();
    if (win && !win.isDestroyed()) win.close();
    win = null;
    currentText = '';
  }

  /** 淡出后关闭：渲染层加 .leave 播过渡动画，主进程等动画时长再 close */
  function fadeOutAndClose(fadeMs = FADE_MS) {
    if (!win || win.isDestroyed()) return;
    const clear = deps.clearTimer || clearTimeout;
    if (hideTimer) {
      clear(hideTimer);
      hideTimer = null;
    }
    stopFollow();
    win.webContents.send('bubble:leave');
    const setT = deps.setTimer || setTimeout;
    fadeTimer = setT(() => {
      fadeTimer = null;
      if (win && !win.isDestroyed()) win.close();
      win = null;
      currentText = '';
    }, fadeMs);
  }

  /** 按当前文本长度算停留时长并重新计时（新台词会重置上一句的隐藏定时器） */
  function scheduleHide(text) {
    const clear = deps.clearTimer || clearTimeout;
    const setT = deps.setTimer || setTimeout;
    if (hideTimer) clear(hideTimer);
    hideTimer = setT(() => {
      hideTimer = null;
      fadeOutAndClose();
    }, holdMsFor(text));
  }

  function ensureWindow() {
    if (win && !win.isDestroyed()) return win;
    win = new BrowserWindow({
      width: lastSize.width,
      height: lastSize.height,
      frame: false,
      transparent: true,
      backgroundColor: '#00000000',
      // 气泡要压过宠物窗本体：mac 版用 popUpMenu + 1，这里同层级再抬一级
      alwaysOnTop: true,
      resizable: false,
      movable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      skipTaskbar: true,
      hasShadow: false,
      focusable: false, // 冒泡不该抢焦点（否则用户正在输入的框会掉焦点）
      show: false,
      title: '宠物说',
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        preload: path.join(__dirname, '..', 'renderer', 'bubble-preload.js'),
      },
    });
    if (process.platform === 'win32') win.setAlwaysOnTop(true, 'screen-saver', 2);
    else win.setAlwaysOnTop(true, 'screen-saver');
    win.loadFile(path.join(__dirname, '..', 'renderer', 'bubble.html'));
    win.on('closed', () => {
      win = null;
      stopFollow();
    });
    return win;
  }

  return {
    /**
     * 宠物说一句气泡（对标 mac 版 catSay）。
     * 宠物窗没显示时不冒泡：气泡浮在一只在屏外的猫头顶没有意义。
     * @param {string} text 台词
     * @returns {boolean} 是否真的展示了
     */
    say(text) {
      const content = String(text || '').trim();
      if (!content) return false;
      const pet = deps.getPetWindow && deps.getPetWindow();
      if (!pet || pet.isDestroyed() || !pet.isVisible()) return false;

      currentText = content;
      const w = ensureWindow();
      // 先把新文本推给已加载完的渲染层；还没加载完时由渲染层主动 invoke 拉 __bubbleText
      w.__bubbleText = content;
      w.webContents.send('bubble:update', content);
      reposition();
      // 窗口不先行显形：等渲染层量完文字回 reportSize（handleResize）再定位到头顶并 show，
      // 否则会看到一帧未贴合文字尺寸的白框
      scheduleHide(content);
      return true;
    },

    /** 渲染层回报内容尺寸：改盒大小 + 定位到头顶 + 显形 + 开始跟随 */
    handleResize(width, height) {
      if (!win || win.isDestroyed()) return;
      const w = Math.max(120, Math.min(MAX_WIDTH, Math.round(Number(width) || MAX_WIDTH)));
      const h = Math.max(40, Math.round(Number(height) || FALLBACK_HEIGHT));
      lastSize = { width: w, height: h };
      win.setContentSize(w, h);
      reposition();
      if (!win.isVisible()) win.showInactive();
      startFollow();
    },

    /** 当前台词（测试 / 状态查询用） */
    currentText: () => currentText,

    isVisible() {
      return Boolean(win && !win.isDestroyed() && win.isVisible());
    },

    getWindow() {
      return win && !win.isDestroyed() ? win : null;
    },

    dismiss,

    /** 用户点掉气泡 / 台词自然结束：播淡出动画后收起（区别于 dismiss 的立即关闭） */
    fadeOut: fadeOutAndClose,

    /** 退出前收尾：取消所有定时器（窗口由 app 统一销毁） */
    stop() {
      dismiss();
    },
  };
}

module.exports = { createSpeechBubble, holdMsFor, clampToBounds, MAX_WIDTH };
