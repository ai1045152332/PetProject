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
  // 每次点进「好友消息」都重拉一次：面板是复用实例，不重建就不会知道对方刚同意了申请
  if (id === 'social') loadSocial(false);
  // 停在宠物信息区时刷一次剩余生成次数（有码才会真发请求，没码主进程直接回落）
  if (id === 'pet' && api.petImageRefresh) api.petImageRefresh();
  syncSocialAutoRefresh();
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

// 自定义状态图片（对标 mac 版 refreshSpriteAccessUI）：有码与否决定描述文案与 AI 按钮可用性，
// busy 期间（正在生成 / 重试）不让人再改同一批图
const SPRITE_DESC_FULL = '直接上传：本机即时生效；AI 生成：上传一次，逐状态各生成一张 · 最大 10 MB';
const SPRITE_DESC_NO_CODE = '直接上传与本机历史随时可用；AI 生成需服务端激活码';
const AI_TOOLTIP = '上传一张照片，AI 为全部 5 个状态各生成一张图片（姿态按状态区分）并自动应用；整批仅消耗该激活码的 1 次生成配额';
let petImages = { hasCode: false, busy: false, quotaLimit: 0, quotaRemaining: 0, status: '', availability: {} };

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
  const avail = (petImages.availability || {})[item.id] || {};

  const info = document.createElement('span');
  info.className = 'sprite-current';
  const name = document.createElement('b');
  name.textContent = item.label;
  const tag = document.createElement('span');
  tag.className = 'sprite-tag' + (has ? '' : ' muted');
  tag.textContent = has ? '已自定义' : '内置动画';
  info.append(name, tag);

  // 直传图存不存在用「●」前标出来（与 mac 版同样只靠按钮文案区分直传 / 云端）
  const upload = document.createElement('button');
  upload.type = 'button';
  upload.className = 'primary';
  upload.textContent = avail.hasLocal ? '● 直接上传' : '直接上传';
  upload.title = `原图（含 GIF 动图）直接作为${item.label}状态图片，仅保存在本机`;
  upload.disabled = Boolean(petImages.busy);
  upload.addEventListener('click', async () => {
    upload.disabled = true;
    upload.textContent = '选择中…';
    const res = await api.pickCustomSprite(item.id);
    upload.textContent = avail.hasLocal ? '● 直接上传' : '直接上传';
    if (res && res.ok) {
      setHint('sprite-hint', `已为「${item.label}」上传形象`, 'ok');
      await refreshSpriteStatus();
    } else if (res && res.canceled) {
      // 用户取消，不打扰
      renderActions();
    } else {
      setHint('sprite-hint', (res && res.error) || '上传失败', 'error');
      renderActions();
    }
  });

  const reset = document.createElement('button');
  reset.type = 'button';
  reset.className = 'ghost';
  reset.textContent = '恢复默认';
  reset.title = `清除${item.label}状态的图片，恢复内置默认图`;
  // mac 版：本机关过直传图、或当前正生效着任意自定义图，才允许恢复默认
  reset.disabled = Boolean(petImages.busy) || !(avail.hasLocal || avail.hasCustom);
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

/**
 * 刷新「自定义状态图片」卡的右侧：描述 / AI 按钮可用性 / 配额与进度文案。
 * 逐条对齐 mac 版 refreshSpriteAccessUI。
 */
function renderPetImages(snapshot) {
  if (snapshot) petImages = snapshot;
  const desc = $('sprite-desc');
  const aiBtn = $('ai-generate');
  const status = $('ai-status');
  const historyBtn = $('pet-history');
  if (!desc || !aiBtn || !status) return;

  const { hasCode, busy, quotaLimit, quotaRemaining } = petImages;
  const quotaExhausted = Boolean(hasCode) && Number(quotaRemaining) === 0 && Number(quotaLimit) > 0;

  if (hasCode) {
    desc.textContent = SPRITE_DESC_FULL;
    desc.classList.remove('warn');
    if (!busy && Number(quotaLimit) > 0) {
      status.textContent = quotaExhausted
        ? `AI 生成次数已用完（${quotaLimit}/${quotaLimit}）`
        : `剩余 AI 生成次数：${quotaRemaining}/${quotaLimit}`;
    }
  } else {
    desc.textContent = SPRITE_DESC_NO_CODE;
    desc.classList.add('warn');
    status.textContent = '';
  }
  // 生成中的阶段文案（「正在生成宠物动画帧…」这类）优先占着右侧，不让配额把它盖掉
  if (petImages.status) status.textContent = petImages.status;
  if (busy) status.classList.add('working');
  else status.classList.remove('working');

  aiBtn.disabled = !hasCode || busy || quotaExhausted;
  aiBtn.title = hasCode ? AI_TOOLTIP : 'AI 生成需要有效的服务端激活码（本地快捷码不占生成配额）';
  if (historyBtn) historyBtn.disabled = busy;
}

