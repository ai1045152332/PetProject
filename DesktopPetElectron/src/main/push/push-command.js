// src/main/push-command.js
// 运营推送指令的客户端执行器：服务端随心跳下发 commands，这里按 kind 分派并做去重。
//   update → 触发一次「用户主动」更新检查（等同点托盘「检查更新」）
//   text   → 弹文字卡（可配置自动关闭时长）
//   video  → 弹视频窗（播完自动关）
// 去重：同一 id 只执行一次（服务端已按设备标记下发，这里是崩在「收到但没执行完」时的兜底）。
'use strict';

const config = require('../core/config-store');

const EXECUTED_KEY = 'executedPushIds';
const KEEP = 100;

/** 读出已执行过的指令 id（脏数据回落空数组） */
function executedIds() {
  const saved = config.get(EXECUTED_KEY);
  return Array.isArray(saved) ? saved.map(String) : [];
}

/** 记一笔已执行（只保留最近 100 个，避免配置无限增长） */
function markExecuted(id) {
  const list = executedIds();
  if (list.includes(id)) return;
  list.push(id);
  config.set(EXECUTED_KEY, list.slice(-KEEP));
}

/**
 * 创建指令执行器。
 * @param {object} deps
 * @param {(cmd: object) => void} deps.onUpdate 触发更新检查
 * @param {(cmd: object) => void} deps.onText   弹文字卡
 * @param {(cmd: object) => void} deps.onVideo  弹视频窗
 * @returns {{handle: (commands: Array) => number}}
 */
function createPushCommands({ onUpdate, onText, onVideo } = {}) {
  /** 执行单条；返回是否真的执行了 */
  function run(cmd) {
    switch (cmd.kind) {
      case 'update':
        if (onUpdate) onUpdate(cmd);
        return true;
      case 'text':
        if (onText) onText(cmd);
        return true;
      case 'video':
        if (onVideo) onVideo(cmd);
        return true;
      default:
        return false;
    }
  }

  return {
    /**
     * 处理一次心跳下发的指令数组。
     * @param {Array<object>} commands
     * @returns {number} 实际执行条数
     */
    handle(commands) {
      const list = Array.isArray(commands) ? commands : [];
      const seen = new Set(executedIds());
      let ran = 0;
      for (const cmd of list) {
        const id = String((cmd && cmd.id) || '');
        if (!cmd || !id || seen.has(id)) continue;
        seen.add(id);
        markExecuted(id);
        try {
          if (run(cmd)) ran += 1;
        } catch (e) {
          console.warn(`[push] 指令 ${id}（${cmd.kind}）执行失败: ${e.message}`);
        }
      }
      if (ran) console.log(`[push] 本次执行 ${ran} 条运营推送`);
      return ran;
    },
  };
}

module.exports = { createPushCommands, executedIds, markExecuted, EXECUTED_KEY };
