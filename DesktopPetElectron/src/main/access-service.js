// src/main/access-service.js
// DesktopPetElectron — 权限控制系统（移植 mac 版 System/AccessControl.swift）
// 基础权限：只能用简单功能（显示 / 状态切换 / 喝水 / Todo 等）；
// 输入校验码解锁全部功能（天气、热点新闻、每日天气提醒等按量付费能力）。
// 校验规则与 mac 版一致：本地校验码 456 直接通过；否则请求后端 /api/access/verify
// （请求体用服务端公钥加密，见 crypto-envelope.js）。
// 定时复核（与版本检查同节奏）：仅当服务端明确判定失效才收回权限，网络异常保留。
'use strict';

const config = require('./config-store');
const info = require('./app-info');
const { encryptedEnvelope } = require('./crypto-envelope');

const LOCAL_CODE = '456';          // 本地后门码（与 mac 版 AccessControl.fullCode 一致）
const VERIFY_PATH = '/api/access/verify';
const TIMEOUT_MS = 8000;

const LEVEL_KEY = 'accessLevel';
const CODE_KEY = 'accessCode';
const FULL_LEVEL = 'full';

/** 归一化：大写、去掉非字母数字（与后端 normalizeCode 对齐） */
function normalizedCode(code) {
  return String(code || '')
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '');
}

/** 格式预检：归一化后应为 12 位（激活码 XXXX-XXXX-XXXX），避免误粘其它文本时只报「校验码错误」 */
function isPlausibleActivationCode(code) {
  return normalizedCode(code).length === 12;
}

function isFullAccess() {
  return config.get(LEVEL_KEY) === FULL_LEVEL;
}

/** 解锁时用的服务端激活码（本地后门码不记录，也不参与远程复核 / 云端图片） */
function serverActivationCode() {
  if (!isFullAccess()) return '';
  const code = String(config.get(CODE_KEY) || '');
  if (!code || code === LOCAL_CODE) return '';
  return normalizedCode(code);
}

function persistFullAccess(code) {
  config.set(LEVEL_KEY, FULL_LEVEL);
  if (code) config.set(CODE_KEY, code);
  else config.remove(CODE_KEY);
}

/** 清除权限，回到基础权限（高级功能锁定） */
function clearAccess() {
  config.remove(LEVEL_KEY);
  config.remove(CODE_KEY);
}

function serverURL(pathname) {
  const base = (config.get('serverBaseURL') || '').replace(/\/+$/, '');
  return `${base}${pathname}`;
}

/**
 * 请求后端校验激活码（激活码 + 设备 ID 加密后传输，不发明文）。
 * @returns {Promise<'success'|'invalidCode'|'expired'|'deviceLimit'|'networkError'|'localError'|'serverError'>}
 */
async function verifyRemote(code, deps = {}) {
  const doFetch = deps.fetch || fetch;
  const plain = JSON.stringify({
    code: normalizedCode(code),
    deviceId: deps.deviceId ? deps.deviceId() : info.resolveDeviceId(),
  });
  const body = encryptedEnvelope(plain);
  if (!body) return 'localError'; // 本地加密失败：放弃本次校验，绝不回退明文

  let res;
  try {
    res = await doFetch(serverURL(VERIFY_PATH), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (e) {
    console.warn(`[access] 校验码远程验证请求失败: ${e.message}`);
    return 'networkError';
  }
  if (!res.ok) return 'serverError';

  let json;
  try {
    json = await res.json();
  } catch (e) {
    return 'serverError';
  }
  const data = (json && json.data) || {};
  if (data.valid === true) return 'success';
  switch (data.reason) {
    case 'device_limit': return 'deviceLimit';
    case 'expired': return 'expired';
    default: return 'invalidCode';
  }
}

/**
 * 输入校验码解锁：先比对本地码，再走后端接口；通过则持久化为「全部功能」。
 * @returns {Promise<string>} 结果码（'success' 见 verifyRemote 各失败码；'badFormat' 格式预检失败）
 */
async function unlock(code, deps = {}) {
  const trimmed = String(code == null ? '' : code).trim();
  if (!trimmed) return 'invalidCode';
  // 本地校验码直接通过（不记录，避免参与远程复核）
  if (trimmed === LOCAL_CODE) {
    persistFullAccess(null);
    return 'success';
  }
  if (!isPlausibleActivationCode(trimmed)) return 'badFormat';
  const result = await verifyRemote(trimmed, deps);
  // 存归一化值（与后端存储形态一致），定时复核直接复用
  if (result === 'success') persistFullAccess(normalizedCode(trimmed));
  return result;
}

/**
 * 定时复核授权（与版本检查同节奏）：用解锁时记录的校验码请求服务端，
 * 仅当服务端明确判定无效（失效/过期/超设备数）才收回权限；网络异常保留。
 * @returns {Promise<'ok'|'skipped'|'revoked'>}
 */
async function revalidate(deps = {}) {
  if (!isFullAccess()) return 'skipped';
  const code = String(config.get(CODE_KEY) || '').trim();
  if (!code || code === LOCAL_CODE) return 'skipped'; // 旧版本未记录 / 本地后门码：不复核
  const result = await verifyRemote(code, deps);
  if (result === 'success') return 'ok';
  if (result === 'invalidCode' || result === 'expired' || result === 'deviceLimit') {
    console.warn(`[access] 定时复核未通过，收回权限: ${result}`);
    clearAccess();
    return 'revoked';
  }
  return 'skipped'; // 网络/服务异常等：保留现有权限
}

module.exports = {
  LOCAL_CODE,
  isFullAccess,
  serverActivationCode,
  clearAccess,
  unlock,
  revalidate,
  normalizedCode,
  isPlausibleActivationCode,
  verifyRemote,
};
