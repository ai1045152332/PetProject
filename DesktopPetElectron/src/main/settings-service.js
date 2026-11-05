// src/main/settings-service.js
// 设置面板的业务逻辑：读配置 / 校验并写入（提醒间隔、宠物名称、宠物大小、每日天气提醒）/ 触发测试提醒
// 与 IPC、窗口解耦，便于单测（index.js 只做 ipcMain 接线与副作用）
'use strict';

const config = require('./config-store');
const contextMenuPrefs = require('./context-menu-prefs');
const proactiveChat = require('./proactive-chat');
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
// 首次启动随机取的宠物名（用户可在面板里自行改名）
const PET_NAME_POOL = ['毛豆', '汤圆', '布丁', '奶糖', '芝麻', '糯米', '土豆', '团子', '花卷', '年糕'];
const MAX_PET_NAME = 20;

// 形象（对齐 mac 版 CatAnimationState.displayName）。
// PET_STATES 是「可点着切换」的四态；hide（贴边躲藏）由拖到屏幕侧边 / 右键「躲起来」触发，
// 面板形象区照样展示它（能预览、能上传探头图），但不能手动切：窗口没吸附就切过去，
// 等于把半个身子晾在屏外，所以它不进切换列表，只作为可持有图的形象存在。
const HIDE_STATE = 'hide';
const PET_STATES = [
  { id: 'focus', label: '专注' },
  { id: 'idel', label: '休闲' },
  { id: 'sleep', label: '睡觉' },
  { id: 'pet', label: '抚摸' },
];
const HIDE_STATE_INFO = { id: HIDE_STATE, label: '躲藏', switchable: false };

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

/** 随机取一个宠物名 */
function randomPetName() {
  return PET_NAME_POOL[Math.floor(Math.random() * PET_NAME_POOL.length)];
}

/** 当前宠物名称：没设过就随机取一个并落盘，保证心跳与面板读到同一个稳定名字 */
function currentPetName() {
  const saved = String(config.get('petName') || '').trim();
  if (saved) return saved;
  const picked = randomPetName();
  config.set('petName', picked);
  return picked;
}

/** 当前宠物大小 */
function currentPetScale() {
  return clampScale(config.get('petScale'));
}

// 每日天气提醒（对齐 mac 版 WeatherReminderService：默认 08:00，城市留空按定位）
const WEATHER_DEFAULT_HOUR = 8;
const WEATHER_DEFAULT_MINUTE = 0;
const MAX_WEATHER_CITY = 40;

/** 时间分量收敛：脏数据回落默认值 */
function clampPart(value, max, fallback) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < 0 || n > max) return fallback;
  return n;
}

/** 是否是合法形象 id（含不进切换列表、但要能上传/持久化自定义图的躲藏态） */
function isValidPetState(state) {
  return PET_STATES.some((s) => s.id === state) || state === HIDE_STATE;
}

/** 是否允许面板点着切换（躲藏态只可视化/可换图，切换仍只由贴边吸附与右键驱动） */
function isSwitchablePetState(state) {
  return PET_STATES.some((s) => s.id === state);
}

/** 面板形象区列表：四个可切换态 + 只读但可上传图的躲藏态 */
function panelPetStates() {
  return [...PET_STATES.map((s) => ({ id: s.id, label: s.label, switchable: true })), { ...HIDE_STATE_INFO }];
}

/** 当前所有可持有形象图的状态（含不进切换列表的躲藏态，供自定义图快照遍历） */
function allPetStateIds() {
  return [...PET_STATES.map((s) => s.id), HIDE_STATE];
}

