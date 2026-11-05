// src/renderer/pet-history.js
// 图片历史窗渲染层：把主进程推来的本机图片清单摊成缩略图网格，右侧看大图与做操作。
// 只做展示与交互编排，判定（谁属于哪个状态、能不能应用）全在主进程，避免两端各算一套。
'use strict';

const api = window.petHistoryAPI;

const $ = (id) => document.getElementById(id);
const grid = $('grid');
const filterBox = $('filter');
const targetSel = $('target');

let data = { states: [], stateLabels: {}, history: { items: [], failures: [] }, busy: false };
let filterState = '';
let selectedKey = null;
/// 上一次渲染详情对应的 key：换图时才重置「应用目标」，同一张图刷新不打断用户选择
let lastDetailKey = null;

function labelOf(state) {
  return (data.stateLabels && data.stateLabels[state]) || state || '';
}

function history() {
  return data.history || { items: [], failures: [] };
}

/** 只列当前状态可用的图：直传图绑定该状态、AI 图按生成状态归类；未归属老图置底保留可达性 */
function filteredItems() {
  const items = history().items || [];
  const own = items.filter((i) => !i.isDirect && i.boundState === filterState);
  const direct = items.filter((i) => i.isDirect && i.boundState === filterState);
  const unassigned = items.filter((i) => !i.isDirect && !i.boundState);
  return [...direct, ...own, ...unassigned];
}

function filteredFailures() {
  return (history().failures || []).filter((f) => f.state === filterState);
}

// ── 顶部筛选条 ──────────────────────────────
function renderFilter() {
  filterBox.textContent = '';
  for (const item of data.states || []) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'seg' + (item.id === filterState ? ' selected' : '');
    btn.textContent = item.label;
    btn.title = '查看某个状态的可用图片；直接上传只属于它的状态，AI 图可应用到任意状态';
    btn.addEventListener('click', () => switchFilter(item.id));
    filterBox.append(btn);
  }
}

/** 切筛选：应用目标跟着切到当前状态，切完即点「应用」不会落到上一个状态 */
function switchFilter(state) {
  filterState = state;
  targetSel.value = state;
  selectedKey = null;
  lastDetailKey = null;
  render();
}

// ── 目标状态下拉 ────────────────────────────
function renderTargets() {
  targetSel.textContent = '';
  for (const item of data.states || []) {
    const opt = document.createElement('option');
    opt.value = item.id;
    opt.textContent = item.label;
    targetSel.append(opt);
  }
  targetSel.value = filterState;
  targetSel.addEventListener('change', refreshDetail);
}

// ── 缩略图网格 ──────────────────────────────
function makeTile(key, title, subtitle, thumbUrl, placeholder) {
  const tile = document.createElement('div');
  tile.className = 'tile';
  tile.dataset.key = key;

  if (thumbUrl) {
    const img = document.createElement('img');
    img.className = 'thumb';
    img.alt = '';
    img.draggable = false;
    img.src = thumbUrl;
    tile.append(img);
  } else {
    const ph = document.createElement('div');
    ph.className = 'placeholder';
    ph.textContent = placeholder || '⚠️';
    tile.append(ph);
  }

  const t = document.createElement('div');
  t.className = 'tile-title';
  t.textContent = title;
  const s = document.createElement('div');
  s.className = 'tile-sub';
  s.textContent = subtitle;
  tile.append(t, s);

  // 单击选中看大图，双击直接应用（失败卡片双击 = 重试）
  tile.addEventListener('click', (event) => {
    select(key);
    if (event.detail >= 2) primary();
  });
  return tile;
}

function renderGrid() {
  const items = filteredItems();
  const failures = filteredFailures();
  grid.textContent = '';

  for (const item of items) {
    const mark = (item.selectedStates || []).length ? '✓ ' : '';
    grid.append(makeTile(item.key, mark + item.title, item.subtitle, item.url, ''));
  }
  for (const failure of failures) {
    grid.append(makeTile(
      `failure:${failure.state}`,
      `⚠ 失败 · ${failure.label}`,
      `${failure.timeText} · 点此重试`,
      '',
      '⚠️',
    ));
  }
  if (!items.length && !failures.length) {
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '这一栏暂时没有图片。\n用「直接上传」或「AI 生成」添加后，历史都会保存在本机。';
    grid.append(empty);
  }

  $('count').textContent = `${labelOf(filterState)} · ${items.length + failures.length} 张`;

  // 选中项跟着刷新：还在就用原来的，没了就默认选中当前状态正在生效的那张
  const keys = [...items.map((i) => i.key), ...failures.map((f) => `failure:${f.state}`)];
  if (!keys.includes(selectedKey)) {
    const active = items.find((i) => (i.selectedStates || []).includes(filterState));
    selectedKey = active ? active.key : (keys[0] || null);
  }
  for (const tile of grid.children) tile.classList.toggle('selected', tile.dataset.key === selectedKey);
  refreshDetail();
}

// ── 右侧详情 ────────────────────────────────
function selectedItem() {
  return (history().items || []).find((i) => i.key === selectedKey) || null;
}

