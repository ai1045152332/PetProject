// src/main/app-info.js
// DesktopPetElectron — 运行时基础信息（版本号 / 设备 ID / 宠物名 / 系统描述）
// 对标 mac 版 AppVersion.swift + AccessControl.deviceID + PetName.currentName()
'use strict';

const os = require('os');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const { app } = require('electron');
const config = require('./config-store');

/** 版本前缀：与 mac 原生版的 v 前缀区分开，后台设备列表一眼能看出这是 Electron 版 */
const VERSION_PREFIX = 'electron';

/** 去掉 electron / v 前缀，只留纯数字版本（比较与拼接都用它） */
function normalizeVersion(value) {
  return String(value || '')
    .trim()
    .replace(/^electron/i, '')
    .replace(/^[vV]/, '')
    .trim();
}

/**
 * 当前版本号，统一为 electron0.0.1 形式。
 * 打包版读 electron-builder 写入的 package.json version；开发态同样可用。
 */
function currentVersion() {
  let v = '';
  try {
    v = app.getVersion() || '';
  } catch (e) {
    v = '';
  }
  if (!v) v = require('../../package.json').version || '0.0.1';
  const digits = normalizeVersion(v);
  // 版本号已在 package.json 里手写成 electron 前缀时不重复拼
  return String(v).trim().toLowerCase().startsWith(VERSION_PREFIX) ? String(v).trim() : `${VERSION_PREFIX}${digits}`;
}

/**
 * 设备唯一标识：与 mac 原生版保持同一来源，同一台 mac 上两版拿到同一个 ID（宠物号一致）。
 * macOS → IOPlatformUUID；Windows → 注册表 MachineGuid；取不到时生成随机 UUID 并持久化。
 */
function resolveDeviceId() {
  const cached = config.get('deviceId');
  if (cached) return cached;

  let id = '';
  try {
    if (process.platform === 'darwin') {
      const out = execFileSync('/usr/sbin/ioreg', ['-rd1', '-c', 'IOPlatformExpertDevice'], {
        encoding: 'utf8',
        timeout: 5000,
      });
      const m = out.match(/"IOPlatformUUID"\s*=\s*"([^"]+)"/);
      if (m) id = m[1];
    } else if (process.platform === 'win32') {
      const out = execFileSync('reg.exe', ['query', 'HKLM\\SOFTWARE\\Microsoft\\Cryptography', '/v', 'MachineGuid'], {
        encoding: 'utf8',
        timeout: 5000,
        windowsHide: true,
      });
      const m = out.match(/MachineGuid\s+REG_SZ\s+([0-9a-fA-F-]+)/);
      if (m) id = m[1];
    }
  } catch (e) {
    console.warn('[app-info] 读取硬件 ID 失败，回退随机 UUID:', e.message);
  }

  if (!id) id = crypto.randomUUID();
  config.set('deviceId', id);
  return id;
}

/** 宠物名称（设置面板可改；默认与 mac 版一致） */
function petName() {
  return config.get('petName') || '毛豆';
}

/** 系统描述，与 mac 原生版格式对齐：macOS Version 15.6.1 (Build 24G90) / Windows 10.0.22631 */
function osDescription() {
  if (process.platform === 'darwin') {
    // 原生版用 ProcessInfo.operatingSystemVersionString（形如 Version 15.6.1 (Build 24G90)），
    // 这里从 sw_vers 拿同样的字段，避免上报成 Darwin 内核号（os.release() 是 24.6.0，会认成 macOS 24）
    try {
      const out = execFileSync('/usr/bin/sw_vers', [], { encoding: 'utf8', timeout: 3000 });
      const version = /ProductVersion:\s*(\S+)/.exec(out);
      const build = /BuildVersion:\s*(\S+)/.exec(out);
      if (version && build) return `macOS Version ${version[1]} (Build ${build[1]})`;
      if (version) return `macOS Version ${version[1]}`;
    } catch (e) {
      console.warn('[app-info] sw_vers 读取失败，回退 Electron 系统版本:', e.message);
    }
    const fallback = typeof process.getSystemVersion === 'function' ? process.getSystemVersion() : os.release();
    return `macOS ${fallback}`;
  }
  if (process.platform === 'win32') {
    const v = typeof process.getSystemVersion === 'function' ? process.getSystemVersion() : os.release();
    return `Windows ${v}`;
  }
  return `${process.platform} ${os.release()}`;
}

/**
 * 主机名（服务端设备列表以它为唯一键）。
 * macOS 的 gethostname 返回系统 LocalHostName 的原始大小写（如 MBP-XXX.local），
 * 而 mac 原生版的 ProcessInfo.hostName 是小写——不统一会被服务端当成两台设备、同一宠物号出现两条记录。
 */
function hostname() {
  return (os.hostname() || 'unknown').toLowerCase();
}

module.exports = { currentVersion, normalizeVersion, resolveDeviceId, petName, osDescription, hostname };
