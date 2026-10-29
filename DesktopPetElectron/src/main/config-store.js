// src/main/config-store.js
// 极简配置持久化：存到 userData/pet-config.json
// 对标 mac 版 UserDefaults 的 settings.drinkWaterInterval
'use strict';

const fs = require('fs');
const path = require('path');
const { app } = require('electron');

const DEFAULTS = {
  drinkWaterInterval: 30, // 分钟
  serverBaseURL: 'http://101.96.248.75', // PetServer 地址（与 mac 版 ServerConfig.baseURL 同源）
  petName: '毛豆', // 宠物名称，随心跳上报
  deviceId: '', // 设备唯一标识，首次启动由 app-info 解析后写回
  petNo: 0, // 服务端分配的宠物号，心跳响应回填
  lastUpdateCheckAt: 0, // 上次检查更新的时间戳（毫秒）
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

module.exports = { load, save, get, set, DEFAULTS };