/** AI 生成所有状态：选一张照片 → 上传 → 等逐状态生成 → 自动应用（整批扣 1 次配额） */
async function generateAllStatesWithAI() {
  if (!petImages.hasCode) {
    setHint('sprite-hint', '该功能需要解锁：请在「通用设置 → 权限」输入有效的服务端激活码；直接上传、本机历史与本地切图不受影响', 'error');
    return;
  }
  const res = await api.petImageGenerateAll().catch(() => null);
  if (res && res.canceled) return;
  if (!res || !res.ok) setHint('sprite-hint', (res && res.error) || 'AI 生成失败', 'error');
  else await refreshSpriteStatus();
}

$('ai-generate').addEventListener('click', generateAllStatesWithAI);

// 历史图片完全读本机文件，不需要网络（服务端只负责生成与存储）
$('pet-history').addEventListener('click', async () => {
  const res = await api.petImageOpenHistory(currentState).catch(() => null);
  if (!res || !res.ok) setHint('sprite-hint', (res && res.error) || '打开历史图片失败', 'error');
});

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

// 微信号点击即复制：剪贴板写入走主进程（settings:copy-text），结果回填权限卡下方提示行
$('copy-wechat').addEventListener('click', async () => {
  const wechat = $('copy-wechat').textContent.trim();
  const res = await api.copyText(wechat);
  setHint('access-hint', res && res.ok
    ? `已复制微信号「${wechat}」，添加后可获取校验码`
    : (res && res.error) || '复制失败，请手动选中复制', res && res.ok ? 'ok' : 'error');
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
// 城市不再提供设置：默认按 IP 定位提醒当前城市（与 mac 版天气提醒同口径）
const wrToggle = $('weather-rem-toggle');
const wrTime = $('weather-rem-time');
const wrPreview = $('weather-rem-preview');
const wrDesc = $('weather-rem-desc');

let weather = { enabled: false, hour: 8, minute: 0 };

function fmtHourMinute(hour, minute) {
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

/** 控件可用状态与描述文案（对齐 mac 版 refreshWeatherControls） */
function renderWeatherAvailability() {
  for (const el of [wrToggle, wrTime, wrPreview]) el.disabled = !fullAccess;
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

wrPreview.addEventListener('click', async () => {
  const res = await api.previewWeather();
  setHint('weather-rem-hint', (res && res.ok) ? '已推送今日天气，请看天气窗' : ((res && res.error) || '预览失败'), (res && res.ok) ? 'ok' : 'error');
});

// ── 提醒设置：主动搭话（对齐 mac 版 refreshChatControls）──
// 开关决定是否冒泡，间隔预设只在开启时可点（关闭时整组置灰，与 mac 版 alphaValue 0.4 一致）
const chatToggle = $('chat-toggle');
const chatDesc = $('chat-desc');
const chatPresetBox = $('chat-presets');

const CHAT_DESC_ON = '按勾选的内容找你聊天';
const CHAT_DESC_OFF = '已关闭';

let chatState = { enabled: true, minutes: 30, presets: [], allTopics: [] };

// 搭话内容勾选（消息提醒）：勾/取消直接写盘，至少留一项（全取消时主进程会拒绝并回滚）
const chatTopicBox = $('chat-topics');

function renderChatTopics() {
  if (!chatTopicBox) return;
  chatTopicBox.textContent = '';
  for (const topic of chatState.allTopics || []) {
    const label = document.createElement('label');
    label.className = 'topic-check';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = Boolean(topic.checked);
    input.dataset.key = topic.key;
    input.disabled = !chatState.enabled;
    const text = document.createElement('span');
    text.textContent = topic.label;
    input.addEventListener('change', () => {
      const picked = [...chatTopicBox.querySelectorAll('input')]
        .filter((el) => el.checked)
        .map((el) => el.dataset.key);
      setProactiveChat({ topics: picked });
    });
    label.append(input, text);
    if (!chatState.enabled) label.classList.add('disabled');
    chatTopicBox.append(label);
  }
}

/** 预设按钮只在初始化时建一次（预设不会运行期变），选中态/置灰态交给 render 刷 */
function renderChatPresets() {
  if (!chatPresetBox) return;
  chatPresetBox.textContent = '';
  for (const minutes of chatState.presets || []) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'preset chat-preset';
    btn.dataset.minutes = String(minutes);
    btn.textContent = String(minutes);
    btn.addEventListener('click', () => setProactiveChat({ intervalMinutes: minutes }));
    chatPresetBox.append(btn);
  }
}

function renderChatControls() {
  if (!chatToggle) return;
  chatToggle.setAttribute('aria-pressed', String(Boolean(chatState.enabled)));
  chatDesc.textContent = chatState.enabled ? CHAT_DESC_ON : CHAT_DESC_OFF;
  for (const btn of chatPresetBox.querySelectorAll('.chat-preset')) {
    btn.classList.toggle('selected', Number(btn.dataset.minutes) === chatState.minutes);
    btn.disabled = !chatState.enabled;
  }
  renderChatTopics();
}

async function setProactiveChat(patch) {
  const res = await api.setProactiveChat(patch);
  if (res && res.ok) {
    chatState = res.chat || chatState;
    renderChatControls();
    let msg;
    if (patch.topics !== undefined) msg = '搭话内容已更新';
    else if (patch.intervalMinutes !== undefined) msg = `每 ${chatState.minutes} 分钟一次`;
    else msg = chatState.enabled ? '已开启' : '已关闭';
    setHint('chat-hint', msg, 'ok');
    return;
  }
  if (res && res.chat) chatState = res.chat;
  renderChatControls();
  setHint('chat-hint', (res && res.error) || '保存失败，请重试', 'error');
}

chatToggle.addEventListener('click', () => {
  setProactiveChat({ enabled: chatToggle.getAttribute('aria-pressed') !== 'true' });
});

// 立刻说一句：不等 15 分钟，用来确认搭话链路通不通
const chatTestBtn = $('chat-test');
if (chatTestBtn) {
  chatTestBtn.addEventListener('click', async () => {
    const res = await api.testChat();
    setHint('chat-hint', (res && res.ok) ? '已让它说一句，看小猫头顶（没显示就看终端日志）' : ((res && res.error) || '触发失败'),
      (res && res.ok) ? 'ok' : 'error');
  });
}

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

// ── 好友消息（对齐 mac 版 fillSocialSection / loadSocial / 好友行与申请行）──
// 数据一律走主进程 social-service（加密信封），这里只管渲染与交互节奏：
//   · 停在好友区且面板可见时每 60s 静默同步一次（不抢用户看到的操作反馈）
//   · 静默同步失败不打扰用户（网络瞬断下个周期会重来），手动刷新才回错误文案
const socialListBox = $('friends-list');
const socialRefreshBtn = $('refresh-social');
const socialAddInput = $('add-friend-no');
const socialAddBtn = $('add-friend');

const EMPTY_HINT = '还没有好友，输入对方宠物号点「发申请」，对方同意后你们就互为好友了';
const SHORT_EMPTY_HINT = '还没有好友，输入对方宠物号点「发申请」';
const SOCIAL_AUTO_REFRESH_MS = 60 * 1000;

let socialFriends = [];
let socialRequests = [];
let socialLoading = false;
let socialTimer = null;

function setSocialStatus(text, kind) {
  setHint('social-hint', text || '', kind);
}

function renderPetNoValue(petNo) {
  const el = $('pet-no-social');
  if (el) el.textContent = petNo > 0 ? `#${petNo}` : '尚未获取，稍后会自动出现';
}

function socialTiny(label, handler) {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'tiny';
  btn.textContent = label;
  btn.addEventListener('click', handler);
  return btn;
}

function socialRow(name, buttons, isRequest) {
  const row = document.createElement('div');
  row.className = isRequest ? 'friend-row request' : 'friend-row';
  const label = document.createElement('span');
  label.className = 'friend-name';
  label.textContent = name;
  row.append(label, ...buttons);
  return row;
}

function socialGroup(title) {
  const el = document.createElement('div');
  el.className = 'list-group';
  el.textContent = title;
  return el;
}

/** 重建「好友与申请」列表：待处理申请靠上（避开被好友顶到看不见），下面才是好友 */
function renderSocialList(emptyHint) {
  if (!socialListBox) return;
  socialListBox.textContent = '';
  if (!socialFriends.length && !socialRequests.length) {
    const hint = document.createElement('div');
    hint.className = 'list-empty';
    hint.textContent = emptyHint || EMPTY_HINT;
    socialListBox.append(hint);
    return;
  }
  if (socialRequests.length) {
    socialListBox.append(socialGroup('收到的申请（同意后才互为好友）'));
    for (const req of socialRequests) {
      socialListBox.append(socialRow(`${req.display} 申请加你为好友`, [
        socialTiny('同意', () => decideFriendRequest('accept', req)),
        socialTiny('拒绝', () => decideFriendRequest('reject', req)),
      ], true));
    }
  }
  if (socialFriends.length) {
    socialListBox.append(socialGroup('我的好友'));
    for (const friend of socialFriends) {
      socialListBox.append(socialRow(friend.display, [
        socialTiny('聊天', () => openFriendChatWith(friend)),
        socialTiny('删除', () => removeFriend(friend)),
      ], false));
    }
  }
}

function socialChanged(friends, requests) {
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  return !same(friends, socialFriends) || !same(requests, socialRequests);
}

/** 列表底部状态文案（逐条对齐 mac 版 applySocialStatus） */
function applySocialStatus(pending, changed, silent) {
  const pendingText = `有 ${socialRequests.length} 条好友申请等你处理`;
  if (!silent) {
    setSocialStatus(pending ? pendingText : '');
    return;
  }
  // 原本就在提示待处理申请时，静默同步才能接着改这一行（不抢用户刚看到的操作反馈）
  const el = $('social-hint');
  const wasPendingHint = /条好友申请等你处理$/.test((el && el.textContent) || '');
  if (pending) setSocialStatus(pendingText);
  else if (wasPendingHint) setSocialStatus(changed ? '好友与申请已同步到最新' : '');
}

/**
 * 拉好友与申请。silent=true 为后台静默同步（面板可见期间的定时触发）：
 * 不抢「刷新中…」与「正在加载…」这些可见反馈，只在数据确实变了时重排列表。
 */
async function loadSocial(silent) {
  if (socialLoading) return;
  socialLoading = true;
  if (!silent) {
    socialRefreshBtn.textContent = '刷新中…';
    setSocialStatus('正在加载…');
  }
  let res = null;
  try {
    res = await api.socialSync();
  } finally {
    socialLoading = false;
    if (!silent) socialRefreshBtn.textContent = '刷新';
  }
  if (!res || !res.ok) {
    if (!silent) setSocialStatus(`加载失败：${(res && res.error) || '未知错误'}`, 'error');
    return;
  }
  renderPetNoValue(Number(res.petNo) || 0);
  const changed = socialChanged(res.friends || [], res.requests || []);
  socialFriends = res.friends || [];
  socialRequests = res.requests || [];
  if (changed || !silent) renderSocialList(EMPTY_HINT);
  applySocialStatus(Boolean(socialRequests.length), changed, silent);
}

/** 根据「当前分区是好友区 + 面板可见」开/关静默同步计时 */
function syncSocialAutoRefresh() {
  const onSocial = document.querySelector('.section[data-section="social"]').classList.contains('active');
  if (onSocial && document.visibilityState === 'visible') {
    if (socialTimer) return;
    socialTimer = setInterval(() => {
      if (document.visibilityState === 'visible') loadSocial(true);
    }, SOCIAL_AUTO_REFRESH_MS);
    return;
  }
  if (socialTimer) {
    clearInterval(socialTimer);
    socialTimer = null;
  }
}

socialRefreshBtn.addEventListener('click', () => loadSocial(false));

document.getElementById('copy-pet-no').addEventListener('click', async () => {
  const res = await api.socialCopyPetNo();
  if (res && res.ok) setSocialStatus(`已复制你的宠物号 #${res.petNo}，把它告诉朋友，对方发申请、你同意后就是好友`);
  else setSocialStatus((res && res.error) || '复制失败', 'error');
});

async function addFriend() {
  const raw = (socialAddInput.value || '').trim();
  if (!/^[1-9]\d*$/.test(raw)) {
    setSocialStatus('请输入正确的宠物号（纯数字）', 'error');
    return;
  }
  if (socialLoading) return;
  socialLoading = true;
  setSocialStatus('正在发送申请…');
  socialAddBtn.disabled = true;
  let res = null;
  try {
    res = await api.socialAdd(Number(raw));
  } finally {
    socialLoading = false;
    socialAddBtn.disabled = false;
  }
  if (!res || !res.ok) {
    setSocialStatus(`申请失败：${(res && res.error) || '未知错误'}`, 'error');
    return;
  }
  socialFriends = res.friends || [];
  socialAddInput.value = '';
  socialAddInput.blur();
  renderSocialList(SHORT_EMPTY_HINT);
  setSocialStatus(`#${raw}：${res.notice}`);
}

socialAddBtn.addEventListener('click', addFriend);
socialAddInput.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    addFriend();
  }
});

