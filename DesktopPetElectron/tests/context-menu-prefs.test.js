// tests/context-menu-prefs.test.js
// 「菜单设置」分区回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：默认全展示、写盘后按用户选择、未知 key 拒绝、菜单模板按勾选过滤、
//       标题取自 prefs（面板与菜单同一份文案）、固定项不受勾选影响
'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const Module = require('module');

const USER_DATA = fs.mkdtempSync(path.join(os.tmpdir(), 'pet-menu-prefs-'));

// ── mock electron：config-store 只用 app.getPath；Menu 用于模板构建断言 ──
const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      app: { getPath: () => USER_DATA },
      Menu: { buildFromTemplate: (template) => ({ template }) },
    };
  }
  return origLoad.apply(this, arguments);
};

const SRC = path.join(__dirname, '..', 'src', 'main');
const prefs = require(path.join(SRC, 'pet', 'context-menu-prefs.js'));
const { buildTemplate } = require(path.join(SRC, 'pet', 'pet-context-menu.js'));
const { SettingsService } = require(path.join(SRC, 'settings', 'settings-service.js'));

let failed = 0;
function check(name, condition, extra) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    failed += 1;
    console.error(`❌ ${name}${extra ? ` → ${extra}` : ''}`);
  }
}

// ── 默认策略：本版所有已收录项都展示 ──
for (const item of prefs.ITEMS) {
  check(`默认展示「${item.title}」`, prefs.isVisible(item.key) === true);
}

// ── 勾选关闭 → 立即读到 false；再打开恢复 ──
prefs.setVisible(false, 'news');
check('取消勾选后 news 不展示', prefs.isVisible('news') === false);
prefs.setVisible(true, 'news');
check('重新勾选后 news 展示', prefs.isVisible('news') === true);

// ── 面板数据形态（title/visible 齐全，顺序与 ITEMS 一致）──
{
  const items = prefs.panelItems();
  check('panelItems 数量与 ITEMS 相同', items.length === prefs.ITEMS.length);
  check('panelItems 每项都有 key/title/visible',
    items.every((i) => typeof i.key === 'string' && typeof i.title === 'string' && typeof i.visible === 'boolean'));
  check('panelItems 标题与 ITEMS 对齐',
    JSON.stringify(items.map((i) => i.title)) === JSON.stringify(prefs.ITEMS.map((i) => i.title)));
}

// ── 未知 key 不改配置、白名单拒绝 ──
check('未知 key 不在白名单', prefs.isValidKey('nope') === false);
check('title 未知 key 原样返回', prefs.title('nope') === 'nope');

// ── 菜单模板按勾选过滤 ──
{
  const deps = {
    pet: () => {},
    openTodo: () => {},
    hide: () => {},
    openNews: () => {},
    openWeather: () => {},
    openSettings: () => {},
    quit: () => {},
    menuVisible: (key) => prefs.isVisible(key),
    menuTitle: (key) => prefs.title(key),
  };
  const labels = () => buildTemplate(deps).filter((m) => m.type !== 'separator').map((m) => m.label);

  check('全勾选时五项功能 + 设置/关闭都在菜单里',
    JSON.stringify(labels()) === JSON.stringify(['抚摸 🐾', 'Todo 清单 📝', '躲起来 👀', '今日热点新闻 📰', '查看天气 ☀️', '设置…', '关闭 ❌']),
    JSON.stringify(labels()));

  prefs.setVisible(false, 'todo');
  prefs.setVisible(false, 'hide');
  check('勾掉 Todo / 躲藏后菜单不再出现这两项',
    !labels().includes('Todo 清单 📝') && !labels().includes('躲起来 👀'), JSON.stringify(labels()));
  check('未勾掉的项文案仍取自 prefs（与面板一致）', labels().includes(prefs.title('news')));

  // 固定项不受勾选影响：关闭 ❌ 始终在，Windows 兜底的托盘项也始终在
  const withTray = buildTemplate({ ...deps, trayFallback: true });
  check('「关闭 ❌」为固定项始终展示',
    withTray.some((m) => m.label === '关闭 ❌'));
  check('trayFallback 的显隐/检查更新不受菜单勾选影响',
    withTray.some((m) => m.label === '隐藏宠物') && withTray.some((m) => String(m.label).startsWith('检查更新')));

  prefs.setVisible(true, 'todo');
  prefs.setVisible(true, 'hide');
}

// ── 没传 menuVisible 回调时全部展示（老调用方行为不变）──
{
  const labels = buildTemplate({ pet: () => {}, openTodo: () => {}, openNews: () => {} })
    .filter((m) => m.type !== 'separator').map((m) => m.label);
  check('未注入 menuVisible 时不因勾选过滤', labels.includes('Todo 清单 📝') && labels.includes('今日热点新闻 📰'));
}

// ── SettingsService：写开关 + 未知 key 拒绝 ──
{
  const service = new SettingsService({});
  const saved = service.load();
  check('load() 带出菜单项列表', Array.isArray(saved.menu.items) && saved.menu.items.length === prefs.ITEMS.length);

  const ok = service.setMenuItemVisible('weather', false);
  check('setMenuItemVisible 成功返回最新列表', ok.ok === true && ok.visible === false && ok.items.length === prefs.ITEMS.length);
  check('写盘后面板 load() 反映新状态', service.load().menu.items.find((i) => i.key === 'weather').visible === false);

  const bad = service.setMenuItemVisible('secret', true);
  check('未知 key 被拒绝', bad.ok === false && typeof bad.error === 'string');

  service.setMenuItemVisible('weather', true);
}

if (failed > 0) {
  console.error(`\n菜单设置测试失败 ${failed} 项`);
  process.exit(1);
}
console.log('\n全部通过');
