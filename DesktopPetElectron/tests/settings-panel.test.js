// tests/settings-panel.test.js
// 设置面板回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：五项导航用到的基础数据、间隔预设/区间校验、持久化、改完立即重启计时、脏数据回落、名称/大小校验
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const Module = require('module');

const USER_DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-settings-test-'));

// ── mock electron（config-store 只用到 app.getPath）──
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return { app: { getPath: () => USER_DATA } };
  }
  return origLoad.apply(this, arguments);
};

const SRC = path.join(__dirname, '..', 'src', 'main');
const config = require(path.join(SRC, 'config-store.js'));
const {
  clampInterval,
  isValidInterval,
  MIN_INTERVAL,
  MAX_INTERVAL,
} = require(path.join(SRC, 'reminder-scheduler.js'));
const {
  SettingsService,
  PRESETS,
  KEY,
  PET_STATES,
  isValidPetState,
  clampScale,
  DEFAULT_PET_NAME,
  MAX_PET_NAME,
} = require(path.join(SRC, 'settings-service.js'));
const { scaledSize } = require(path.join(SRC, 'pet-window.js'));

let failed = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed += 1;
  console.log(`${ok ? '✅' : '❌'} ${name}${ok ? '' : ` → 期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`}`);
}

// 假的调度器：只记录被调用的次数
function fakeScheduler() {
  const state = { restart: 0, triggerNow: 0 };
  return {
    state,
    restart() { state.restart += 1; },
    triggerNow() { state.triggerNow += 1; },
  };
}

// ── 1. 间隔收敛（对齐 mac 版 setter：max(1, min(v, 120))）──
check('clampInterval(45) = 45', clampInterval(45), 45);
check('clampInterval("45") 字符串也认', clampInterval('45'), 45);
check('clampInterval(0) 回落默认 30', clampInterval(0), 30);
check('clampInterval(-5) 回落默认 30', clampInterval(-5), 30);
check('clampInterval(NaN) 回落默认 30', clampInterval(NaN), 30);
check('clampInterval("abc") 回落默认 30', clampInterval('abc'), 30);
check('clampInterval(200) 截到上限 120', clampInterval(200), 120);
check('clampInterval(1) 保留下限', clampInterval(1), 1);

// ── 2. 用户输入严格校验 ──
check('isValidInterval(30) = true', isValidInterval(30), true);
check('isValidInterval(0) = false', isValidInterval(0), false);
check('isValidInterval(121) = false', isValidInterval(121), false);
check('isValidInterval(30.5) = false（必须整数）', isValidInterval(30.5), false);
check('isValidInterval("30") = true（IPC 可能传字符串）', isValidInterval('30'), true);
check('isValidInterval(null) = false', isValidInterval(null), false);

// ── 3. load()：五个分区用到的基础数据 ──
const scheduler = fakeScheduler();
const service = new SettingsService({
  scheduler,
  providers: {
    version: () => 'electron0.0.1',
    petNo: () => 100003,
    petState: () => 'idel',
    autoLaunch: () => true,
    heartbeat: () => ({
      lastAttemptAt: 1000,
      lastSuccessAt: 2000,
      lastError: '',
      successCount: 3,
      intervalSec: 60,
      url: 'http://101.96.248.75/api/heartbeat',
      sending: false,
    }),
  },
});

const initial = service.load();
check('初始间隔 30 分钟（与 mac 版 defaultReminderInterval 一致）', initial.reminder.minutes, 30);
check('预设为 15/30/45/60', initial.reminder.presets, [15, 30, 45, 60]);
check('PRESETS 常量一致', PRESETS, [15, 30, 45, 60]);
check('合法区间 1～120', [initial.reminder.min, initial.reminder.max], [MIN_INTERVAL, MAX_INTERVAL]);
check('宠物名称默认毛豆', initial.pet.name, DEFAULT_PET_NAME);
check('宠物号来自 provider', initial.pet.petNo, 100003);
check('当前形象来自 provider', initial.pet.state, 'idel');
check('宠物大小默认 1', initial.pet.scale, 1);
check('形象列表与 mac 版 displayName 一致（不含 hide）', initial.pet.states, [
  { id: 'focus', label: '专注' },
  { id: 'idel', label: '休闲' },
  { id: 'sleep', label: '睡觉' },
  { id: 'pet', label: '抚摸' },
]);
check('通用区版本号来自 provider', initial.general.version, 'electron0.0.1');
check('通用区开机自启来自 provider', initial.general.autoLaunch, true);
check('心跳状态透传到通用区', initial.general.heartbeat, {
  lastAttemptAt: 1000,
  lastSuccessAt: 2000,
  lastError: '',
  successCount: 3,
  intervalSec: 60,
  url: 'http://101.96.248.75/api/heartbeat',
  sending: false,
});

