// src/renderer/todo.js — Todo 清单渲染层（移植自 mac 版 HTMLAlertWindow.showTodo 的页面脚本）
// 数据单向：所有增删都走 IPC 交给主进程落盘，主进程回灌最新全量列表后重绘，渲染层不自己改状态
'use strict';

let items = [];
let pendingDeleteId = null;   // 处于「再点一次确认删除」态的待办 id
let pendingDue = null;        // 待添加待办的提醒时间（epoch 秒），null = 不提醒
let pickDay = 0, pickHour = 9, pickMin = 0; // 弹层内临时选择

const WD = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

const pad = (n) => (n < 10 ? '0' : '') + n;

/** 提醒时间文案：今天 / 明天 / M/D + HH:mm */
function fmtDue(sec) {
  if (!sec) return '';
  const d = new Date(sec * 1000);
  const now = new Date();
  const hm = pad(d.getHours()) + ':' + pad(d.getMinutes());
  if (d.toDateString() === now.toDateString()) return '今天 ' + hm;
  const tomorrow = new Date(now);
  tomorrow.setDate(now.getDate() + 1);
  if (d.toDateString() === tomorrow.toDateString()) return '明天 ' + hm;
  return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + hm;
}

function isOverdue(sec) {
  return Boolean(sec) && sec * 1000 < Date.now();
}

function dayLabel(off) {
  if (off === 0) return '今天';
  if (off === 1) return '明天';
  if (off === 2) return '后天';
  const d = new Date();
  d.setDate(d.getDate() + off);
  return WD[d.getDay()];
}

// ── 列表渲染 ──
function renderTodos() {
  const list = document.getElementById('todoList');
  list.innerHTML = '';
  if (!items.length) {
    const empty = document.createElement('div');
    empty.className = 'todo-empty';
    empty.textContent = '暂无待办事项 🎉';
    list.appendChild(empty);
    return;
  }
  // 有到期时间的按时间升序排在前（逾期自然置顶），无时间的保持原序在后
  const sorted = items.slice().sort((a, b) => (a.due || Infinity) - (b.due || Infinity));
  for (const t of sorted) {
    const isPending = t.id === pendingDeleteId;
    const overdue = isOverdue(t.due);

    const item = document.createElement('div');
    item.className = 'todo-item'
      + (isPending ? ' todo-item-confirm' : overdue ? ' todo-item-overdue' : '');

    const dot = document.createElement('span');
    dot.className = 'todo-dot';
    dot.textContent = isPending ? '⚠️' : overdue ? '🔴' : '●';
    dot.addEventListener('click', () => copyTodo(t.text));

    const txt = document.createElement('span');
    txt.className = 'todo-text';
    txt.textContent = isPending ? '再次点击确认删除' : t.text;
    txt.addEventListener('click', () => copyTodo(t.text));

    item.appendChild(dot);
    if (t.due) {
      const chip = document.createElement('span');
      chip.className = 'todo-chip' + (overdue ? ' todo-chip-overdue' : '');
      chip.textContent = (overdue ? '⏰ 已逾期 · ' : '⏰ ') + fmtDue(t.due);
      item.appendChild(chip);
    }
    item.appendChild(txt);

    const del = document.createElement('span');
    del.className = 'todo-delete';
    del.textContent = isPending ? '删除' : '✕';
    del.addEventListener('click', () => deleteTodo(t.id));
    item.appendChild(del);

    list.appendChild(item);
  }
}

function render(items_) {
  if (Array.isArray(items_)) items = items_;
  renderTodos();
}

// ── 提醒时间按钮 / 弹层 ──
function updateRemindChip() {
  const btn = document.getElementById('remindBtn');
  if (pendingDue) {
    btn.textContent = '⏰ ' + fmtDue(pendingDue);
    btn.classList.add('remind-on');
  } else {
    btn.textContent = '🕐 无提醒';
    btn.classList.remove('remind-on');
  }
}

function pickerEl() {
  return document.getElementById('duePicker');
}

/** open 传 undefined 时切换显隐（点「🕐」的行为） */
function togglePicker(open) {
  const p = pickerEl();
  const willOpen = open === undefined ? !p.classList.contains('open') : open;
  if (willOpen) {
    renderPicker();
    p.classList.add('open');
  } else {
    p.classList.remove('open');
  }
}

function renderPicker() {
  fillSelect('dpDate', 7, pickDay, dayLabel);
  fillSelect('dpHour', 24, pickHour, (h) => pad(h) + '点');
  fillSelect('dpMin', 60, pickMin, (m) => pad(m) + '分');
  updatePreview();
}