/** 同意/拒绝的共用处理：处理后从待处理列表移除并刷新列表 */
async function decideFriendRequest(action, req) {
  if (socialLoading) return;
  socialLoading = true;
  setSocialStatus(action === 'accept' ? '正在同意…' : '正在拒绝…');
  const res = await api.socialDecide(action, req.fromPetNo).catch(() => null);
  socialLoading = false;
  if (!res || !res.ok) {
    setSocialStatus(`处理失败：${(res && res.error) || '未知错误'}`, 'error');
    return;
  }
  socialFriends = res.friends || [];
  socialRequests = socialRequests.filter((item) => item.id !== req.id);
  renderSocialList(SHORT_EMPTY_HINT);
  setSocialStatus(action === 'accept'
    ? `已同意 ${req.display} 的申请，你们互为好友了`
    : `已拒绝 ${req.display} 的申请`);
}

async function removeFriend(friend) {
  if (socialLoading) return;
  socialLoading = true;
  setSocialStatus('正在删除…');
  const res = await api.socialRemove(friend.petNo).catch(() => null);
  socialLoading = false;
  if (!res || !res.ok) {
    setSocialStatus(`删除失败：${(res && res.error) || '未知错误'}`, 'error');
    return;
  }
  socialFriends = res.friends || [];
  renderSocialList('还没有好友');
  setSocialStatus(`已删除好友 ${friend.display}（双方同时解除）`);
}

