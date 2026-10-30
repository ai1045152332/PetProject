// tests/update-heartbeat.test.js
// Electron 版心跳 / 自动更新的回归测试：node 直接跑（npm test），不依赖 electron 运行时。
// 通过劫持 require('electron') 提供最小 mock，再对真实模块做断言。
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const Module = require('module');

const USER_DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-electron-test-'));

// ── mock electron ──────────────────────────────────────────
const dialogs = [];
const opened = [];
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      app: {
        getVersion: () => APP_VERSION,
        getPath: () => USER_DATA,
        focus() {},
        quit() {},
      },
      dialog: {
        showMessageBox: async (opts) => {
          dialogs.push(opts);
          return { response: 1 }; // 一律选第二个按钮（稍后），避免测试真的去下载
        },
      },
      shell: { openPath: async () => '', showItemInFolder: (p) => opened.push(p) },
    };
  }
  return origLoad.apply(this, arguments);
};

const SRC = path.join(__dirname, '..', 'src', 'main');
const { isNewer, selectPackage, verifySignature, UpdateService } = require(path.join(SRC, 'update-service.js'));
const APP_VERSION = require(path.join(__dirname, '..', 'package.json')).version;
const { HeartbeatService } = require(path.join(SRC, 'heartbeat.js'));
const config = require(path.join(SRC, 'config-store.js'));

let failed = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed += 1;
  console.log(`${ok ? '✅' : '❌'} ${name}${ok ? '' : ` → 期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`}`);
}

// ── 1. 版本比较（与 mac 版 UpdateService.isNewer 同语义）──
check('v1.0.032 > v1.0.031', isNewer('v1.0.032', 'v1.0.031'), true);
check('v1.0.031 == v1.0.031', isNewer('v1.0.031', 'v1.0.031'), false);
check('0.0.10 > 0.0.2（数值比较，非字典序）', isNewer('0.0.10', '0.0.2'), true);
check('v1.0.31 == v1.0.031（数值相等）', isNewer('v1.0.31', 'v1.0.031'), false);
check('缺段补 0：v1.1 > v1.0.9', isNewer('v1.1', 'v1.0.9'), true);
check('electron 前缀：electron0.0.2 > electron0.0.1', isNewer('electron0.0.2', 'electron0.0.1'), true);
check('electron 前缀：electron0.0.1 == v0.0.1（前缀不影响序列）', isNewer('electron0.0.1', 'v0.0.1'), false);
check('electron 前缀：electron0.0.10 > electron0.0.2', isNewer('electron0.0.10', 'electron0.0.2'), true);

// ── 2. 平台选包：只认平台前缀字段，不回落到 mac 原生版字段 ──
const prefix = process.platform === 'win32' ? 'win' : 'mac';
const goodExt = process.platform === 'win32' ? '.exe' : '.dmg';
const manifest = {
  version: 'v1.0.031', file: 'cute-pet-v1.0.031.zip', sha256: 'a'.repeat(64), signature: 'sig', notes: 'mac 原生版说明',
  [`${prefix}Version`]: 'v0.0.2',
  [`${prefix}File`]: `DesktopPet-0.0.2${goodExt}`,
  [`${prefix}SHA256`]: 'b'.repeat(64),
  [`${prefix}Signature`]: 'dev-sig',
  [`${prefix}Notes`]: '托盘加检查更新',
};
const picked = selectPackage(manifest);
check('选中本平台字段', picked && [picked.version, picked.file, picked.notes],
  ['v0.0.2', `DesktopPet-0.0.2${goodExt}`, '托盘加检查更新']);
check('平台字段缺失时返回 null（不回落到 mac 原生版字段）',
  selectPackage({ version: 'v1.0.031', file: 'cute-pet.zip', sha256: 'x', signature: 'y' }), null);
check('扩展名不匹配时返回 null',
  selectPackage({ [`${prefix}File`]: 'pet.apk', [`${prefix}SHA256`]: 'x', [`${prefix}Signature`]: 'y' }), null);
check('版本号缺失时返回 null（不回落 mac 原生版 version，避免反复误判有新版本）',
  selectPackage({
    version: 'v9.9.9', notes: 'mac 原生版说明',
    [`${prefix}File`]: `DesktopPet${goodExt}`, [`${prefix}SHA256`]: 'x', [`${prefix}Signature`]: 'y',
  }), null);

// ── 3. Ed25519 验签（与 openssl pkeyutl -sign -rawin 生成的签名互通）──
// 取自 mac 版真实发布包 v1.0.031 的 zip 摘要与签名，用于确认公钥/编码方式与发布链路一致
const VECTOR = {
  sha256: 'c4f46cc23fcacb91383d511625c2bc759c4406af367499cebaa79f5788ac12c8',
  signature: 'MWh1GnQJ80FxYL3I7ZAyvD947hHEjMnBdeFrbGgWhCS3xX+uw1Mq837pkERYRXkujKMj8xoWnJHh8z2iNrgqDQ==',
};
check('真实发布签名通过', verifySignature(VECTOR.signature, VECTOR.sha256), true);
check('摘要被篡改则拒绝', verifySignature(VECTOR.signature, VECTOR.sha256.replace(/^./, (c) => (c === '0' ? '1' : '0'))), false);
check('签名非法则拒绝', verifySignature('not-base64!!', VECTOR.sha256), false);

// ── 4. 心跳上报体：字段与 mac 版 makePayload 对齐 ──
let captured = null;
global.fetch = async (url, opts) => {
  captured = { url, opts };
  return { ok: true, status: 200, json: async () => ({ code: 0, msg: 'ok', data: { petNo: 10086 } }) };
};

