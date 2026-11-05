// src/renderer/settings.js
// 设置面板逻辑：左侧五项导航 + 各分区控件（宠物信息 / 通用设置 / 提醒设置）
'use strict';

const api = window.settingsAPI;

// ── 通用小工具 ────────────────────────────────
const $ = (id) => document.getElementById(id);

/**
 * 把 mac 系统信息映射成 CSS 变量（配色对齐 SettingsPanel.swift）：
 * 底板三平台统一由 CSS 画不透明卡片（窗口不开 vibrancy），这里只负责深色/强调色；
 * 强调色跟随 controlAccentColor，拿不到就用 macOS 默认蓝。
 * .macos 类当前无样式依赖，只作为平台钩子保留。
 */
function applySystemTheme() {
  const theme = window.settingsTheme || {};
  const root = document.documentElement;
  if (theme.isMac) root.classList.add('macos');
  if (theme.dark) root.classList.add('dark');
  if (theme.accent) {
    const hex = theme.accent.startsWith('#') ? theme.accent : `#${theme.accent}`;
    const n = parseInt(hex.slice(1), 16);
    const rgb = `${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}`;
    root.style.setProperty('--accent', hex);
    root.style.setProperty('--accent-18', `rgba(${rgb}, 0.18)`);
    root.style.setProperty('--accent-14', `rgba(${rgb}, 0.14)`);
    root.style.setProperty('--accent-08', `rgba(${rgb}, 0.08)`);
  }
}

applySystemTheme();

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

// ── 宠物信息：形象（缩略图切换 + 为选中状态上传自定义图）──
// 两个游标要分开：currentState 是宠物此刻在播的形象（只能由主进程状态机定），
// selectedState 是「上传图片/恢复默认」针对的形象。躲藏（hide）只能选不能切，
// 所以点它只移动 selectedState。
const stateBadge = $('state-badge');
let petStateList = [];
let currentState = 'focus';
let selectedState = 'focus';
let spriteStatus = {};
const HIDE_STATE_ID = 'hide';

function findState(id) {
  return petStateList.find((s) => s.id === id) || null;
}

/** 「当前状态」文案：躲藏是贴边探头状态，带「中」表示正在进行 */
function badgeText(id) {
  const item = findState(id);
  if (!item) return '专注';
  return item.id === HIDE_STATE_ID ? '躲藏中' : item.label;
}

/** 预览图：有自定义图显本地上传图（file://），否则显内置首帧 */
function previewSrcFor(id) {
  return spriteStatus[id] || `../../assets/Sprites/${id}/frame_00.png`;
}

/** 形象缩略图网格：可切换态点一下即切动画，躲藏态只选中不切换 */
function renderGrid() {
  const box = $('sprite-grid');
  if (!box) return;
  box.textContent = '';
  for (const item of petStateList) {
    const switchable = item.switchable !== false;
    const tile = document.createElement('button');
    tile.type = 'button';
    tile.className = 'sprite-tile';
    tile.dataset.state = item.id;
    tile.classList.toggle('selected', item.id === selectedState);
    tile.classList.toggle('playing', item.id === currentState);
    tile.classList.toggle('locked', !switchable);
    tile.classList.toggle('custom', Boolean(spriteStatus[item.id]));
    if (!switchable) tile.title = '躲藏形象：把宠物拖到屏幕侧边或右键「躲起来」时探头，可换图但不能手动切换';

    const img = document.createElement('img');
    img.className = 'sprite-thumb';
    img.alt = item.label;
    img.draggable = false;
    img.src = previewSrcFor(item.id);

    const label = document.createElement('span');
    label.className = 'sprite-label';
    label.textContent = item.label;

    tile.append(img, label);
    tile.addEventListener('click', () => selectState(item));
    box.append(tile);
  }
}

