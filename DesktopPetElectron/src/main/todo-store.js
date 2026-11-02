// src/main/todo-store.js
// 本地待办事项存储：落 userData/pet-todos.json（对标 mac 版 TodoManager 的 UserDefaults 持久化）
// 字段对齐 TodoItem：id / text / due（到点提醒时间，epoch 秒，null=只随手记不设提醒）
//                     / lastNotifiedAt（上次到期触达时间，epoch 毫秒，用于「按间隔重复提醒直到删除」）
// 与窗口 / IPC 解耦，纯文件操作便于单测（tests 里 mock app.getPath 到临时目录）。
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { app } = require('electron');

// 单条待办的文本上限：够写一句话，又能挡住误粘贴的长文本把文件撑爆
const MAX_TEXT = 200;

function storePath() {
  return path.join(app.getPath('userData'), 'pet-todos.json');
}

/** 提醒时间归一化：接受 epoch 秒（数字或数字串），无效/空值一律当作「不设提醒」 */
function normalizeDue(value) {
  if (value == null || value === '' || value === false) return null;
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  return Math.round(n);
}

/** 单条记录归一化：脏数据（缺字段 / 类型不对）直接丢弃，避免渲染层拿到 undefined 崩掉 */
function normalizeItem(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const text = String(raw.text == null ? '' : raw.text).trim();
  const id = String(raw.id == null ? '' : raw.id);
  if (!id || !text) return null;
  const due = normalizeDue(raw.due);
  const last = Number(raw.lastNotifiedAt);
  return {
    id,
    text: text.slice(0, MAX_TEXT),
    due,
    lastNotifiedAt: Number.isFinite(last) && last > 0 ? last : null,
  };
}

/** 读全量待办（文件不存在 / 被写坏都回空数组，保证启动不受影响） */
function load() {
  try {
    const raw = fs.readFileSync(storePath(), 'utf8');
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.map(normalizeItem).filter(Boolean);
  } catch (e) {
    return [];
  }
}

function save(items) {
  try {
    fs.mkdirSync(path.dirname(storePath()), { recursive: true });
    fs.writeFileSync(storePath(), JSON.stringify(items, null, 2), 'utf8');
    return true;
  } catch (e) {
    console.error('[todo-store] save failed:', e.message);
    return false;
  }
}

/**
 * 新增一条待办（对标 TodoManager.add）。
 * @param {string} text 待办内容
 * @param {number|string|null} [due] 到点提醒时间（epoch 秒），null=不设提醒
 * @returns {{ok: true, item: object} | {ok: false, error: string}}
 */
function add(text, due = null) {
  const value = String(text == null ? '' : text).trim();
  if (!value) return { ok: false, error: '待办内容不能为空' };
  if (value.length > MAX_TEXT) return { ok: false, error: `待办最多 ${MAX_TEXT} 个字符` };

  const items = load();
  const item = {
    id: crypto.randomUUID(),
    text: value.slice(0, MAX_TEXT),
    due: normalizeDue(due),
    lastNotifiedAt: null,
  };
  items.push(item);
  if (!save(items)) return { ok: false, error: '保存失败' };
  return { ok: true, item };
}

/**
 * 删除一条待办（对标 TodoManager.delete）。不存在也视为成功（渲染层本就按整表重绘）。
 * @param {string} id
 */
function remove(id) {
  const items = load();
  const next = items.filter((it) => it.id !== String(id));
  if (next.length === items.length) return { ok: true, removed: false };
  return { ok: save(next), removed: true };
}

/**
 * 标记某条待办的到期提醒已触达（对标 TodoManager.markNotified），用于按间隔重复提醒。
 * @param {string} id
 * @param {number} [atMs] 触达时间（epoch 毫秒）
 */
function markNotified(id, atMs = Date.now()) {
  const items = load();
  const hit = items.find((it) => it.id === String(id));
  if (!hit) return false;
  hit.lastNotifiedAt = atMs;
  return save(items);
}

module.exports = { load, save, add, remove, markNotified, normalizeDue, MAX_TEXT, storePath };
