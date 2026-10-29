// src/main/heartbeat.js
// DesktopPetElectron — 心跳上报服务
// 移植自 mac 版 Services/HeartbeatService.swift：启动立刻上报一次，之后每 1 分钟一次
// 上报体与 mac 版字段一致，服务端（PetServer /api/heartbeat）无需区分客户端类型
'use strict';

const config = require('./config-store');
const info = require('./app-info');

const INTERVAL_MS = 60 * 1000;      // 上报间隔：1 分钟（与 mac 版一致）
const TIMEOUT_MS = 10 * 1000;       // 单次请求超时

function serverURL(pathname) {
  const base = (config.get('serverBaseURL') || '').replace(/\/+$/, '');
  return `${base}${pathname}`;
}

class HeartbeatService {
  /**
   * @param {object} [opts]
   * @param {() => string} [opts.getState] 返回宠物当前状态（focus/idel/sleep/pet/hide）
   */
  constructor({ getState } = {}) {
    this.getState = getState || (() => 'idel');
    this.timer = null;
    this.sending = false;
    // 心跳每 60s 一次，网络持续不通时同一原因只记一条，避免刷满日志（对齐 mac 版 lastLoggedFailure）
    this.lastFailure = '';
  }

  start() {
    if (this.timer) return;
    this.send();
    this.timer = setInterval(() => this.send(), INTERVAL_MS);
    console.log(`[heartbeat] 已启动，间隔 ${INTERVAL_MS / 1000}s → ${serverURL('/api/heartbeat')}`);
  }

  stop() {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  /** 组装上报体（字段与 mac 版 makePayload 一一对应） */
  makePayload() {
    return {
      version: info.currentVersion(),
      hostname: info.hostname(),
      os: info.osDescription(),
      machine: process.arch,
      petName: info.petName(),
      petState: this.getState(),
      deviceId: info.resolveDeviceId(),
    };
  }

  async send() {
    if (this.sending) return;
    this.sending = true;
    try {
      const res = await fetch(serverURL('/api/heartbeat'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(this.makePayload()),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });

      if (!res.ok) {
        this.recordFailure(`上报异常，状态码: ${res.status}`);
        return;
      }

      // 成功不写日志（每 60s 一条量级过大），只清空失败记录以便下次断开时重新记一条
      this.lastFailure = '';
      // 响应里可能带宠物号（带 deviceId 首跳时服务端自动分配），先缓存下来供后续好友功能使用
      const json = await res.json().catch(() => null);
      const petNo = json && json.data && json.data.petNo;
      if (Number.isInteger(petNo) && petNo > 0 && petNo !== config.get('petNo')) {
        config.set('petNo', petNo);
        console.log(`[heartbeat] 宠物号已分配: #${petNo}`);
      }
    } catch (e) {
      this.recordFailure(`上报失败: ${e.message}`);
    } finally {
      this.sending = false;
    }
  }

  recordFailure(message) {
    if (message === this.lastFailure) return;
    this.lastFailure = message;
    console.warn(`[heartbeat] ${message}`);
  }
}

module.exports = { HeartbeatService };
