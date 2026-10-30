// src/renderer/settings.js
// 设置面板逻辑：左侧五项导航 + 各分区控件（宠物信息 / 通用设置 / 提醒设置）
'use strict';

const api = window.settingsAPI;

// ── 通用小工具 ────────────────────────────────
const $ = (id) => document.getElementById(id);

function setHint(id, text, kind) {
  const el = $(id);
  if (!el) return;
  el.textContent = text;
  el.className = kind ? `hint ${kind}` : 'hint';
}

// ── 左侧导航 ──────────────────────────────────
const navItems = Array.from(document.querySelectorAll('.nav-item'));
const sections = Array.from(document.querySelectorAll('.section'));

function selectSection(id) {
  for (const btn of navItems) btn.classList.toggle('active', btn.dataset.section === id);
  for (const sec of sections) sec.classList.toggle('active', sec.dataset.section === id);
  $('content').scrollTop = 0;
}

for (const btn of navItems) {
  btn.addEventListener('click', () => selectSection(btn.dataset.section));
}

// ── 宠物信息：形象切换 ────────────────────────
const stateBadge = $('state-badge');

function renderStates(states, current) {
  const box = $('states');
  box.textContent = '';
  for (const item of states) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'state-tile';
    btn.dataset.state = item.id;
    btn.classList.toggle('selected', item.id === current);

    btn.textContent = item.label;
    btn.addEventListener('click', () => applyState(item));
    box.appendChild(btn);
  }
}

function markState(id, label) {
  stateBadge.textContent = label;
  for (const btn of document.querySelectorAll('.state-tile')) {
    btn.classList.toggle('selected', btn.dataset.state === id);
  }
}

async function applyState(item) {
  const res = await api.setPetState(item.id);
  if (res && res.ok) markState(res.state, item.label);
  else setHint('name-hint', (res && res.error) || '切换形象失败', 'error');
}

// ── 宠物信息：名称 ────────────────────────────
async function savePetName() {
  const res = await api.setPetName($('pet-name').value);
  if (res && res.ok) {
    $('pet-name').value = res.name;
    setHint('name-hint', `已保存为「${res.name}」`, 'ok');
  } else {
    setHint('name-hint', (res && res.error) || '保存失败', 'error');
  }
}

$('save-name').addEventListener('click', savePetName);
$('pet-name').addEventListener('keydown', (event) => {
  if (event.key === 'Enter') savePetName();
  if (event.key === 'Escape') event.target.blur();
});

// ── 通用设置：宠物大小 ────────────────────────
const scaleSlider = $('scale');
const scaleValue = $('scale-value');

scaleSlider.addEventListener('input', () => {
  scaleValue.textContent = `${Number(scaleSlider.value).toFixed(1)}x`;
});

scaleSlider.addEventListener('change', async () => {
  const res = await api.setPetScale(Number(scaleSlider.value));
  if (res && res.ok) {
    scaleSlider.value = String(res.scale);
    scaleValue.textContent = `${res.scale.toFixed(1)}x`;
    setHint('scale-hint', `已调整为 ${res.scale.toFixed(1)}x`, 'ok');
  } else {
    setHint('scale-hint', (res && res.error) || '调整失败', 'error');
  }
});

// ── 通用设置：开机自启 ────────────────────────
const autoLaunchBtn = $('auto-launch');

autoLaunchBtn.addEventListener('click', async () => {
  const next = autoLaunchBtn.getAttribute('aria-pressed') !== 'true';
  const res = await api.setAutoLaunch(next);
  const enabled = res && res.ok ? res.enabled : !next;
  autoLaunchBtn.setAttribute('aria-pressed', String(enabled));
});

// ── 通用设置：版本与检查更新 ──────────────────
const checkUpdateBtn = $('check-update');

checkUpdateBtn.addEventListener('click', async () => {
  checkUpdateBtn.disabled = true;
  checkUpdateBtn.textContent = '检查中…';
  await api.checkUpdate();
  checkUpdateBtn.disabled = false;
  checkUpdateBtn.textContent = '检查更新';
});

// ── 提醒设置：喝水间隔 ────────────────────────
const currentEl = $('current');
const customEl = $('custom');
const presetBtns = Array.from(document.querySelectorAll('.preset'));

let range = { min: 1, max: 120 };

function renderInterval(minutes) {
  currentEl.textContent = minutes;
  for (const btn of presetBtns) {
    btn.classList.toggle('selected', Number(btn.dataset.minutes) === minutes);
  }
}

