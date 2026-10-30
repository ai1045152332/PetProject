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
   * @param {boolean} [opts.debug] 打印每次收发细节（HEARTBEAT_DEBUG=1 也可开启）
   */
  constructor({ getState, debug = process.env.HEARTBEAT_DEBUG === '1' } = {}) {
    this.getState = getState || (() => 'idel');
    this.timer = null;
    this.sending = false;
    this.sendStartedAt = 0;
    this.debug = debug;
    // 上报结果，供设置面板显示「心跳是否真的通着」（成功默认静默，光看日志无法判定）
    this.status = { lastAttemptAt: 0, lastSuccessAt: 0, lastError: '', successCount: 0 };
    // 心跳每 60s 一次，网络持续不通时同一原因只记一条，避免刷满日志（对齐 mac 版 lastLoggedFailure）
    this.lastFailure = '';
  }

  /** 上报状态快照（面板展示 / 排查用） */
  getStatus() {
    return {
      ...this.status,
      sending: this.sending,
      intervalSec: INTERVAL_MS / 1000,
      url: serverURL('/api/heartbeat'),
    };
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
    if (this.sending) {
      // 看门狗：上一次请求卡在 fetch/json 上（网络栈挂起、abort 未触发）会让 sending 永远为 true，
      // 心跳从此静默停摆且不报错。超过两个超时周期一律强制解锁重发。
      if (this.sendStartedAt && Date.now() - this.sendStartedAt > TIMEOUT_MS * 2) {
        const stuckSec = Math.round((Date.now() - this.sendStartedAt) / 1000);
        this.sending = false;
        this.recordFailure(`上次上报卡住 ${stuckSec}s 未返回，已重置`);
      } else {
        return;
      }
    }
    this.sending = true;
    const startedAt = Date.now();
    this.sendStartedAt = startedAt;
    const wasFailing = Boolean(this.lastFailure);
    try {
      const payload = this.makePayload();
      this.status.lastAttemptAt = startedAt;
      if (this.debug) {
        console.log(`[heartbeat] → POST v=${payload.version} device=${payload.deviceId} state=${payload.petState}`);
      }
      const res = await fetch(serverURL('/api/heartbeat'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });

      if (!res.ok) {
        this.recordFailure(`上报异常，状态码: ${res.status}`);
        return;
      }

      // 成功默认静默（每 60s 一条量级过大），但首报与「失败恢复」各记一条，便于确认通道真的通
      this.lastFailure = '';
      this.status.lastSuccessAt = Date.now();
      this.status.lastError = '';
      this.status.successCount += 1;
      if (this.debug) {
        console.log(`[heartbeat] ← ${res.status} ${Date.now() - startedAt}ms`);
      } else if (this.status.successCount === 1 || wasFailing) {
        console.log(`[heartbeat] 上报成功（累计 ${this.status.successCount} 次）`);
      }
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
      this.sendStartedAt = 0;
    }
  }

  recordFailure(message) {
    this.status.lastError = message;
    if (message === this.lastFailure) return;
    this.lastFailure = message;
    console.warn(`[heartbeat] ${message}`);
  }
}

module.exports = { HeartbeatService };