function selectedFailure() {
  if (!selectedKey || !selectedKey.startsWith('failure:')) return null;
  const state = selectedKey.slice('failure:'.length);
  return (history().failures || []).find((f) => f.state === state) || null;
}

function refreshDetail() {
  const switched = selectedKey !== lastDetailKey;
  lastDetailKey = selectedKey;
  const preview = $('preview');
  const info = $('info');
  const applyBtn = $('applyBtn');
  const deleteBtn = $('deleteBtn');
  const revealBtn = $('revealBtn');
  const failure = selectedFailure();
  const busy = Boolean(data.busy);

  if (failure) {
    preview.classList.remove('shown');
    preview.removeAttribute('src');
    targetSel.disabled = true;
    applyBtn.textContent = '🔁 重试生成';
    applyBtn.disabled = busy;
    deleteBtn.textContent = '清除记录';
    deleteBtn.disabled = busy;
    revealBtn.disabled = true;
    info.textContent = [
      `${failure.label}状态生成失败`,
      failure.message,
      `时间：${failure.timeText}`,
      `任务：${failure.taskText}`,
      '生成本机没拿到图，可重试一次。',
    ].join('\n');
    return;
  }

  const item = selectedItem();
  if (!item) {
    preview.classList.remove('shown');
    preview.removeAttribute('src');
    targetSel.disabled = true;
    applyBtn.textContent = '应用';
    applyBtn.disabled = true;
    deleteBtn.textContent = '删除';
    deleteBtn.disabled = true;
    revealBtn.disabled = true;
    info.textContent = '这一栏暂时没有图片。\n用「直接上传」或「AI 生成」添加后，历史都会保存在本机。';
    return;
  }

  preview.src = item.url;
  preview.classList.add('shown');

  // 直传图只能回自己的状态；AI 图可应用到任意状态，默认先落到它的生成状态
  if (item.isDirect && item.boundState) {
    targetSel.value = item.boundState;
    targetSel.disabled = true;
    applyBtn.textContent = `应用到${labelOf(item.boundState)}`;
  } else {
    if (switched && item.boundState) targetSel.value = item.boundState;
    targetSel.disabled = busy;
    applyBtn.textContent = `应用到${labelOf(targetSel.value)}`;
  }
  applyBtn.disabled = busy;
  deleteBtn.textContent = '删除';
  deleteBtn.disabled = busy;
  revealBtn.disabled = false;

  const owner = item.boundState
    ? `${labelOf(item.boundState)}（${item.isDirect ? '只属于该状态' : '生成状态'}）`
    : '未归属（应用后自动归类）';
  const applied = (item.selectedStates || []).length
    ? `生效中：${(item.selectedStates || []).map(labelOf).join('、')}`
    : '未生效';
  info.textContent = [
    item.isDirect ? '直接上传' : 'AI 生成',
    `所属状态：${owner}`,
    applied,
    `${item.subtitle}`,
  ].join('\n');
}

function select(key) {
  selectedKey = key;
  for (const tile of grid.children) tile.classList.toggle('selected', tile.dataset.key === key);
  refreshDetail();
}

// ── 操作 ────────────────────────────────────
async function primary() {
  const failure = selectedFailure();
  if (failure) {
    await api.retry(failure.state);
    return;
  }
  const item = selectedItem();
  if (!item) return;
  const state = item.isDirect && item.boundState ? item.boundState : targetSel.value;
  await api.apply(item.key, state);
}

async function secondary() {
  const failure = selectedFailure();
  if (failure) {
    await api.clearFailure(failure.state);
    selectedKey = null;
    return;
  }
  const item = selectedItem();
  if (!item) return;
  // 对齐 mac 版：删除前先确认，被选中的状态会恢复内置默认图
  if (!window.confirm('删除这张本机图片？\n只删本机文件；若它正被某个状态使用，该状态会恢复内置默认图。')) return;
  await api.remove(item.key);
  selectedKey = null;
}

function render() {
  renderFilter();
  renderGrid();
  $('status').textContent = data.status || '';
}

/** 主进程推来的整包数据：筛选段没了要回落，所以每次都对一遍 filterState */
function applySnapshot(snapshot) {
  if (!snapshot) return;
  data = snapshot;
  const states = (snapshot.states || []).map((s) => s.id);
  if (!filterState || !states.includes(filterState)) {
    filterState = states.includes('idel') ? 'idel' : states[0] || '';
    if (targetSel.options.length) targetSel.value = filterState;
  }
  render();
}

api.onRefresh(applySnapshot);
api.onFilter((state) => {
  const states = (data.states || []).map((s) => s.id);
  if (states.includes(state)) switchFilter(state);
});

$('applyBtn').addEventListener('click', primary);
$('deleteBtn').addEventListener('click', secondary);
$('revealBtn').addEventListener('click', () => {
  const item = selectedItem();
  if (item) api.reveal(item.file);
});
$('close').addEventListener('click', () => api.close());
$('doneBtn').addEventListener('click', () => api.close());
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') api.close();
});

(async () => {
  renderTargets();
  applySnapshot((await api.payload()) || data);
})();