/** 选中状态的操作条：显示当前来源 + 上传 / 恢复默认（针对 selectedState） */
function renderActions() {
  const box = $('sprite-actions');
  if (!box) return;
  box.textContent = '';
  const item = findState(selectedState) || { id: selectedState, label: '' };
  const has = Boolean(spriteStatus[item.id]);

  const info = document.createElement('span');
  info.className = 'sprite-current';
  const name = document.createElement('b');
  name.textContent = item.label;
  const tag = document.createElement('span');
  tag.className = 'sprite-tag' + (has ? '' : ' muted');
  tag.textContent = has ? '已自定义' : '内置动画';
  info.append(name, tag);

  const upload = document.createElement('button');
  upload.type = 'button';
  upload.className = 'primary';
  upload.textContent = '上传图片';
  upload.addEventListener('click', async () => {
    upload.disabled = true;
    upload.textContent = '选择中…';
    const res = await api.pickCustomSprite(item.id);
    upload.disabled = false;
    upload.textContent = '上传图片';
    if (res && res.ok) {
      setHint('sprite-hint', `已为「${item.label}」上传形象`, 'ok');
      await refreshSpriteStatus();
    } else if (res && res.canceled) {
      // 用户取消，不打扰
    } else {
      setHint('sprite-hint', (res && res.error) || '上传失败', 'error');
    }
  });

  const reset = document.createElement('button');
  reset.type = 'button';
  reset.className = 'ghost';
  reset.textContent = '恢复默认';
  reset.disabled = !has;
  reset.addEventListener('click', async () => {
    const res = await api.clearCustomSprite(item.id);
    if (res && res.ok) {
      setHint('sprite-hint', `「${item.label}」已恢复默认动画`, 'ok');
      await refreshSpriteStatus();
    } else {
      setHint('sprite-hint', (res && res.error) || '操作失败', 'error');
    }
  });

  box.append(info, upload, reset);
}

async function refreshSpriteStatus() {
  spriteStatus = (await api.listCustomSprites()) || {};
  renderGrid();
  renderActions();
}

function markState(id) {
  currentState = id;
  stateBadge.textContent = badgeText(id);
  renderGrid();
}

/**
 * 点形象格：先把它作为上传/恢复默认的目标；可切换态同时切动画，
 * 躲藏态不切（主进程也会拒），只给一行说明，不当错误提示。
 */
async function selectState(item) {
  selectedState = item.id;
  renderGrid();
  renderActions();
  if (item.switchable === false) {
    setHint('sprite-hint', `「${item.label}」是贴边躲藏时的探头形象，可以换图，但要拖到屏幕侧边或右键「躲起来」才会进入`);
    return;
  }
  if (item.id === currentState) return;
  const res = await api.setPetState(item.id);
  if (res && res.ok) markState(res.state);
  else setHint('sprite-hint', (res && res.error) || '切换形象失败', 'error');
}

// ── 宠物信息：名称 ────────────────────────────
async function savePetName() {
  const res = await api.setPetName($('pet-name').value);
  if (res && res.ok) {
    $('pet-name').value = res.name;
  } else {
    setHint('sprite-hint', (res && res.error) || '保存失败', 'error');
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

// ── 通用设置：权限（校验码解锁）────────────────
// 解锁/清除的判定全在主进程（本地码直过，否则加密后走服务端校验），
// 面板只拿结果码回填提示；文案对齐 mac 版 handleUnlockResult
const accessStatus = $('access-status');
const accessCode = $('access-code');
const unlockBtn = $('unlock-access');
const clearBtn = $('clear-access');

let fullAccess = false;

const ACCESS_MESSAGES = {
  invalidCode: ['校验码错误', '请输入正确的校验码'],
  expired: ['激活码已过期', '该激活码已超过有效期，请联系客服获取新的激活码'],
  deviceLimit: ['激活码已达设备上限', '该激活码绑定的设备数量已达上限，无法在新设备上使用'],
  networkError: ['网络异常', '无法连接校验服务，请检查网络后重试'],
  badFormat: ['激活码格式不正确', '激活码是 12 位字母数字（形如 XXXX-XXXX-XXXX），请检查是否误粘贴了其它内容'],
  localError: ['本地处理失败', '校验码加密失败，请重试；若持续出现请反馈日志'],
  serverError: ['服务异常', '校验服务返回异常，请稍后重试'],
};

async function doUnlock() {
  // 远程校验要等网络，期间禁用防重复提交（对齐 mac 版 unlockBtn isEnabled 守卫）
  unlockBtn.disabled = true;
  const res = await api.unlockAccess(accessCode.value);
  unlockBtn.disabled = false;
  if (res && res.ok) {
    accessCode.value = '';
    fullAccess = true;
    renderAccess();
    setHint('access-hint', '解锁成功，已解锁全部功能', 'ok');
  } else {
    const m = (res && ACCESS_MESSAGES[res.result]) || ACCESS_MESSAGES.invalidCode;
    setHint('access-hint', `${m[0]}：${m[1]}`, 'error');
  }
}

unlockBtn.addEventListener('click', doUnlock);
accessCode.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') doUnlock();
});

