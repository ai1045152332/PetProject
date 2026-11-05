// src/main/swift-migration.js
//
// ⚠️ 临时代码（2026-11 引入）：只为「Swift 老用户升级到 Electron 版」这一次迁移服务。
//   等线上 Swift 用户基本升级完（或 version 通道发出几版后），可整文件删除；
//   删除时同步去掉 index.js 里的 require + app.whenReady 首次调用，以及本文件在 README 的说明。
//   熔断：PET_DISABLE_SWIFT_MIGRATION=1 可跳过（出问题时不改代码就能关掉）。
//
// macOS 从 Swift 原生版迁移到 Electron 版时，一次性把老 App 的本地数据搬过来。
//
// 老数据都在 UserDefaults 里（域 com.desktoppetformacapp.app），Electron 用 pet-config.json：
//   settings.petName / drinkWaterInterval / catScale / accessLevel / accessCode /
//   weatherReminder* / proactiveChat.* / todoReminder.repeatMinutes / shownFriendRequestIDs
//   desktoppetformacapp.todos（Data，JSONEncoder 的 [TodoItem]）
//
// 只搬「Electron 侧还没有」的键，搬完写 migratedFromSwift 标记，绝不覆盖已有配置。
// 自定义形象图不用搬：两边共用 ~/Library/Application Support/DesktopPetForMacApp/CustomSprites。
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const todoStore = require('../reminders/todo-store');

// 老 App 的 UserDefaults 域（= CFBundleIdentifier）
const SWIFT_DOMAIN = 'com.desktoppetformacapp.app';
// Swift Date 的 JSONEncoder 默认编码：自 2001-01-01 起的秒数
const APPLE_EPOCH_OFFSET = 978307200;

/** 老 App 的 plist 候选路径：未沙盒在 Preferences；万一被沙盒过再兜一层容器路径 */
function plistCandidates() {
  const home = os.homedir();
  return [
    path.join(home, 'Library', 'Preferences', `${SWIFT_DOMAIN}.plist`),
    path.join(home, 'Library', 'Containers', SWIFT_DOMAIN, 'Data', 'Library', 'Preferences', `${SWIFT_DOMAIN}.plist`),
  ];
}

