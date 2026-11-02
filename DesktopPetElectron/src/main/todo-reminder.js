// src/main/todo-reminder.js
// Todo 到期提醒调度（对标 mac 版 PetViewModel.startTodoReminderLoop / checkTodoReminders）
// 逻辑：每 30 秒扫一遍待办，命中「已到期且（从未提醒过 或 距上次提醒已满重复间隔）」的第一条 →
//       标记已触达 + 弹常驻提醒卡，直到用户删除该条才停止骚扰。
// 扫描与触达解耦（pickDueTodo / fire 都是纯函数依赖注入），便于 node 直跑单测。
'use strict';

// 到期检查周期（秒）：与 mac 版 todoCheckSeconds 一致
const CHECK_INTERVAL_MS = 30 * 1000;
// 同一条到期后重复提醒的默认间隔（分钟）
const DEFAULT_REPEAT_MINUTES = 5;
const MIN_REPEAT_MINUTES = 1;
const MAX_REPEAT_MINUTES = 240;

/** 重复提醒间隔收敛到 1~240 分钟，脏数据回落默认 5 分钟（对齐 mac 版 setter） */
function clampRepeatMinutes(value) {
  const n = parseInt(value, 10);
  if (!Number.isInteger(n) || n < MIN_REPEAT_MINUTES) return DEFAULT_REPEAT_MINUTES;
  return Math.min(n, MAX_REPEAT_MINUTES);
}

/**
 * 挑出本次要提醒的待办：已到期且（未提醒过 或 距上次提醒超过重复间隔）的第一条。
 * @param {Array<{due:number|null,lastNotifiedAt:number|null}>} items due 为 epoch 秒，lastNotifiedAt 为 epoch 毫秒
 * @param {number} nowMs 当前时间（epoch 毫秒）
 * @param {number} repeatMs 重复提醒间隔（毫秒）
 * @returns {object|null}
 */
function pickDueTodo(items, nowMs, repeatMs) {
  const list = Array.isArray(items) ? items : [];
  return list.find((it) => {
    if (!it || !it.due || it.due * 1000 > nowMs) return false;
    if (it.lastNotifiedAt) return nowMs - it.lastNotifiedAt >= repeatMs;
    return true;
  }) || null;
}

/** 提醒时间文案（对齐 mac 版 showTodoReminderAlert 的「约定时间 M月d日 HH:mm」） */
function formatDueLabel(dueSec) {
  const n = Number(dueSec);
  if (!Number.isFinite(n) || n <= 0) return '';
  const d = new Date(n * 1000);
  const pad = (v) => String(v).padStart(2, '0');
  return `${d.getMonth() + 1}月${d.getDate()}日 ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/**
 * 创建到期扫描循环。
 * @param {object} deps
 * @param {() => Array} deps.load 读当前待办
 * @param {(id: string, atMs: number) => void} deps.markNotified 标记已触达
 * @param {(item: object) => void} deps.fire 触达提醒（弹卡 + 宠物动画）
 * @param {() => number} [deps.getRepeatMinutes] 重复提醒间隔（分钟）
 * @param {Function} [deps.setTimer] 可注入定时器（单测用）
 * @param {Function} [deps.clearTimer] 可注入取消定时器（单测用）
 * @returns {{start: () => void, stop: () => void, checkNow: (nowMs?: number) => object|null}}
 */
function createTodoReminderLoop({ load, markNotified, fire, getRepeatMinutes, setTimer = setInterval, clearTimer = clearInterval }) {
  let timer = null;

  const stop = () => {
    if (timer) {
      clearTimer(timer);
      timer = null;
    }
  };

  const checkNow = (nowMs = Date.now()) => {
    const repeatMs = clampRepeatMinutes(getRepeatMinutes ? getRepeatMinutes() : DEFAULT_REPEAT_MINUTES) * 60 * 1000;
    const hit = pickDueTodo(load ? load() : [], nowMs, repeatMs);
    if (!hit) return null;
    // 先落「已触达」再弹卡：即使弹卡抛错也不会下一轮又弹同一条
    if (markNotified) markNotified(hit.id, nowMs);
    console.log(`[todo-reminder] 到期提醒: 「${hit.text}」`);
    if (fire) fire(hit);
    return hit;
  };

  return {
    start() {
      stop();
      timer = setTimer(checkNow, CHECK_INTERVAL_MS);
      if (timer && typeof timer.unref === 'function') timer.unref();
    },
    stop,
    checkNow,
  };
}

module.exports = {
  createTodoReminderLoop,
  pickDueTodo,
  clampRepeatMinutes,
  formatDueLabel,
  CHECK_INTERVAL_MS,
  DEFAULT_REPEAT_MINUTES,
  MIN_REPEAT_MINUTES,
  MAX_REPEAT_MINUTES,
};