// 未注入心跳 provider 时归一化为空状态，面板显示「等待首次上报」而不是崩
const bare = new SettingsService({ scheduler }).load().general.heartbeat;
check('心跳默认区间 60s', bare.intervalSec, 60);
check('心跳默认无成功时间', bare.lastSuccessAt, 0);
check('心跳默认无错误', bare.lastError, '');
check('心跳默认 url 为空', bare.url, '');

// ── 4. setInterval：写入 + 立即重启计时 ──
let res = service.setInterval(45);
check('设置 45 分钟返回成功', res, { ok: true, minutes: 45 });
check('配置已持久化到 drinkWaterInterval', config.get(KEY), 45);
check('改完立即重启计时（对齐 restartDrinkWaterReminder）', scheduler.state.restart, 1);
check('load() 反映新值', service.load().reminder.minutes, 45);

res = service.setInterval('60');
check('字符串 "60" 也能设置', res, { ok: true, minutes: 60 });

// ── 5. 非法间隔：不写配置、不重启计时 ──
const before = config.get(KEY);
const restartsBefore = scheduler.state.restart;
for (const bad of [0, -1, 121, 30.5, 'abc', null, undefined, '']) {
  res = service.setInterval(bad);
  check(`非法间隔 ${JSON.stringify(bad)} 被拒绝`, res.ok, false);
  check(`非法间隔 ${JSON.stringify(bad)} 回填当前值`, res.minutes, before);
}
check('非法间隔不写配置', config.get(KEY), before);
check('非法间隔不重启计时', scheduler.state.restart, restartsBefore);

// ── 6. 宠物名称：空值回落默认、超长拒绝（对齐 PetName.setName）──
config.set('petName', '');
check('空名称读成默认名', service.load().pet.name, DEFAULT_PET_NAME);

res = service.setPetName('  汤圆  ');
check('保存名称会去首尾空格', res, { ok: true, name: '汤圆' });
check('名称已持久化', config.get('petName'), '汤圆');

res = service.setPetName('   ');
check('空输入保存回退默认名', res, { ok: true, name: DEFAULT_PET_NAME });
check('默认名已写入配置', config.get('petName'), DEFAULT_PET_NAME);

res = service.setPetName('x'.repeat(MAX_PET_NAME + 1));
check('超长名称被拒绝', res.ok, false);
check('超长名称不动配置', config.get('petName'), DEFAULT_PET_NAME);

// ── 7. 宠物大小：0.5~2.0 校验 + 窗口尺寸换算 ──
res = service.setPetScale(1.4);
check('设置 1.4x 成功', res, { ok: true, scale: 1.4 });
check('宠物大小已持久化', config.get('petScale'), 1.4);
check('窗口尺寸随缩放置换（200 × 1.4 = 280）', scaledSize(1.4), 280);
check('0.5x → 100px', scaledSize(0.5), 100);
check('2.0x → 400px', scaledSize(2), 400);
check('滑杆给字符串也认', scaledSize('1.5'), 300);
check('脏数据按 1x 兜底', scaledSize('oops'), 200);

for (const bad of [0.4, 2.1, 'abc', null]) {
  res = service.setPetScale(bad);
  check(`非法大小 ${JSON.stringify(bad)} 被拒绝`, res.ok, false);
  check(`非法大小 ${JSON.stringify(bad)} 回填当前值`, res.scale, 1.4);
}
check('非法大小不写配置', config.get('petScale'), 1.4);
check('clampScale(5) 截到上限 2', clampScale(5), 2);
check('clampScale(0) 截到下限 0.5', clampScale(0), 0.5);

// ── 8. 形象 id 校验（只接受四个可见形象）──
check('focus 合法', isValidPetState('focus'), true);
check('pet 合法', isValidPetState('pet'), true);
check('hide 不在面板可选项里', isValidPetState('hide'), false);
check('PET_STATES 长度为 4', PET_STATES.length, 4);

// ── 9. 脏数据回落：配置文件被手工改坏也能安全启动 ──
config.set(KEY, 999);
check('配置 999 → 读到上限 120', service.load().reminder.minutes, 120);
config.set(KEY, 0);
check('配置 0 → 回落默认 30', service.load().reminder.minutes, 30);
config.set(KEY, 'oops');
check("配置 'oops' → 回落默认 30", service.load().reminder.minutes, 30);

// ── 10. 测试提醒只弹窗，不改配置、不影响计时 ──
config.set(KEY, 30);
const restartsBeforeTest = scheduler.state.restart;
service.testReminder();
check('测试提醒触发一次', scheduler.state.triggerNow, 1);
check('测试提醒不重启计时', scheduler.state.restart, restartsBeforeTest);
check('测试提醒不改配置', config.get(KEY), 30);

console.log(failed === 0 ? '\n全部通过' : `\n${failed} 项失败`);
process.exit(failed === 0 ? 0 : 1);
