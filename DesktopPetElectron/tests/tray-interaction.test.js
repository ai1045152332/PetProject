// tests/tray-interaction.test.js
// 托盘交互回归测试：node 直接跑，不依赖 electron 运行时
// 覆盖：Windows 左键切换显隐 / 右键才弹菜单（不设 contextMenu）、mac 左键弹菜单不误触发切换、
//       菜单文案与 tooltip 跟随显隐状态
'use strict';

const path = require('path');
const Module = require('module');

const SRC = path.join(__dirname, '..', 'src', 'main');
const TRAY_PATH = path.join(SRC, 'tray.js');

const trayInstances = [];

class FakeTray {
  constructor(image) {
    this.image = image;
    this.handlers = new Map();
    this.tooltips = [];
    this.contextMenus = [];
    this.poppedMenus = [];
    this.balloons = [];
    this.destroyed = false;
    trayInstances.push(this);
  }

  setToolTip(text) {
    this.tooltips.push(text);
  }

  setContextMenu(menu) {
    this.contextMenus.push(menu);
  }

  setTitle(text) {
    this.titles = this.titles || [];
    this.titles.push(text);
  }

  popUpContextMenu(menu) {
    this.poppedMenus.push(menu);
  }

  displayBalloon(opts) {
    this.balloons.push(opts);
  }

  on(event, fn) {
    if (!this.handlers.has(event)) this.handlers.set(event, []);
    this.handlers.get(event).push(fn);
  }

  emit(event, ...args) {
    (this.handlers.get(event) || []).forEach((fn) => fn(...args));
  }

  destroy() {
    this.destroyed = true;
  }
}

// ── mock electron ──
// nativeImage 必须按真实语义模拟：共享原图 createFromPath 得到 360×348，
// resize() 返回**新图**而不改原对象（把返回值丢掉就会拿到巨图，菜单栏直接不显示）；
// Windows 预描边图则本身就是 32×32，运行时不缩放。
const RAW_SIZE = { width: 360, height: 348 };
const WIN_ASSET_SIZE = { width: 32, height: 32 };

function fakeNativeImage(size, isTemplate) {
  const img = {
    size,
    isTemplate,
    // 真实语义：resize 返回新图，原对象尺寸不变
    resize: (opts) => fakeNativeImage({ width: opts.width, height: opts.height }, img.isTemplate),
    setTemplateImage: (flag) => { img.isTemplate = Boolean(flag); },
  };
  return img;
}

const origLoad = Module._load;
Module._load = function (request) {
  if (request === 'electron') {
    return {
      Tray: FakeTray,
      Menu: { buildFromTemplate: (template) => ({ template }) },
      app: { on: () => {} },
      nativeImage: {
        createFromPath: (file) => fakeNativeImage(
          /WindowsTray\.png$/.test(file) ? WIN_ASSET_SIZE : RAW_SIZE, false,
        ),
      },
    };
  }
  return origLoad.apply(this, arguments);
};

const ORIGINAL_PLATFORM = process.platform;

/** 按平台加载一份全新的 tray 模块（模块内有 tray 单例，必须清缓存） */
function loadTray(platform) {
  Object.defineProperty(process, 'platform', { value: platform, configurable: true });
  delete require.cache[require.resolve(TRAY_PATH)];
  return require(TRAY_PATH);
}

let failed = 0;
function check(name, condition) {
  if (condition) {
    console.log(`✅ ${name}`);
  } else {
    console.error(`❌ ${name}`);
    failed += 1;
  }
}

// ── Windows：左键切换，右键弹菜单 ──
{
  let toggled = 0;
  let petVisible = true;
  let menuOpens = 0;
  const trayModule = loadTray('win32');
  const tray = trayModule.createTray({
    togglePet: () => { toggled += 1; },
    openSettings: () => {},
    checkUpdate: () => {},
    quit: () => {},
    version: '0.0.1',
    isPetVisible: () => petVisible,
    onMenuOpen: () => { menuOpens += 1; },
  });

  check('Windows 不设 contextMenu（否则左键也会弹菜单）', tray.contextMenus.length === 0);
  check('Windows 用预描边静态图（32×32，不依赖共享原图）',
    tray.image.size.width === 32 && tray.image.size.height === 32);
  check('Windows 不标模板图（无系统反色机制）', tray.image.isTemplate === false);

  tray.emit('click');
  check('Windows 左键单击切换显隐', toggled === 1);
  check('Windows 左键单击不弹菜单', tray.poppedMenus.length === 0);

  tray.emit('right-click');
  check('Windows 右键弹出菜单', tray.poppedMenus.length === 1);
  check('弹菜单前先让出置顶层', menuOpens === 1);
  check('Windows 右键不触发切换', toggled === 1);

  const menu = tray.poppedMenus[0];
  // 未注入 buildSysInfoTemplate 时不挂「系统信息」项，首项仍是显隐
  const first = menu.template.find((t) => t.label === '隐藏宠物' || t.label === '显示宠物');
  check('宠物可见时菜单显示「隐藏宠物」', first.label === '隐藏宠物');
  first.click();
  check('菜单项点击触发切换', toggled === 2);

  petVisible = false;
  tray.emit('right-click');
  const hiddenMenu = tray.poppedMenus[1];
  check('宠物隐藏时菜单显示「显示宠物」', hiddenMenu.template[0].label === '显示宠物');

  trayModule.setTrayStatus();
  check('tooltip 标注已隐藏', tray.tooltips[tray.tooltips.length - 1].includes('已隐藏'));

  trayModule.setTrayStatus('正在检查更新…');
  check('进度文案覆盖默认 tooltip', tray.tooltips[tray.tooltips.length - 1] === '正在检查更新…');

  // Win11 托盘图标常被折进通知区溢出面板 → 首启弹一次引导气泡（未注入 shouldShowTrayHint 时默认该弹）
  check('Windows 首启弹一次托盘引导气泡', tray.balloons.length === 1);
  check('气泡文案指向通知区溢出面板',
    tray.balloons[0].content.includes('^') && tray.balloons[0].content.includes('通知区'));
}

// ── Windows：已弹过（shouldShowTrayHint 返回 false）不再重复打扰 ──
{
  const trayModule = loadTray('win32');
  const tray = trayModule.createTray({
    togglePet: () => {},
    shouldShowTrayHint: () => false,
  });
  check('shouldShowTrayHint=false 时不弹气泡', tray.balloons.length === 0);
}

// ── macOS：左键弹菜单，不直接切换（避免「弹菜单 + 隐藏」双触发）──
{
  let toggled = 0;
  const trayModule = loadTray('darwin');
  const tray = trayModule.createTray({
    togglePet: () => { toggled += 1; },
    version: '0.0.1',
    isPetVisible: () => true,
  });

  tray.emit('click');
  check('mac 左键弹出菜单', tray.poppedMenus.length === 1);
  check('mac 左键不直接切换显隐', toggled === 0);
  check('mac 不依赖 setContextMenu 自动弹菜单', tray.contextMenus.length === 0);
  check('mac 图标缩到 22pt（resize 返回值必须接住，否则巨图不显示）',
    tray.image.size.width === 22 && tray.image.size.height === 22);
  check('mac 标为模板图（系统按深浅色反色）', tray.image.isTemplate === true);
  check('mac 不弹 Windows 托盘引导气泡', tray.balloons.length === 0);
}

Object.defineProperty(process, 'platform', { value: ORIGINAL_PLATFORM, configurable: true });

if (failed > 0) {
  console.error(`\n托盘交互测试失败 ${failed} 项`);
  process.exit(1);
}
console.log('\n全部通过');