function xmlUnescape(text) {
  return String(text)
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/**
 * 把 XML plist 里的「标量键值」抽出来。
 * 不用 plutil -convert json：老 App 的 plist 里有 <data>（Finder 状态、Todo），
 * 转 JSON 会直接报 invalid object。这里只认 string / integer / real / true / false / data，
 * 字典与数组值跳过——迁移用到的键全是标量。
 */
function parseScalarPlist(xml) {
  const re = /<key>([\s\S]*?)<\/key>\s*(<string>[\s\S]*?<\/string>|<integer>[\s\S]*?<\/integer>|<real>[\s\S]*?<\/real>|<true\s*\/>|<false\s*\/>|<data>[\s\S]*?<\/data>)/g;
  const out = {};
  let m;
  while ((m = re.exec(xml)) !== null) {
    const key = xmlUnescape(m[1]);
    const raw = m[2];
    if (raw.startsWith('<string>')) {
      out[key] = xmlUnescape(raw.slice(8, -9));
    } else if (raw.startsWith('<integer>')) {
      out[key] = Number(raw.slice(9, -10));
    } else if (raw.startsWith('<real>')) {
      out[key] = Number(raw.slice(6, -7));
    } else if (raw.startsWith('<true')) {
      out[key] = true;
    } else if (raw.startsWith('<false')) {
      out[key] = false;
    } else if (raw.startsWith('<data>')) {
      // base64（plist 会折行）→ 原样保留给调用方按 base64 解
      out[key] = raw.slice(6, -7).replace(/\s+/g, '');
    }
  }
  return out;
}

/**
 * 读出老 App 的 UserDefaults（键 → 值）。读不到返回 null。
 * 走 plutil 转 XML：不依赖 defaults 命令，也不会触发 CFPreferences 缓存。
 */
function readSwiftDefaults() {
  if (process.platform !== 'darwin') return null;
  const file = plistCandidates().find((p) => {
    try { return fs.statSync(p).isFile(); } catch (e) { return false; }
  });
  if (!file) return null;
  try {
    const xml = execFileSync('/usr/bin/plutil', ['-convert', 'xml1', '-o', '-', file], {
      encoding: 'utf8',
      timeout: 5000,
    });
    return parseScalarPlist(xml);
  } catch (e) {
    console.warn(`[migrate] 读取 Swift 配置失败: ${e.message}`);
    return null;
  }
}

/** 取整并夹到区间；非法值返回 null（保持 Electron 侧默认） */
function clampInt(value, min, max) {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.min(max, Math.max(min, Math.round(n)));
}

function clampFloat(value, min, max) {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.min(max, Math.max(min, n));
}

function asBool(value) {
  return value === true || value === 1 || value === '1' || value === 'true';
}

/** Swift Date（自 2001-01-01 的秒，可能是浮点）→ epoch 毫秒；非法返回 null */
function appleDateToMs(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  return Math.round((n + APPLE_EPOCH_OFFSET) * 1000);
}

/** 老 TodoItem[] → Electron todo-store 的 {id,text,due(epoch 秒),lastNotifiedAt(ms)} */
function convertTodos(base64) {
  if (typeof base64 !== 'string' || !base64) return [];
  let list;
  try {
    list = JSON.parse(Buffer.from(base64, 'base64').toString('utf8'));
  } catch (e) {
    console.warn(`[migrate] Todo 解析失败: ${e.message}`);
    return [];
  }
  if (!Array.isArray(list)) return [];
  return list
    .map((item) => {
      const text = String((item && item.text) || '').trim();
      const id = String((item && item.id) || '');
      if (!id || !text) return null;
      const dueMs = appleDateToMs(item.dueDate);
      const notifiedMs = appleDateToMs(item.lastNotifiedAt);
      return {
        id,
        text: text.slice(0, 200),
        due: dueMs ? Math.round(dueMs / 1000) : null,
        lastNotifiedAt: notifiedMs || null,
      };
    })
    .filter(Boolean);
}

/**
 * 执行迁移（幂等：跑过一次就写标记）。
 * @param {object} deps
 * @param {object} deps.config config-store 实例
 * @returns {{migrated: boolean, keys: string[], todos: number, reason?: string}}
 */
function migrateFromSwift(config, deps = {}) {
  const store = deps.todoStore || todoStore;
  if (process.env.PET_DISABLE_SWIFT_MIGRATION === '1') {
    return { migrated: false, keys: [], todos: 0, reason: 'disabled' };
  }
  if (process.platform !== 'darwin') return { migrated: false, keys: [], todos: 0, reason: 'not-macos' };
  if (config.get('migratedFromSwift')) return { migrated: false, keys: [], todos: 0, reason: 'already' };

  const prefs = readSwiftDefaults();
  if (!prefs) {
    // 没装过老版本：直接打标记，之后不再探测
    config.set('migratedFromSwift', true);
    return { migrated: false, keys: [], todos: 0, reason: 'no-swift-data' };
  }

  // Electron 已经有用户数据（老用户自己配过）：不覆盖，只打标记
  const existingName = String(config.get('petName') || '').trim();
  const existingTodos = store.load();
  if (existingName || existingTodos.length) {
    config.set('migratedFromSwift', true);
    return { migrated: false, keys: [], todos: 0, reason: 'electron-data-exists' };
  }

  const applied = [];
  const put = (key, value) => {
    if (value === null || value === undefined) return;
    config.set(key, value);
    applied.push(key);
  };

  put('petName', String(prefs['settings.petName'] || '').trim().slice(0, 20) || null);
  put('drinkWaterInterval', clampInt(prefs['settings.drinkWaterInterval'], 1, 120));
  put('petScale', clampFloat(prefs['settings.catScale'], 0.5, 2.0));
  put('todoReminderRepeatMinutes', clampInt(prefs['settings.todoReminder.repeatMinutes'], 1, 240));

  if (prefs['settings.weatherReminderEnabled'] !== undefined) {
    put('weatherReminderEnabled', asBool(prefs['settings.weatherReminderEnabled']));
  }
  put('weatherReminderHour', clampInt(prefs['settings.weatherReminderHour'], 0, 23));
  put('weatherReminderMinute', clampInt(prefs['settings.weatherReminderMinute'], 0, 59));
  put('weatherReminderCity', String(prefs['settings.weatherReminderCity'] || '').trim() || null);

  if (prefs['settings.proactiveChat.enabled'] !== undefined) {
    put('proactiveChatEnabled', asBool(prefs['settings.proactiveChat.enabled']));
  }
  put('proactiveChatIntervalMinutes', clampInt(prefs['settings.proactiveChat.interval'], 1, 720));

  // 宠物号：服务端按 deviceId 记录，两边是同一台机器同一个 UUID，直接沿用能少一次注册
  put('petNo', clampInt(prefs['settings.myPetNo'], 1, Number.MAX_SAFE_INTEGER));

  // 权限：激活码与设备绑定，同一台机器复制过来仍然有效（启动后会向服务端复核）
  const level = String(prefs['settings.accessLevel'] || '').trim();
  if (level) put('accessLevel', level);
  const code = String(prefs['settings.accessCode'] || '').trim();
  if (code) put('accessCode', code);

  // 已弹过的好友申请 ID：搬过来避免升级后又把旧申请弹一遍
  const shown = prefs['settings.shownFriendRequestIDs'];
  if (Array.isArray(shown) && shown.length) put('shownFriendRequestIDs', shown.map(String));

  // Todo：直接写 Electron 的 pet-todos.json（老数据是 Data → plist 里是 base64）
  const todos = convertTodos(prefs['desktoppetformacapp.todos']);
  if (todos.length) store.save(todos);

  config.set('migratedFromSwift', true);
  console.log(`[migrate] 已从 Swift 版迁移：${applied.length} 项配置、${todos.length} 条 Todo`);
  return { migrated: true, keys: applied, todos: todos.length };
}

// 临时代码：删除本文件时一并移除 index.js 的调用
module.exports = {
  migrateFromSwift,
  readSwiftDefaults,
  parseScalarPlist,
  convertTodos,
  appleDateToMs,
  SWIFT_DOMAIN,
};