/** 打开与这位好友的会话窗（主进程 FriendChatWindow 同能力：可回看记录、可直接回复） */
async function openFriendChatWith(friend) {
  const res = await api.socialOpenChat(friend.petNo, friend.display).catch(() => null);
  if (res && res.ok) setSocialStatus(`已打开与 ${friend.display} 的会话窗`);
  else setSocialStatus((res && res.error) || '打开会话失败', 'error');
}

// ── 关闭 ─────────────────────────────────────
$('close').addEventListener('click', () => api.close());

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') api.close();
});

// ── 初始化 ───────────────────────────────────
api.load().then((state) => {
  if (!state) return;

  // 宠物信息
  const pet = state.pet || {};
  $('pet-name').value = pet.name || '';
  $('pet-name').placeholder = pet.name || '毛豆';
  renderPetNoValue(Number(pet.petNo) || 0);
  petStateList = pet.states || [];
  currentState = pet.state || 'focus';
  selectedState = findState(currentState) ? currentState : 'focus';
  stateBadge.textContent = badgeText(currentState);
  renderPetImages(state.petImages || null);
  refreshSpriteStatus();
  // 剩余生成次数拉一次（无码 / 生成中都会在主进程里直接回落，不必这里再判权限）
  if (api.petImageRefresh) api.petImageRefresh();

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

  // 提醒设置：消息提醒 → 主动搭话（开关 / 间隔 / 搭话内容）
  chatState = state.proactiveChat || chatState;
  renderChatPresets();
  renderChatControls();

  // 好友消息：先给空态，停在好友区时顺手拉一次（面板复用实例，切分区时也会重拉）
  renderSocialList(EMPTY_HINT);
  syncSocialAutoRefresh();

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

// 图片生成进度 / 配额 / 本机图片变化：主进程推整包快照，面板重绘右侧文案与按钮可用性
// （busy 一解除，「直接上传」的圆点与「恢复默认」可用态也要跟着重算，所以连操作条一起重画）
if (api.onPetImages) {
  api.onPetImages((snapshot) => {
    renderPetImages(snapshot);
    renderActions();
    refreshSpriteStatus();
  });
}

// 心跳拿到/刷新了宠物号（首次联网、换号）时跟着改展示
if (api.onPetNo) {
  api.onPetNo((payload) => renderPetNoValue(Number(payload && payload.petNo) || 0));
}

// 在申请卡上同意/拒绝了申请：按主进程回传的最新好友列表重排，面板不重跑网络
if (api.onSocialChanged) {
  api.onSocialChanged((payload) => {
    const p = payload || {};
    if (Array.isArray(p.friends)) socialFriends = p.friends;
    if (p.removeRequestId) socialRequests = socialRequests.filter((item) => item.id !== p.removeRequestId);
    renderSocialList(EMPTY_HINT);
    if (p.notice) setSocialStatus(p.notice);
  });
}

// 面板被遮到别的 Space / 最小化时停掉静默同步，回来再开（mac 版靠 isVisible）
document.addEventListener('visibilitychange', syncSocialAutoRefresh);
