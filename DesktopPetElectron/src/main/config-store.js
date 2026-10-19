// src/main/config-store.js
// 极简配置持久化：存到 userData/pet-config.json
// 对标 mac 版 UserDefaults 的 settings.drinkWaterInterval
'use strict';

const fs = require('fs');
const path = require('path');
const { app } = require('electron');

const DEFAULTS = {
  drinkWaterInterval: 30, // 分钟
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
