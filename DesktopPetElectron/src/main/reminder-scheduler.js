// src/main/reminder-scheduler.js
// 喝水提醒调度器（移植自 PetViewModel.startDrinkWaterReminder / triggerDrinkWaterReminder）
// 逻辑：先对齐到「能被间隔整除的分钟点」触发第一次，之后按固定间隔重复；
//       弹窗未关闭（isShowing）时跳过本次触发，避免叠加。
'use strict';

// 喝水提醒间隔的合法区间（对齐 mac 版 PetViewModel.reminderInterval setter：1~120 分钟）
const MIN_INTERVAL = 1;
const MAX_INTERVAL = 120;
const DEFAULT_INTERVAL = 30;

/**
 * 把任意输入收敛成合法间隔（分钟）。
 * 非法 / 越界输入不报错，直接回落到默认值或边界（持久化里的脏数据也能安全读取）。
 * @param {*} value
 * @param {number} [fallback] 非法时的回落值
 * @returns {number}
 */
function clampInterval(value, fallback = DEFAULT_INTERVAL) {
  const n = parseInt(value, 10);
  if (!Number.isInteger(n) || n < MIN_INTERVAL) return fallback;
  return Math.min(n, MAX_INTERVAL);
}

/** 严格校验用户输入：只能是通过校验的正整数，用于设置面板给出提示 */
function isValidInterval(value) {
  const n = Number(value);
  return Number.isInteger(n) && n >= MIN_INTERVAL && n <= MAX_INTERVAL;
}

class ReminderScheduler {
  /**
   * @param {object} opts
   * @param {() => number} opts.getIntervalMinutes  返回当前间隔（分钟）
   * @param {(event: string) => void} opts.send     向渲染进程发送事件
   */
  constructor({ getIntervalMinutes, send }) {
    this.getIntervalMinutes = getIntervalMinutes;
    this.send = send;
    this.firstTimer = null;
    this.repeatTimer = null;
    this.isShowing = false; // 对标 isWaterAlertShowing
  }

  // 距离下一个对齐触发点的毫秒数
  _msUntilNextTrigger(intervalMin, now = new Date()) {
    const minute = now.getMinutes();
    const second = now.getSeconds();
    const ms = now.getMilliseconds();
    const remainder = minute % intervalMin;

    let deltaMinutes;
    if (remainder === 0 && second === 0 && ms === 0) {
      deltaMinutes = intervalMin;            // 正好在触发点，推到下一格
    } else if (remainder === 0) {
      deltaMinutes = 0;                      // 在当前间隔内，本整点触发
    } else {
      deltaMinutes = intervalMin - remainder; // 等到下一个整点
    }

    let delaySec = deltaMinutes * 60 - second - ms / 1000;
    if (delaySec <= 0) delaySec = intervalMin * 60;
    return delaySec * 1000;
  }

  start() {
    this.stop();
    const intervalMin = this._clamp(this.getIntervalMinutes());
    const intervalMs = intervalMin * 60 * 1000;
    const delay = this._msUntilNextTrigger(intervalMin);

    console.log(`[reminder] start: interval=${intervalMin}min, first fire in ${Math.round(delay / 1000)}s`);
    this.firstTimer = setTimeout(() => {
      this._fire();
      this.repeatTimer = setInterval(() => this._fire(), intervalMs);
    }, delay);
  }

  stop() {
    if (this.firstTimer) { clearTimeout(this.firstTimer); this.firstTimer = null; }
    if (this.repeatTimer) { clearInterval(this.repeatTimer); this.repeatTimer = null; }
  }

  // 修改间隔后重启
  restart() {
    this.start();
  }

  _fire() {
    if (this.isShowing) {
      console.log('[reminder] fire skipped: alert already showing');
      return;
    }
    this.isShowing = true;
    console.log('[reminder] fire drink-water');
    this.send('drink-water:show');
  }

  // 渲染层关闭弹窗后回调，解除"正在显示"标记
  dismiss() {
    this.isShowing = false;
  }

  // 立即触发一次（测试用）
  triggerNow() {
    this._fire();
  }

  _clamp(v) {
    return clampInterval(v);
  }
}

module.exports = {
  ReminderScheduler,
  clampInterval,
  isValidInterval,
  MIN_INTERVAL,
  MAX_INTERVAL,
  DEFAULT_INTERVAL,
};