clearBtn.addEventListener('click', async () => {
  await api.clearAccess();
  fullAccess = false;
  renderAccess();
  setHint('access-hint', '已清除权限，回到基础权限，高级功能已锁定', 'error');
});

// 定时复核收回权限时主进程主动推一次；本地状态已一致则忽略（解锁链路 IPC 已回发）
api.onAccessChanged((state) => {
  const next = Boolean(state && state.fullAccess);
  if (next === fullAccess) return;
  fullAccess = next;
  renderAccess();
  setHint('access-hint', next
    ? '解锁成功，已解锁全部功能'
    : '激活码已失效，权限已被服务端收回（高级功能已锁定）', next ? 'ok' : 'error');
});

function renderAccess() {
  accessStatus.textContent = fullAccess ? '已解锁全部功能' : '基础权限';
  accessStatus.classList.toggle('ok', fullAccess);
  accessCode.hidden = fullAccess;
  unlockBtn.hidden = fullAccess;
  clearBtn.hidden = !fullAccess;
  renderWeatherAvailability();
}

// ── 提醒设置：每日天气提醒（需解锁；天气接口按量付费）──────
const wrToggle = $('weather-rem-toggle');
const wrTime = $('weather-rem-time');
const wrCity = $('weather-rem-city');
const wrPreview = $('weather-rem-preview');
const wrDesc = $('weather-rem-desc');

let weather = { enabled: false, hour: 8, minute: 0, city: '' };

