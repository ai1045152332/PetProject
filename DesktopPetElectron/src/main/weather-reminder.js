// src/main/weather-reminder.js
// DesktopPetElectron — 每日天气提醒调度（移植 mac 版 Services/WeatherReminderService.swift 的调度部分）
// 每天在用户选的 时:分 触发一次：取天气 → 弹天气卡。
// 与 mac 版一致的两条守卫：
//   1) 睡眠补偿校验：一次性定时器在系统睡眠期间会逾期补发，逾期超过宽限（2 小时）直接跳过，
//      避免睡几天醒来在午后弹上午的天气提醒；
//   2) 基础权限跳过：天气接口按量付费，仅校验码解锁后推送（配置里开着也不会提醒，对齐 Swift handleFire）。
'use strict';

const FIRE_GRACE_MS = 2 * 60 * 60 * 1000; // 逾期宽限（与 mac 版 fireGraceInterval = 2h 一致）
const DAY_MS = 24 * 60 * 60 * 1000;

/** 今天 hour:minute 对应的毫秒时间戳（已过今天时间则顺延到明天），与 nextTime 语义一致 */
function nextFireMs(nowMs, hour, minute) {
  const d = new Date(nowMs);
  const target = new Date(d.getFullYear(), d.getMonth(), d.getDate(), hour, minute, 0, 0);
  if (target.getTime() > nowMs) return target.getTime();
  return target.getTime() + DAY_MS;
}

/**
 * @param {object} deps
 * @param {() => boolean} deps.isEnabled 提醒开关
 * @param {() => number} deps.getHour / deps.getMinute 提醒时间
 * @param {() => boolean} [deps.isFullAccess] 权限守卫（默认放行）
 * @param {() => void} deps.fire 实际推送（主进程注入：查天气 + 开天气窗）
 * @param {Function} [deps.setTimer] / [deps.clearTimer] 可注入定时器（单测用）
 * @returns {{start: () => void, reschedule: () => void, stop: () => void}}
 */
function createWeatherReminder({
  isEnabled,
  getHour,
  getMinute,
  isFullAccess = () => true,
  fire,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
}) {
  let timer = null;
  let targetMs = 0;

  function schedule() {
    if (!isEnabled()) return;
    const hour = clampPart(getHour(), 23, 8);
    const minute = clampPart(getMinute(), 59, 0);
    targetMs = nextFireMs(Date.now(), hour, minute);
    timer = setTimer(onFire, Math.max(1000, targetMs - Date.now()));
    console.log(`[weather-reminder] 已安排下次提醒 ${new Date(targetMs).toLocaleString('zh-CN')}`);
  }

  function onFire() {
    timer = null;
    // 先算逾期再排下一次：schedule 会覆盖 targetMs，放在后面会把逾期算成负数
    const overdueMs = Date.now() - targetMs;
    // 无论本次结果如何都先排下一次（对齐 Swift handleFire 的 defer scheduleNext）
    schedule();
    if (overdueMs > FIRE_GRACE_MS) {
      console.log(`[weather-reminder] 本次触发逾期 ${Math.round(overdueMs / 60000)}min（多为睡眠期间积压），跳过提醒`);
      return;
    }
    if (!isFullAccess()) {
      console.log('[weather-reminder] 当前为基础权限，跳过天气提醒');
      return;
    }
    fire();
  }

  return {
    start() {
      if (!timer) schedule();
    },
    /** 配置（开关 / 时间）变化后重排 */
    reschedule() {
      if (timer) clearTimer(timer);
      timer = null;
      schedule();
    },
    stop() {
      if (timer) clearTimer(timer);
      timer = null;
    },
  };
}

/** 时间分量收敛：脏数据回落默认（时 8 / 分 0，与 mac 版 defaultHour/defaultMinute 一致） */
function clampPart(value, max, fallback) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < 0 || n > max) return fallback;
  return n;
}

/** 展示用时间文本（形如 08:00，对齐 Swift timeText） */
function timeText(hour, minute) {
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

module.exports = { createWeatherReminder, nextFireMs, timeText, FIRE_GRACE_MS };