function defaultHint() {
  setHint('hint', `可填 ${range.min}～${range.max} 分钟，回车或点「应用」生效`);
}

async function applyInterval(minutes) {
  const res = await api.setInterval(minutes);
  if (res && res.ok) {
    renderInterval(res.minutes);
    customEl.value = '';
    setHint('hint', `已设为每 ${res.minutes} 分钟提醒，已重新计时`, 'ok');
    return;
  }
  renderInterval(res && res.minutes ? res.minutes : Number(currentEl.textContent));
  setHint('hint', (res && res.error) || '设置失败，请重试', 'error');
}

function applyCustom() {
  const raw = customEl.value.trim();
  if (!raw) {
    setHint('hint', '请先填写间隔分钟数', 'error');
    customEl.focus();
    return;
  }
  applyInterval(Number(raw));
}

for (const btn of presetBtns) {
  btn.addEventListener('click', () => applyInterval(Number(btn.dataset.minutes)));
}

$('apply').addEventListener('click', applyCustom);

customEl.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') applyCustom();
  if (event.key === 'Escape') {
    customEl.value = '';
    defaultHint();
    customEl.blur();
  }
});

$('test').addEventListener('click', () => {
  api.testReminder();
  setHint('hint', '已弹出一次提醒窗', 'ok');
});

// ── 关闭 ─────────────────────────────────────
$('close').addEventListener('click', () => api.close());

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') api.close();
});

// ── 初始化 ───────────────────────────────────
function formatPetNo(petNo) {
  return petNo ? `#${petNo}` : '未分配';
}

/** 相对时间：12 秒前 / 3 分钟前 / 2 小时前 */
function agoLabel(ts) {
  if (!ts) return '—';
  const sec = Math.max(0, Math.round((Date.now() - ts) / 1000));
  if (sec < 60) return `${sec} 秒前`;
  if (sec < 3600) return `${Math.round(sec / 60)} 分钟前`;
  return `${Math.round(sec / 3600)} 小时前`;
}

/** 心跳卡片：失败原因优先，其次展示最近一次成功时间（成功默认不写日志，这里是主要观测口） */
function renderHeartbeat(hb) {
  const stateEl = $('heartbeat-state');
  const descEl = $('heartbeat');
  if (!hb) {
    stateEl.textContent = '—';
    stateEl.className = 'value';
    return;
  }
  stateEl.className = 'value';
  if (hb.lastError) {
    stateEl.textContent = '失败';
    stateEl.classList.add('bad');
    descEl.textContent = hb.lastError;
    return;
  }
  if (hb.lastSuccessAt) {
    stateEl.textContent = '正常';
    stateEl.classList.add('ok');
    descEl.textContent = `最近一次 ${agoLabel(hb.lastSuccessAt)} · 每 ${hb.intervalSec} 秒一次`;
    return;
  }
  stateEl.textContent = hb.sending ? '上报中' : '等待首次上报';
  descEl.textContent = hb.url ? `目标 ${hb.url}` : '尚未上报';
}

/** 心跳每 60s 一次，面板打开期间轮询刷新，只改心跳卡片不动其他表单 */
async function refreshHeartbeat() {
  const state = await api.load();
  if (state) renderHeartbeat(state.general && state.general.heartbeat);
}

api.load().then((state) => {
  if (!state) return;

  // 宠物信息
  const pet = state.pet || {};
  $('pet-name').value = pet.name || '';
  $('pet-name').placeholder = '毛豆';
  $('pet-no').textContent = formatPetNo(pet.petNo);
  $('pet-no-social').textContent = formatPetNo(pet.petNo);
  renderStates(pet.states || [], pet.state || 'focus');
  const currentLabel = (pet.states || []).find((s) => s.id === pet.state);
  stateBadge.textContent = currentLabel ? currentLabel.label : '专注';

  // 通用设置
  const general = state.general || {};
  $('version').textContent = general.version || '—';
  autoLaunchBtn.setAttribute('aria-pressed', String(Boolean(general.autoLaunch)));
  renderHeartbeat(general.heartbeat);
  setInterval(refreshHeartbeat, 5000);

  if (typeof pet.scale === 'number') {
    scaleSlider.value = String(pet.scale);
    scaleValue.textContent = `${pet.scale.toFixed(1)}x`;
  }

  // 提醒设置
  const reminder = state.reminder || {};
  if (reminder.min && reminder.max) range = { min: reminder.min, max: reminder.max };
  renderInterval(reminder.minutes || 30);
  defaultHint();
});