function fmtHourMinute(hour, minute) {
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

/** 控件可用状态与描述文案（对齐 mac 版 refreshWeatherControls） */
function renderWeatherAvailability() {
  for (const el of [wrToggle, wrTime, wrCity, wrPreview]) el.disabled = !fullAccess;
  if (!fullAccess) {
    wrDesc.textContent = '需解锁全部功能后可用（天气接口按量付费）';
    wrDesc.classList.add('locked');
    return;
  }
  wrDesc.classList.remove('locked');
  wrDesc.textContent = weather.enabled
    ? `每天 ${fmtHourMinute(weather.hour, weather.minute)}（24 小时制）提醒今天的天气`
    : '打开开关后，每天在你选择的时间提醒今天的天气';
}

function renderWeatherReminder() {
  wrToggle.setAttribute('aria-pressed', String(Boolean(weather.enabled)));
  wrTime.value = fmtHourMinute(weather.hour, weather.minute);
  wrCity.value = weather.city || '';
  renderWeatherAvailability();
}

async function setWeather(patch) {
  const res = await api.setWeatherReminder(patch);
  if (res && res.ok) {
    weather = res.weather;
    renderWeatherReminder();
    setHint('weather-rem-hint', '已保存，新的设置立即生效', 'ok');
  } else {
    renderWeatherReminder();
    setHint('weather-rem-hint', (res && res.error) || '保存失败，请重试', 'error');
  }
}

wrToggle.addEventListener('click', () => {
  const next = wrToggle.getAttribute('aria-pressed') !== 'true';
  setWeather({ enabled: next });
});

wrTime.addEventListener('change', () => {
  const m = /^(\d{1,2}):(\d{2})$/.exec(wrTime.value || '');
  if (!m) {
    wrTime.value = fmtHourMinute(weather.hour, weather.minute);
    return;
  }
  setWeather({ hour: Number(m[1]), minute: Number(m[2]) });
});

wrCity.addEventListener('change', () => setWeather({ city: wrCity.value }));

wrPreview.addEventListener('click', async () => {
  const res = await api.previewWeather();
  setHint('weather-rem-hint', (res && res.ok) ? '已推送今日天气，请看天气窗' : ((res && res.error) || '预览失败'), (res && res.ok) ? 'ok' : 'error');
});

// ── 菜单设置：右键菜单项展示开关（对齐 mac 版 fillMenuSettingsSection）──
// 勾 / 取消直接写盘，下次弹出宠物右键菜单就应用（mac 版 contextMenuToggle 同节奏）
let menuItems = [];

function renderMenuGrid() {
  const box = $('menu-grid');
  if (!box) return;
  box.textContent = '';
  for (const item of menuItems) {
    const label = document.createElement('label');
    label.className = 'menu-check';

    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = Boolean(item.visible);
    input.dataset.key = item.key;

    const text = document.createElement('span');
    text.textContent = item.title;

    input.addEventListener('change', async () => {
      const res = await api.setMenuItem(item.key, input.checked);
      if (res && res.ok) {
        menuItems = res.items || menuItems;
        setHint('menu-hint', `已${input.checked ? '显示' : '隐藏'}「${item.title}」，下次弹出右键菜单生效`, 'ok');
      } else {
        input.checked = !input.checked; // 写失败回滚勾选，别让面板与菜单不一致
        setHint('menu-hint', (res && res.error) || '保存失败', 'error');
      }
    });

    label.append(input, text);
    box.append(label);
  }
}

// ── 关闭 ─────────────────────────────────────
$('close').addEventListener('click', () => api.close());

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') api.close();
});

// ── 初始化 ───────────────────────────────────
function formatPetNo(petNo) {
  return petNo ? `#${petNo}` : '未分配';
}

api.load().then((state) => {
  if (!state) return;

  // 宠物信息
  const pet = state.pet || {};
  $('pet-name').value = pet.name || '';
  $('pet-name').placeholder = pet.name || '毛豆';
  $('pet-no-social').textContent = formatPetNo(pet.petNo);
  petStateList = pet.states || [];
  currentState = pet.state || 'focus';
  selectedState = findState(currentState) ? currentState : 'focus';
  stateBadge.textContent = badgeText(currentState);
  refreshSpriteStatus();

  // 通用设置
  const general = state.general || {};
  $('version').textContent = general.version || '—';
  autoLaunchBtn.setAttribute('aria-pressed', String(Boolean(general.autoLaunch)));

  // 权限 + 每日天气提醒
  fullAccess = Boolean(state.access && state.access.fullAccess);
  weather = state.weatherReminder || weather;
  renderAccess();
  renderWeatherReminder();

  if (typeof pet.scale === 'number') {
    scaleSlider.value = String(pet.scale);
    scaleValue.textContent = `${pet.scale.toFixed(1)}x`;
  }

  // 菜单设置（右键菜单项展示开关）
  menuItems = (state.menu && state.menu.items) || [];
  renderMenuGrid();

  // 提醒设置
  const reminder = state.reminder || {};
  if (reminder.min && reminder.max) range = { min: reminder.min, max: reminder.max };
  renderInterval(reminder.minutes || 30);
  defaultHint();
});

// 形象被主进程状态机改掉（贴边躲藏 / 专注跟随 / 右键抚摸）时实时同步徽标与「播放中」标记
// 只动 currentState，不把 selectedState（上传目标）从用户选中的格上拉开
if (api.onPetState) {
  api.onPetState((payload) => markState((payload && payload.state) || payload));
}
