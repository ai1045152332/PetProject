// tests/push-command.test.js
// 运营推送指令执行器回归：按 kind 分派、同 id 只执行一次、未知类型忽略
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const Module = require('module');

const USER_DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-push-'));

const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return { app: { getPath: () => USER_DATA } };
  }
  return origLoad.apply(this, arguments);
};

const SRC = path.join(__dirname, '..', 'src', 'main');
const config = require(path.join(SRC, 'core', 'config-store.js'));
const { createPushCommands, executedIds, EXECUTED_KEY } = require(path.join(SRC, 'push', 'push-command.js'));

let failed = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed += 1;
  console.log(`${ok ? '✅' : '❌'} ${name}${ok ? '' : ` → 期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`}`);
}

const calls = [];
const run = createPushCommands({
  onUpdate: (cmd) => calls.push(['update', cmd.id]),
  onText: (cmd) => calls.push(['text', cmd.id]),
  onVideo: (cmd) => calls.push(['video', cmd.id]),
});

// 1. 三种类型分派
check('三种 kind 分别落到对应回调',
  run.handle([
    { id: 'a1', kind: 'update' },
    { id: 'a2', kind: 'text', text: 'hi' },
    { id: 'a3', kind: 'video', url: 'https://x/y.mp4' },
  ]), 3);
check('回调按顺序收到三类指令',
  calls.map((c) => c[0]), ['update', 'text', 'video']);

// 2. 同 id 不重复执行（服务端重发 / 客户端重启兜底）
calls.length = 0;
check('重复 id 不再执行', run.handle([{ id: 'a1', kind: 'update' }]), 0);
check('重复 id 回调没被调用', calls.length, 0);

// 3. 一批里重复也去重
calls.length = 0;
check('同一批内重复 id 只执行一次',
  run.handle([{ id: 'b1', kind: 'text', text: 'x' }, { id: 'b1', kind: 'text', text: 'x' }]), 1);

// 4. 未知 kind / 缺 id 忽略
calls.length = 0;
check('未知 kind 不执行也不报错', run.handle([{ id: 'c1', kind: 'nope' }]), 0);
check('缺 id 直接跳过', run.handle([{ kind: 'text', text: 'x' }]), 0);

// 5. 已执行 id 落到配置里，且只留最近 100 个
const ids = executedIds();
check('执行过的 id 已落盘（含 a1/a2/a3/b1）',
  ['a1', 'a2', 'a3', 'b1'].every((id) => ids.includes(id)), true);
for (let i = 0; i < 120; i += 1) run.handle([{ id: `bulk-${i}`, kind: 'update' }]);
check('已执行 id 只保留最近 100 个', executedIds().length, 100);
check('最老的 id 已被挤掉', executedIds().includes('a1'), false);
check('配置键名稳定', EXECUTED_KEY, 'executedPushIds');

// 6. 执行失败不影响后续指令
calls.length = 0;
const throwing = createPushCommands({
  onText: () => { throw new Error('boom'); },
  onUpdate: (cmd) => calls.push(['update', cmd.id]),
});
check('单条抛错不中断整批', throwing.handle([
  { id: 'd1', kind: 'text', text: 'x' },
  { id: 'd2', kind: 'update' },
]), 1);
check('后面的指令仍然执行', calls.map((c) => c[1]), ['d2']);

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