(async () => {
  const hb = new HeartbeatService({ getState: () => 'focus' });
  await hb.send();

  const payload = JSON.parse(captured.opts.body);
  check('请求地址', captured.url, `${config.get('serverBaseURL')}/api/heartbeat`);
  check('请求方法', captured.opts.method, 'POST');
  check('Content-Type', captured.opts.headers['Content-Type'], 'application/json');
  check('字段集合', Object.keys(payload).sort(),
    ['deviceId', 'hostname', 'machine', 'os', 'petName', 'petState', 'version'].sort());
  check('version 为 electron 前缀', payload.version, `electron${APP_VERSION}`);
  check('petState 来自状态机', payload.petState, 'focus');
  check('petName 默认毛豆', payload.petName, '毛豆');
  check('machine 为 CPU 架构', payload.machine, process.arch);
  // 服务端设备列表以 hostname 为唯一键：必须与 mac 原生版一致（小写），否则同一 deviceId 会变成两条记录
  check('hostname 已小写（与 mac 原生版 ProcessInfo.hostName 对齐）',
    payload.hostname === payload.hostname.toLowerCase(), true);
  check('hostname 与系统主机名小写一致', payload.hostname, os.hostname().toLowerCase());
  if (process.platform === 'darwin') {
    check('os 为 macOS 产品版本而非 Darwin 内核号', /^macOS Version \d+\.\d+/.test(payload.os), true);
  }
  check('deviceId 非空且已持久化', payload.deviceId.length > 0 && config.get('deviceId') === payload.deviceId, true);
  check('响应回填宠物号', config.get('petNo'), 10086);

  // 上报成功后状态可观测（成功本身静默，面板靠这几个字段判断「心跳是不是真通了」）
  const st = hb.getStatus();
  check('成功后记录成功时间', st.lastSuccessAt > 0, true);
  check('成功后累计次数', st.successCount, 1);
  check('成功后清空错误', st.lastError, '');
  check('状态里带上报间隔', st.intervalSec, 60);
  check('状态里带上报地址', st.url, `${config.get('serverBaseURL')}/api/heartbeat`);

  // 失败原因去重：同一原因连续出现只记一条
  const logs = [];
  const origWarn = console.warn;
  console.warn = (...args) => logs.push(args.join(' '));
  global.fetch = async () => { throw new Error('ECONNREFUSED'); };
  await hb.send();
  await hb.send();
  console.warn = origWarn;
  check('同一失败原因只记一条日志', logs.filter((l) => l.includes('ECONNREFUSED')).length, 1);
  check('未产生安装分发动作', opened.length, 0);
  check('失败后记录错误原因', hb.getStatus().lastError.includes('ECONNREFUSED'), true);

  // 看门狗：请求卡死（sending 一直为 true）时不能永久停摆，超时后自动解锁重发
  captured = null;
  global.fetch = async (url, opts) => {
    captured = { url, opts };
    return { ok: true, status: 200, json: async () => ({ code: 0, msg: 'ok', data: { petNo: 10086 } }) };
  };
  hb.sending = true;
  hb.sendStartedAt = Date.now() - 30 * 1000;
  await hb.send();
  check('卡死超过 2 个超时周期后自动重发', Boolean(captured), true);
  check('重发后 sending 已释放', hb.getStatus().sending, false);

  // 未到超时窗口时保持互斥，不叠加并发请求
  captured = null;
  hb.sending = true;
  hb.sendStartedAt = Date.now() - 1000;
  await hb.send();
  check('请求进行中不并发重发', captured, null);
  hb.sending = false;
  hb.sendStartedAt = 0;

  // ── 5. 检查更新：无本平台包 / 已是最新时的提示 ──
  dialogs.length = 0;
  global.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ code: 0, msg: 'ok', data: { version: 'v1.0.031', file: 'cute-pet.zip', sha256: 'x', signature: 'y' } }),
  });
  await new UpdateService({ onStatus: () => {} }).checkForUpdate({ userInitiated: true });
  check('无本平台包时提示暂无可用更新', dialogs[0] && dialogs[0].title, '暂无可用更新');

  const sameVersion = {
    [`${prefix}Version`]: 'electron0.0.1',
    [`${prefix}File`]: `DesktopPet${goodExt}`,
    [`${prefix}SHA256`]: 'x',
    [`${prefix}Signature`]: 'y',
  };
  dialogs.length = 0;
  global.fetch = async () => ({ ok: true, status: 200, json: async () => ({ code: 0, msg: 'ok', data: sameVersion }) });
  await new UpdateService({ onStatus: () => {} }).checkForUpdate({ userInitiated: true });
  check('版本一致时提示已是最新', dialogs[0] && dialogs[0].title, '已经是最新版本');

  // 自动检查（非用户触发）遇到无新版本时不打扰
  dialogs.length = 0;
  await new UpdateService({ onStatus: () => {} }).checkForUpdate({ userInitiated: false });
  check('自动检查无更新时不弹窗', dialogs.length, 0);

  // 网络异常：用户主动触发才提示失败，自动检查静默
  global.fetch = async () => { throw new Error('timeout'); };
  dialogs.length = 0;
  await new UpdateService({ onStatus: () => {} }).checkForUpdate({ userInitiated: false });
  check('自动检查失败时静默', dialogs.length, 0);
  await new UpdateService({ onStatus: () => {} }).checkForUpdate({ userInitiated: true });
  check('主动检查失败时提示', dialogs[0] && dialogs[0].title, '检查更新失败');

  console.log(`\n${failed === 0 ? '全部通过' : `${failed} 项失败`}`);
  process.exit(failed === 0 ? 0 : 1);
})();
