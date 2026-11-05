// src/main/config-store.js
// 极简配置持久化：存到 userData/pet-config.json
// 对标 mac 版 UserDefaults 的 settings.drinkWaterInterval
'use strict';

const fs = require('fs');
const path = require('path');
const { app } = require('electron');

const DEFAULTS = {
  drinkWaterInterval: 30, // 分钟
  petScale: 1.0, // 宠物大小（0.5~2.0，按 200×200 精灵图等比缩放）
  serverBaseURL: 'http://101.96.248.75', // PetServer 地址（与 mac 版 ServerConfig.baseURL 同源）
  petName: '', // 宠物名称，随心跳上报；留空表示尚未取名，首次启动随机取一个
  autoLaunchInitialized: false, // 是否已执行过「默认开启开机自启」的一次性初始化（用户之后可手动关）
  deviceId: '', // 设备唯一标识，首次启动由 app-info 解析后写回
  petNo: 0, // 服务端分配的宠物号，心跳响应回填
  lastUpdateCheckAt: 0, // 上次检查更新的时间戳（毫秒）
  winTrayHintShown: false, // Windows 是否已弹过「托盘图标被折进通知区」的引导气泡（只弹一次）
  todoReminderRepeatMinutes: 5, // 同一条 Todo 到期后重复提醒的间隔（分钟，对标 mac 版 settings.todoReminder.repeatMinutes）
  // 权限控制（对标 mac 版 AccessControl：settings.accessLevel / settings.accessCode）
  accessLevel: '', // 'full' = 校验码解锁全部功能；空 = 基础权限
  accessCode: '', // 解锁时用的服务端激活码（本地后门码不记录，供定时复核）
  // 每日天气提醒（对标 mac 版 WeatherReminderService，需解锁后才能开启）
  weatherReminderEnabled: false,
  weatherReminderHour: 8, // 0~23
  weatherReminderMinute: 0, // 0~59
  weatherReminderCity: '', // 留空按 IP 定位
  // 托盘「系统信息」勾选：指标是否显示在顶栏（键名对齐 mac 原生版 UserDefaults 的 menuBar.show*）
  'menuBar.showCPU': false,
  'menuBar.showMemory': false,
  'menuBar.showDisk': false,
  'menuBar.showNet': false,
};

function configPath() {
  return path.join(app.getPath('userData'), 'pet-config.json');
}

function load() {
  try {
    const raw = fs.readFileSync(configPath(), 'utf8');
    return { ...DEFAULTS, ...JSON.parse(raw) };
  } catch (e) {
    return { ...DEFAULTS };
  }
}

function save(data) {
  try {
    fs.mkdirSync(path.dirname(configPath()), { recursive: true });
    fs.writeFileSync(configPath(), JSON.stringify(data, null, 2), 'utf8');
  } catch (e) {
    console.error('[config-store] save failed:', e.message);
  }
}

function get(key) {
  return load()[key];
}

function set(key, value) {
  const data = load();
  data[key] = value;
  save(data);
}

/** 删除一个键（权限清除时用，避免留残留值） */
function remove(key) {
  const data = load();
  delete data[key];
  save(data);
}

module.exports = { load, save, get, set, remove, DEFAULTS };