function fillSelect(id, count, selected, label) {
  const el = document.getElementById(id);
  el.innerHTML = '';
  for (let i = 0; i < count; i++) {
    const opt = document.createElement('option');
    opt.value = i;
    opt.textContent = label(i);
    if (i === selected) opt.selected = true;
    el.appendChild(opt);
  }
}

/** 选择器 → Date（本地时区的今天/明天/后天 + 时分） */
function pickedDate() {
  const d = new Date();
  d.setDate(d.getDate() + pickDay);
  d.setHours(pickHour, pickMin, 0, 0);
  return d;
}

function updatePreview() {
  const el = document.getElementById('dpPreview');
  el.textContent = '将于 ' + fmtDue(pickedDate().getTime() / 1000) + ' 提醒';
}

function confirmPicker() {
  pendingDue = Math.floor(pickedDate().getTime() / 1000);
  updateRemindChip();
  togglePicker(false);
}

function quickSet(kind) {
  const d = new Date();
  if (kind === '15m') d.setMinutes(d.getMinutes() + 15);
  else if (kind === '30m') d.setMinutes(d.getMinutes() + 30);
  else if (kind === '1h') d.setHours(d.getHours() + 1);
  else if (kind === 'tonight') d.setHours(20, 0, 0, 0);
  else if (kind === 'tom9') { d.setDate(d.getDate() + 1); d.setHours(9, 0, 0, 0); }
  pendingDue = Math.floor(d.getTime() / 1000);
  updateRemindChip();
  togglePicker(false);
}

function clearReminder() {
  pendingDue = null;
  updateRemindChip();
  togglePicker(false);
}

// ── 增删 ──
async function addTodo() {
  const input = document.getElementById('todoInput');
  const text = input.value.trim();
  if (!text) return;
  if (!window.todoAPI) return;
  const res = await window.todoAPI.add(text, pendingDue);
  if (!res || !res.ok) {
    showTip(res && res.error ? res.error : '添加失败');
    return;
  }
  input.value = '';
  pendingDue = null;
  updateRemindChip();
  togglePicker(false);
  render(res.items);
  input.focus();
}

async function deleteTodo(id) {
  if (pendingDeleteId !== id) {
    // 首次点击只进入确认态，再点一次才真删（避免误触 ✕ 直接丢待办）
    pendingDeleteId = id;
    renderTodos();
    return;
  }
  pendingDeleteId = null;
  if (!window.todoAPI) return;
  const res = await window.todoAPI.remove(id);
  if (res && res.ok) render(res.items);
}

// ── 复制到剪贴板（点待办文本）──
async function copyTodo(text) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
    } else {
      throw new Error('clipboard unavailable');
    }
    showTip('已复制');
  } catch (e) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.className = 'copy-fallback';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); showTip('已复制'); } catch (err) { /* 复制失败不打断交互 */ }
    document.body.removeChild(ta);
  }
}

function showTip(text) {
  const tip = document.getElementById('copyTip');
  tip.textContent = text;
  tip.classList.add('show');
  setTimeout(() => tip.classList.remove('show'), 1000);
}

// ── 事件接线 ──
document.getElementById('addBtn').addEventListener('click', addTodo);
document.getElementById('remindBtn').addEventListener('click', () => togglePicker());
document.getElementById('dpOk').addEventListener('click', confirmPicker);
document.getElementById('dpClear').addEventListener('click', clearReminder);
document.getElementById('close').addEventListener('click', () => {
  if (window.todoAPI) window.todoAPI.close();
});
document.getElementById('dpQuick').addEventListener('click', (e) => {
  const chip = e.target.closest('.dp-chip');
  if (chip && chip.getAttribute('data-q')) quickSet(chip.getAttribute('data-q'));
});
document.getElementById('dpDate').addEventListener('change', (e) => { pickDay = parseInt(e.target.value, 10); updatePreview(); });
document.getElementById('dpHour').addEventListener('change', (e) => { pickHour = parseInt(e.target.value, 10); updatePreview(); });
document.getElementById('dpMin').addEventListener('change', (e) => { pickMin = parseInt(e.target.value, 10); updatePreview(); });
document.getElementById('todoInput').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') addTodo();
});
document.getElementById('todoInput').addEventListener('focus', () => {
  pendingDeleteId = null;
  renderTodos();
  togglePicker(false);
});

// 主进程侧数据变化（到期标记 / 其它入口增删）→ 实时刷新
if (window.todoAPI && window.todoAPI.onList) {
  window.todoAPI.onList((list) => render(list));
}

// 首帧：主动拉一次，避免「主进程先 send、页面后挂监听」丢数据
if (window.todoAPI && window.todoAPI.fetchList) {
  window.todoAPI.fetchList().then(render).catch(() => render([]));
} else {
  render([]);
}
updateRemindChip();
document.getElementById('todoInput').focus();
