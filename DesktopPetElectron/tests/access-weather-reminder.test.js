// tests/access-weather-reminder.test.js
// 校验码权限 + 每日天气提醒回归测试：node 直接跑，mock electron / fetch
// 覆盖：混合加密信封格式（与服务端 HybridEnvelope 契约互验）、本地码解锁、格式预检、
//       远程校验各结果映射、定时复核收回策略、天气提醒调度（跨天/睡眠补偿/权限守卫）、
//       SettingsService 天气提醒读写与权限把关
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const Module = require('module');

const USER_DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-access-test-'));

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
const { encryptedEnvelope } = require(path.join(SRC, 'crypto-envelope.js'));
const access = require(path.join(SRC, 'access-service.js'));
const { createWeatherReminder, nextFireMs } = require(path.join(SRC, 'weather-reminder.js'));
const { SettingsService } = require(path.join(SRC, 'settings-service.js'));

let failed = 0;
function check(name, condition) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    console.error(`❌ ${name}`);
    failed += 1;
  }
}

async function main() {
  // ── 1. 混合加密信封：用测试生成的 RSA 私钥解一遍，验证与 Go 端 DecryptHybrid 同构 ──
  {
    const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'pkcs1', format: 'der' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    const plain = JSON.stringify({ code: 'ABCD1234EFGH', deviceId: 'dev-1' });
    const body = encryptedEnvelope(Buffer.from(plain), publicKey.toString('base64'));
    const envelope = JSON.parse(body);

    // RSA-OAEP(SHA-256) 解出 AES 密钥
    const aesKey = crypto.privateDecrypt(
      { key: privateKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
      Buffer.from(envelope.encryptedKey, 'base64'),
    );
    // nonce(12) + ciphertext + tag(16) 组合体 AES-256-GCM 解密
    const combined = Buffer.from(envelope.data, 'base64');
    const decipher = crypto.createDecipheriv('aes-256-gcm', aesKey, combined.subarray(0, 12));
    decipher.setAuthTag(combined.subarray(combined.length - 16));
    const recovered = Buffer.concat([
      decipher.update(combined.subarray(12, combined.length - 16)),
      decipher.final(),
    ]).toString('utf8');

    check('信封可被 RSA-OAEP-SHA256 + AES-256-GCM 解回原文（服务端契约同构）', recovered === plain);
    check('信封字段名对齐 HybridEnvelope（encryptedKey / data）',
      Object.prototype.hasOwnProperty.call(envelope, 'encryptedKey')
        && Object.prototype.hasOwnProperty.call(envelope, 'data'));
    check('坏公钥时返回 null（调用方必须放弃请求，不发明文）',
      encryptedEnvelope(Buffer.from('{}'), 'not-base64!!') === null);
  }

  // ── 2. 归一化与格式预检（与后端 normalizeCode 对齐）──
  check('归一化：大写 + 去非字母数字', access.normalizedCode(' abc-d1234 efgh!') === 'ABCD1234EFGH');
  check('12 位激活码（含横线）通过格式预检', access.isPlausibleActivationCode('ABCD-1234-EFGH'));
  check('短码 / 误粘文本不通过格式预检',
    !access.isPlausibleActivationCode('hello') && !access.isPlausibleActivationCode('4567890123456'));

  // ── 3. 本地码解锁：直过且不记录（不参与远程复核）──
  {
    let fetched = 0;
    const r = await access.unlock('456', { fetch: async () => { fetched += 1; return { ok: true, json: async () => ({ code: 0, data: { valid: true } }) }; } });
    check('本地校验码 456 直接解锁', r === 'success' && access.isFullAccess());
    check('本地码不走网络、不记录激活码', fetched === 0 && !config.get('accessCode'));
    check('解锁码持久化为 full', config.get('accessLevel') === 'full');

    access.clearAccess();
    check('清除权限回到基础', !access.isFullAccess() && !config.get('accessLevel'));
  }

  // ── 4. 远程校验：空码 / 坏格式 / 结果映射 / 持久化 ──
  {
    const good = { ok: true, json: async () => ({ code: 0, data: { valid: true } }) };
    let calls = [];
    const spyFetch = async (url, opts) => { calls.push({ url, opts }); return good; };

    check('空校验码直接判错误', await access.unlock('   ') === 'invalidCode');
    check('误粘文本先被格式预检拦住（不发请求）',
      await access.unlock('paste-from-note', { fetch: spyFetch }) === 'badFormat' && calls.length === 0);

    calls = [];
    const r = await access.unlock('abcd-1234-efgh', { fetch: spyFetch, deviceId: () => 'dev-9' });
    check('12 位码走 /api/access/verify 并解锁', r === 'success' && /\/api\/access\/verify$/.test(calls[0].url));
    check('请求体是加密信封（无明文 code/deviceId）', (() => {
      const body = JSON.parse(calls[0].opts.body);
      return Boolean(body.encryptedKey && body.data) && !body.code && !body.deviceId;
    })());
    check('解锁成功记录激活码归一化值', config.get('accessCode') === 'ABCD1234EFGH');
    access.clearAccess();

    const cases = [
      [{ code: 0, data: { valid: false, reason: 'expired' } }, 'expired'],
      [{ code: 0, data: { valid: false, reason: 'device_limit' } }, 'deviceLimit'],
      [{ code: 0, data: { valid: false, reason: 'invalid_code' } }, 'invalidCode'],
      [{ code: 0, data: {} }, 'invalidCode'],
    ];
    for (const [json, want] of cases) {
      const rr = await access.unlock('AAAA1111BBBB', {
        fetch: async () => ({ ok: true, json: async () => json }),
        deviceId: () => 'dev-9',
      });
      check(`服务端 ${JSON.stringify(json.data)} → ${want}`, rr === want && !access.isFullAccess());
    }
    check('非 2xx 响应判服务异常', await access.unlock('ABCD1234EFGH', {
      fetch: async () => ({ ok: false, status: 500, json: async () => ({}) }),
      deviceId: () => 'd',
    }) === 'serverError');
    check('网络异常判 networkError', await access.unlock('ABCD1234EFGH', {
      fetch: async () => { throw new Error('boom'); },
      deviceId: () => 'd',
    }) === 'networkError');
    access.clearAccess();
  }

  // ── 5. 定时复核：本地码/未解锁跳过；明确失效才收回；网络异常保留 ──
  {
    await access.unlock('456');
    check('本地后门码不复核', await access.revalidate({ fetch: async () => { throw new Error('不该请求'); } }) === 'skipped');
    access.clearAccess();
    check('未解锁不复核', await access.revalidate() === 'skipped');

    const okFetch = async () => ({ ok: true, json: async () => ({ code: 0, data: { valid: true } }) });
    await access.unlock('ABCD1234EFGH', { fetch: okFetch, deviceId: () => 'd' });
    check('复核通过保留权限', await access.revalidate({ fetch: okFetch, deviceId: () => 'd' }) === 'ok' && access.isFullAccess());

    check('复核判过期 → 收回权限', await access.revalidate({
      fetch: async () => ({ ok: true, json: async () => ({ code: 0, data: { valid: false, reason: 'expired' } }) }),
      deviceId: () => 'd',
    }) === 'revoked' && !access.isFullAccess());

    await access.unlock('ABCD1234EFGH', { fetch: okFetch, deviceId: () => 'd' });
    check('复核网络异常保留权限', await access.revalidate({
      fetch: async () => { throw new Error('offline'); },
      deviceId: () => 'd',
    }) === 'skipped' && access.isFullAccess());
    access.clearAccess();
  }

  // ── 6. 天气提醒调度：跨天顺延 / 睡眠补偿 / 权限守卫 ──
  {
    const noon = new Date(2026, 10, 4, 12, 0, 0).getTime();
    check('未到点 → 今天 hh:mm', nextFireMs(noon, 18, 30) === new Date(2026, 10, 4, 18, 30, 0).getTime());
    check('已过点 → 顺延明天', nextFireMs(noon, 8, 0) === new Date(2026, 10, 5, 8, 0, 0).getTime());

    // 注入假定时器与假时钟：Date.now 用可变 nowMs 驱动
    const RealDate = Date;
    let nowMs = noon;
    global.Date = new Proxy(RealDate, {
      construct: (target, args) => new target(...args), // eslint-disable-line new-cap
      get(t, prop) {
        if (prop === 'now') return () => nowMs;
        return Reflect.get(t, prop);
      },
    });
    try {
      let due = null;
      let fired = 0;
      let enabled = true;
      let fullAccess = false;
      const wr = createWeatherReminder({
        isEnabled: () => enabled,
        getHour: () => 8,
        getMinute: () => 0,
        isFullAccess: () => fullAccess,
        fire: () => { fired += 1; },
        // 存绝对到点时间（setTimeout 给的是延迟，直接存延迟会把后续时间轴算乱）
        setTimer: (fn, delay) => { due = { fn, ms: nowMs + delay }; return due; },
        clearTimer: () => { due = null; },
      });
      wr.start();
      check('开着时启动即安排（已过 08:00 → 约 20 小时后触发）',
        due && Math.abs(due.ms - nextFireMs(noon, 8, 0)) < 2000);

      // 到点但基础权限：跳过不推（推进到 due 对应的绝对时刻，逾期=0）
      nowMs = due.ms;
      due.fn();
      check('到点触发但基础权限 → 不推送，且已排下一次', fired === 0 && due && due.ms > nowMs);

      // 解锁后下一次到点正常推
      fullAccess = true;
      nowMs = due.ms;
      due.fn();
      check('解锁后到点推送', fired === 1);

      // 睡眠补偿：唤醒时已逾期超过 2 小时宽限 → 跳过（在下一个到点后 3h 才补发）
      nowMs = due.ms + 3 * 60 * 60 * 1000;
      due.fn();
      check('逾期超过 2h 宽限（睡眠积压）→ 跳过本次', fired === 1);

      // 关闭开关后重排不再挂定时器
      enabled = false;
      wr.reschedule();
      check('关闭开关后不再安排提醒', due === null);
      wr.stop();
    } finally {
      global.Date = RealDate;
    }
  }

  // ── 7. SettingsService：load 反映权限与天气提醒；未解锁拒改 ──
  {
    const bare = new SettingsService({});
    const init = bare.load();
    check('未解锁时 load().access.fullAccess = false', init.access.fullAccess === false);
    check('天气提醒默认 关 / 08:00 / 城市留空',
      init.weatherReminder.enabled === false
        && init.weatherReminder.hour === 8 && init.weatherReminder.minute === 0
        && init.weatherReminder.city === '');

    const blocked = bare.setWeatherReminder({ enabled: true });
    check('基础权限拒改天气提醒（对齐 mac 版：接口按量付费）',
      blocked.ok === false && config.get('weatherReminderEnabled') === false);

    const unlockedService = new SettingsService({ providers: { isFullAccess: () => true } });
    let res = unlockedService.setWeatherReminder({ enabled: true, hour: 7, minute: 30, city: ' 杭州 ' });
    check('解锁后可开启并写时分城市（城市去首尾空格）',
      res.ok === true && res.weather.enabled === true && res.weather.hour === 7
        && res.weather.minute === 30 && res.weather.city === '杭州');
    check('配置已持久化', config.get('weatherReminderHour') === 7 && config.get('weatherReminderCity') === '杭州');

    res = unlockedService.setWeatherReminder({ hour: 24 });
    check('小时越界被拒', res.ok === false && config.get('weatherReminderHour') === 7);
    res = unlockedService.setWeatherReminder({ minute: 60 });
    check('分钟越界被拒', res.ok === false);
    res = unlockedService.setWeatherReminder({ city: 'x'.repeat(41) });
    check('城市名超长被拒', res.ok === false && config.get('weatherReminderCity') === '杭州');
    res = unlockedService.setWeatherReminder({ hour: 19 });
    check('局部更新只改传入字段', res.ok === true && res.weather.hour === 19 && res.weather.minute === 30);

    // 脏数据回落
    config.set('weatherReminderHour', 'oops');
    check('脏时值回落默认 8', unlockedService.load().weatherReminder.hour === 8);

    // 收尾恢复默认，避免影响其它断言
    access.clearAccess();
    config.remove('weatherReminderEnabled');
    config.remove('weatherReminderHour');
    config.remove('weatherReminderMinute');
    config.remove('weatherReminderCity');
  }

  if (failed > 0) {
    console.error(`\n权限/天气提醒测试失败 ${failed} 项`);
    process.exit(1);
  }
  console.log('\n全部通过');
}

main().catch((e) => {
  console.error('测试异常:', e);
  process.exit(1);
});