class SettingsService {
  /**
   * @param {object} [opts]
   * @param {{ restart: () => void, triggerNow: () => void }} [opts.scheduler] 提醒调度器
   * @param {object} [opts.providers] 只读数据来源（版本号 / 宠物号 / 当前形象 / 开机自启状态 / 权限）
   */
  constructor({ scheduler, providers = {} } = {}) {
    this.scheduler = scheduler;
    // 主动搭话调度器（index.js 建好气泡窗后回填）：改配置时要重挂周期定时器
    this.proactiveChat = null;
    this.providers = {
      version: () => '',
      petNo: () => 0,
      petState: () => 'focus',
      autoLaunch: () => false,
      heartbeat: () => null,
      isFullAccess: () => false,
      // 自定义状态图片快照（index.js 用 pet-image-flow 回填）：没接上时给空对象，面板按「什么都没有」渲染
      petImages: () => ({}),
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
        states: panelPetStates(),
      },
      general: {
        version: this.providers.version(),
        autoLaunch: Boolean(this.providers.autoLaunch()),
        heartbeat: normalizeHeartbeat(this.providers.heartbeat()),
      },
      // 权限（对标 mac 版通用设置 > 权限：校验码解锁全部功能）
      access: {
        fullAccess: Boolean(this.providers.isFullAccess()),
      },
      // 每日天气提醒（提醒设置分区；开启需先解锁，天气接口按量付费）
      weatherReminder: {
        enabled: Boolean(config.get('weatherReminderEnabled')),
        hour: clampPart(config.get('weatherReminderHour'), 23, WEATHER_DEFAULT_HOUR),
        minute: clampPart(config.get('weatherReminderMinute'), 59, WEATHER_DEFAULT_MINUTE),
        city: String(config.get('weatherReminderCity') || ''),
      },
      // 菜单设置（对齐 mac 版 ContextMenuPrefs：勾选宠物右键菜单里要展示的功能项）
      menu: {
        items: contextMenuPrefs.panelItems(),
      },
      // 主动搭话（对齐 mac 版 fillReminderSection 卡片 3：开关 + 15/30/60 分钟预设）
      proactiveChat: {
        enabled: proactiveChat.proactiveChatEnabled(),
        minutes: proactiveChat.currentChatInterval(),
        presets: proactiveChat.CHAT_PRESETS.slice(),
        min: proactiveChat.MIN_CHAT_INTERVAL,
        max: proactiveChat.MAX_CHAT_INTERVAL,
      },
      // 自定义状态图片（宠物信息分区）：busy / 配额 / 各状态可用性，纯本机 + 缓存，打开面板不走网络
      petImages: this.providers.petImages(),
    };
  }

  /**
   * 写主动搭话（局部更新：只改传了的字段）→ 立即按新节奏重建周期搭话。
   * 对齐 mac 版 chatToggle / chatIntervalButtonClicked → restartProactiveChat。
   * @param {{enabled?: boolean, intervalMinutes?: number}} patch
   */
  setProactiveChat(patch = {}) {
    if (typeof patch.enabled === 'boolean') {
      config.set(proactiveChat.ENABLED_KEY, patch.enabled);
    }
    if (patch.intervalMinutes !== undefined) {
      const n = Number(patch.intervalMinutes);
      if (!Number.isInteger(n) || n < proactiveChat.MIN_CHAT_INTERVAL || n > proactiveChat.MAX_CHAT_INTERVAL) {
        return {
          ok: false,
          error: `搭话间隔需为 ${proactiveChat.MIN_CHAT_INTERVAL}～${proactiveChat.MAX_CHAT_INTERVAL} 之间的整数分钟`,
          chat: this.load().proactiveChat,
        };
      }
      config.set(proactiveChat.INTERVAL_KEY, n);
    }
    // 改完就按新节奏重挂周期定时器（不重跑启动首句，避免立刻冒两句）
    if (this.proactiveChat) this.proactiveChat.restart();
    return { ok: true, chat: this.load().proactiveChat };
  }

  /**
   * 写右键菜单项展示开关（即改即生效，下次弹出菜单就应用）。
   * @param {string} key 菜单项标识
   * @param {*} visible 是否展示
   */
  setMenuItemVisible(key, visible) {
    if (!contextMenuPrefs.isValidKey(key)) {
      return { ok: false, error: '未知的菜单项', items: contextMenuPrefs.panelItems() };
    }
    const value = contextMenuPrefs.setVisible(visible, key);
    return { ok: true, key, visible: value, items: contextMenuPrefs.panelItems() };
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
   * 写入宠物名称：空输入随机取一个新名字（首次默认名也是随机）。
   * @param {*} name
   */
  setPetName(name) {
    const trimmed = String(name == null ? '' : name).trim();
    if (trimmed.length > MAX_PET_NAME) {
      return { ok: false, error: `名称最多 ${MAX_PET_NAME} 个字符`, name: currentPetName() };
    }
    const value = trimmed || randomPetName();
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

  /**
   * 写每日天气提醒（局部更新：只改传了的字段）。
   * 开启需先解锁（对齐 mac 版：基础权限不开启，天气接口按量付费）。
   * @param {{enabled?: boolean, hour?: number, minute?: number, city?: string}} patch
   */
  setWeatherReminder(patch = {}) {
    if (!this.providers.isFullAccess()) {
      return { ok: false, error: '需解锁全部功能后可用（天气接口按量付费）', weather: this.load().weatherReminder };
    }
    if (typeof patch.enabled === 'boolean') config.set('weatherReminderEnabled', patch.enabled);
    if (patch.hour !== undefined) {
      const n = Number(patch.hour);
      if (!Number.isInteger(n) || n < 0 || n > 23) {
        return { ok: false, error: '小时需为 0～23 的整数', weather: this.load().weatherReminder };
      }
      config.set('weatherReminderHour', n);
    }
    if (patch.minute !== undefined) {
      const n = Number(patch.minute);
      if (!Number.isInteger(n) || n < 0 || n > 59) {
        return { ok: false, error: '分钟需为 0～59 的整数', weather: this.load().weatherReminder };
      }
      config.set('weatherReminderMinute', n);
    }
    if (patch.city !== undefined) {
      const city = String(patch.city).trim();
      if (city.length > MAX_WEATHER_CITY) {
        return { ok: false, error: `城市名最多 ${MAX_WEATHER_CITY} 个字符`, weather: this.load().weatherReminder };
      }
      config.set('weatherReminderCity', city);
    }
    return { ok: true, weather: this.load().weatherReminder };
  }
}

module.exports = {
  SettingsService,
  currentInterval,
  currentPetName,
  currentPetScale,
  clampScale,
  isValidPetState,
  isSwitchablePetState,
  panelPetStates,
  allPetStateIds,
  HIDE_STATE,
  randomPetName,
  PET_STATES,
  PET_NAME_POOL,
  PRESETS,
  KEY,
  MIN_SCALE,
  MAX_SCALE,
  MAX_PET_NAME,
  WEATHER_DEFAULT_HOUR,
  WEATHER_DEFAULT_MINUTE,
  MAX_WEATHER_CITY,
};
