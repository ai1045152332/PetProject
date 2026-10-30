// src/main/settings-service.js
// 设置面板的业务逻辑：读配置 / 校验并写入（提醒间隔、宠物名称、宠物大小）/ 触发测试提醒
// 与 IPC、窗口解耦，便于单测（index.js 只做 ipcMain 接线与副作用）
'use strict';

const config = require('./config-store');
const {
  clampInterval,
  isValidInterval,
  MIN_INTERVAL,
  MAX_INTERVAL,
} = require('./reminder-scheduler');

// 预设间隔（对齐 mac 版 SettingsPanel.fillReminderSection 的 presets）
const PRESETS = [15, 30, 45, 60];
const KEY = 'drinkWaterInterval';

// 宠物大小与名称（对齐 mac 版 viewModel.catScale 0.5~2.0 与 PetName.setName）
const MIN_SCALE = 0.5;
const MAX_SCALE = 2.0;
const DEFAULT_SCALE = 1.0;
const DEFAULT_PET_NAME = '毛豆';
const MAX_PET_NAME = 20;

// 形象（对齐 mac 版 CatAnimationState.displayName；hide 为贴边躲藏态，不在面板里手动切换）
const PET_STATES = [
  { id: 'focus', label: '专注' },
  { id: 'idel', label: '休闲' },
  { id: 'sleep', label: '睡觉' },
  { id: 'pet', label: '抚摸' },
];

/**
 * 心跳状态归一化（面板展示用）：
 * lastSuccessAt / lastAttemptAt 为毫秒时间戳，lastError 为空表示最近一次上报成功
 */
function normalizeHeartbeat(raw) {
  const src = raw || {};
  const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
  return {
    lastAttemptAt: num(src.lastAttemptAt),
    lastSuccessAt: num(src.lastSuccessAt),
    lastError: String(src.lastError || ''),
    successCount: num(src.successCount),
    intervalSec: num(src.intervalSec) || 60,
    url: String(src.url || ''),
    sending: Boolean(src.sending),
  };
}

/** 宠物大小收敛到 0.5~2.0，两位小数 */
function clampScale(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return DEFAULT_SCALE;
  return Math.round(Math.min(MAX_SCALE, Math.max(MIN_SCALE, n)) * 100) / 100;
}

/** 当前生效的提醒间隔（分钟），脏数据自动回落默认值 */
function currentInterval() {
  return clampInterval(config.get(KEY));
}

/** 当前宠物名称（空值回落默认名，对齐 PetName.currentName） */
function currentPetName() {
  const saved = String(config.get('petName') || '').trim();
  return saved || DEFAULT_PET_NAME;
}

/** 当前宠物大小 */
function currentPetScale() {
  return clampScale(config.get('petScale'));
}

/** 是否是合法形象 id */
function isValidPetState(state) {
  return PET_STATES.some((s) => s.id === state);
}

class SettingsService {
  /**
   * @param {object} [opts]
   * @param {{ restart: () => void, triggerNow: () => void }} [opts.scheduler] 提醒调度器
   * @param {object} [opts.providers] 只读数据来源（版本号 / 宠物号 / 当前形象 / 开机自启状态）
   */
  constructor({ scheduler, providers = {} } = {}) {
    this.scheduler = scheduler;
    this.providers = {
      version: () => '',
      petNo: () => 0,
      petState: () => 'focus',
      autoLaunch: () => false,
      heartbeat: () => null,
      ...providers,
    };
  }

  /** 设置面板初始化数据（左侧五项导航用到的全部只读状态） */
  load() {
    return {
      reminder: {
        minutes: currentInterval(),
        presets: PRESETS.slice(),
        min: MIN_INTERVAL,
        max: MAX_INTERVAL,
      },
      pet: {
        name: currentPetName(),
        petNo: this.providers.petNo(),
        state: this.providers.petState(),
        scale: currentPetScale(),
        states: PET_STATES.map((s) => ({ ...s })),
      },
      general: {
        version: this.providers.version(),
        autoLaunch: Boolean(this.providers.autoLaunch()),
        heartbeat: normalizeHeartbeat(this.providers.heartbeat()),
      },
    };
  }

  /**
   * 写入提醒间隔：校验 → 持久化 → 立即重启计时（对齐 mac 版 restartDrinkWaterReminder）。
   * @param {*} minutes
   * @returns {{ok: true, minutes: number} | {ok: false, error: string, minutes: number}}
   */
  setInterval(minutes) {
    if (!isValidInterval(minutes)) {
      return {
        ok: false,
        error: `请输入 ${MIN_INTERVAL}～${MAX_INTERVAL} 之间的整数`,
        minutes: currentInterval(),
      };
    }
    const value = clampInterval(minutes);
    config.set(KEY, value);
    if (this.scheduler) this.scheduler.restart();
    return { ok: true, minutes: value };
  }

  /**
   * 写入宠物名称：空输入回退默认名（与 mac 版 PetName.setName 一致）。
   * @param {*} name
   */
  setPetName(name) {
    const trimmed = String(name == null ? '' : name).trim();
    if (trimmed.length > MAX_PET_NAME) {
      return { ok: false, error: `名称最多 ${MAX_PET_NAME} 个字符`, name: currentPetName() };
    }
    const value = trimmed || DEFAULT_PET_NAME;
    config.set('petName', value);
    return { ok: true, name: value };
  }

  /**
   * 写入宠物大小（0.5~2.0）。
   * @param {*} scale
   */
  setPetScale(scale) {
    const n = Number(scale);
    if (!Number.isFinite(n) || n < MIN_SCALE || n > MAX_SCALE) {
      return {
        ok: false,
        error: `宠物大小需在 ${MIN_SCALE}～${MAX_SCALE} 之间`,
        scale: currentPetScale(),
      };
    }
    const value = clampScale(n);
    config.set('petScale', value);
    return { ok: true, scale: value };
  }

  /** 立即弹一次提醒（不修改配置，也不影响计时） */
  testReminder() {
    if (this.scheduler) this.scheduler.triggerNow();
  }
}

module.exports = {
  SettingsService,
  currentInterval,
  currentPetName,
  currentPetScale,
  clampScale,
  isValidPetState,
  PET_STATES,
  PRESETS,
  KEY,
  MIN_SCALE,
  MAX_SCALE,
  DEFAULT_PET_NAME,
  MAX_PET_NAME,
};
