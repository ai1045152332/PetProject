// src/main/index.js
// DesktopPetElectron — 主进程入口
// 职责：应用生命周期 + 创建宠物窗口 + 喝水提醒调度 + 心跳上报 + 自动更新 + IPC
'use strict';

const { app, BrowserWindow, Menu, ipcMain, globalShortcut } = require('electron');
const { createPetWindow, applyPetScale, startOnTopGuard, createDragController } = require('./pet-window');
const { openReminderWindow, closeReminderWindow } = require('./reminder-window');
const { openSettingsWindow, closeSettingsWindow } = require('./settings-window');
const {
  SettingsService,
  currentPetScale,
  isValidPetState,
} = require('./settings-service');
const { ReminderScheduler } = require('./reminder-scheduler');
const { createTray, setTrayStatus, setTrayTitle, popUpMenu: popUpTrayMenu } = require('./tray');
const { SysInfoMonitor } = require('./system-monitor');
const { startWorker, createCacheOnlySnapshot } = require('./sysinfo-worker');
const { popupPetContextMenu, createPettingOneShot } = require('./pet-context-menu');
const { HeartbeatService } = require('./heartbeat');
const { UpdateService } = require('./update-service');
const info = require('./app-info');
const config = require('./config-store');

let petWindow = null;
let petGuard = null;   // Windows 置顶守护（周期性抬回最上层）
let petDrag = null;    // 手动拖窗控制器（渲染层 mousedown/mousemove + IPC 搬窗）
let scheduler = null;
let heartbeat = null;
let updater = null;
let settings = null;
let sysinfo = null;  // 托盘「系统信息」监控（对标 Swift startSysInfoMonitoring / startMenuBarMonitoring）
let sysinfoCache = null; // worker 投喂的只读快照源
let sysinfoWorker = null; // 采集子进程句柄（退出时必须 kill，fork 的 Node 进程不随 app 回收）

// 当前让宠物让出置顶层级的窗口数（设置窗 / 提醒窗 / 托盘菜单打开期间）
let topYieldCount = 0;

// 创建（或复用）宠物窗，并同步维护置顶守护
function ensurePetWindow() {
  if (petWindow && !petWindow.isDestroyed()) {
    if (!petGuard) petGuard = startOnTopGuard(petWindow);
    return petWindow;
  }
  petWindow = createPetWindow({ scale: currentPetScale() });
  console.log('[pet-window] bounds=', JSON.stringify(petWindow.getBounds()));
  petGuard = startOnTopGuard(petWindow);
  petDrag = createDragController(petWindow);
  petWindow.on('closed', () => {
    if (petGuard) petGuard.stop();
    petGuard = null;
    petDrag = null;
    petWindow = null;
  });
  return petWindow;
}

/**
 * 某个原生窗口需要盖在宠物上面（设置面板 / 提醒窗）时让出置顶，窗口关闭后自动恢复。
 * 用计数而不是布尔值，避免多个窗口同时打开时提前抢回顶层。
 */
function yieldTopTo(win) {
  if (!win || !petGuard) return;
  topYieldCount += 1;
  petGuard.pause(Infinity);
  win.once('closed', () => {
    topYieldCount = Math.max(0, topYieldCount - 1);
    if (topYieldCount === 0 && petGuard) petGuard.resume();
  });
}

// 宠物当前状态：目前只有帧切换（设置面板 / 右键抚摸），P1 状态机上线后由渲染层回传
let petState = 'focus';

// 切换宠物形象：更新状态 + 换帧目录（focus / idel / sleep / pet），设置面板与右键「抚摸」共用
function applyPetState(state) {
  petState = state;
  sendToRenderer('pet:state', state);
  console.log(`[settings] petState -> ${state}`);
  return { ok: true, state };
}

// 右键「抚摸」一次性播放（对标 Swift playOneShot）：播完一圈自动回原状态，设置面板切形象仍是永久的
const petting = createPettingOneShot({
  getState: () => petState,
  setState: (state) => { applyPetState(state); },
});

// 向渲染进程发送事件（窗口存在才发）
function sendToRenderer(channel, payload) {
  if (petWindow && !petWindow.isDestroyed()) {
    petWindow.webContents.send(channel, payload);
  }
}

// 切换宠物窗显示 / 隐藏（托盘 / 右键菜单 / 快捷键用）
function togglePet() {
  const win = ensurePetWindow();
  if (win.isVisible()) {
    win.hide();
  } else {
    win.show();
    // 隐藏期间可能被别的新置顶窗口超过，重新显示时立刻抬回顶层
    if (petGuard) petGuard.resume();
  }
  // 刷新 tooltip（带上「已隐藏」标记）
  setTrayStatus();
}

// 宠物右键菜单（P3，对标 Swift 版 CatView.rightMouseDown）：只收录本版已就绪的能力，
// 抚摸=切 pet 帧、关闭=退出；显隐/设置/检查更新同 Swift 版只放托盘；弹出期间让出置顶层
function showPetContextMenu() {
  popupPetContextMenu(ensurePetWindow(), {
    pet: () => petting.play(),
    quit: () => app.quit(),
    onMenuOpen: () => petGuard && petGuard.pause(10000),
    onMenuClose: () => petGuard && petGuard.resume(),
  });
}

// 开机自启当前状态（mac / Windows 都通过系统登录项实现）
function isAutoLaunchEnabled() {
  try {
    return Boolean(app.getLoginItemSettings().openAtLogin);
  } catch (e) {
    return false;
  }
}

// 触发一次喝水提醒：弹出提醒窗 + 专注动画从头播放（提醒已合并进专注，不再有独立 warn 动画）
function fireReminder() {
  yieldTopTo(openReminderWindow());
  sendToRenderer('drink-water:show');
}

// 打开设置面板（打开期间宠物让出置顶，否则宠物会盖住面板）
function openSettings() {
  yieldTopTo(openSettingsWindow());
}

// 应用菜单：mac 上用最小菜单集（保留编辑菜单，输入框才能 Cmd+C/V）
function buildAppMenu() {
  if (process.platform !== 'darwin') return;
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      label: app.name,
      submenu: [
        { role: 'about', label: `关于 ${app.name}` },
        { type: 'separator' },
        { label: '设置…', accelerator: 'CommandOrControl+,', click: () => openSettings() },
        { type: 'separator' },
        { role: 'hide', label: `隐藏 ${app.name}` },
        { role: 'hideOthers', label: '隐藏其他' },
        { role: 'unhide', label: '全部显示' },
        { type: 'separator' },
        { role: 'quit', label: `退出 ${app.name}` },
      ],
    },
    { role: 'editMenu', label: '编辑' },
    { role: 'windowMenu', label: '窗口' },
  ]));
}

// 更新流程的托盘提示：检查中/下载中/安装中都有反馈，结束后恢复默认文案
function onUpdateStatus(status) {
  if (!status) return;
  if (status.phase === 'checking') setTrayStatus('正在检查更新…');
  else if (status.phase === 'downloading') setTrayStatus(`正在下载 ${status.version || '更新'} ${status.percent || 0}%`);
  else if (status.phase === 'ready') setTrayStatus(`更新已下载，准备安装 ${status.version || ''}`.trim());
  else if (status.phase === 'installing') setTrayStatus('正在安装更新，宠物马上回来…');
  // 空串让托盘回到默认文案（带版本号 + 当前显隐状态）
  else setTrayStatus();
}

app.whenReady().then(() => {
  ensurePetWindow();

  // 喝水提醒：从持久化配置读取间隔，启动调度器
  scheduler = new ReminderScheduler({
    getIntervalMinutes: () => config.get('drinkWaterInterval'),
    send: fireReminder,
  });
  scheduler.start();

  // 设置面板业务逻辑（提醒间隔 / 宠物名称 / 宠物大小），与 IPC 接线分离
  settings = new SettingsService({
    scheduler,
    providers: {
      version: () => info.currentVersion(),
      petNo: () => config.get('petNo') || 0,
      petState: () => petState,
      autoLaunch: isAutoLaunchEnabled,
      heartbeat: () => (heartbeat ? heartbeat.getStatus() : null),
    },
  });

  // 应用菜单：mac 上提供「设置…」与 Cmd+,（保留编辑菜单，设置面板的输入框才支持复制粘贴）
  buildAppMenu();

  // 心跳上报：启动即报一次，之后每 1 分钟一次（与 mac 版同节奏、同上报体）
  heartbeat = new HeartbeatService({ getState: () => petState });
  heartbeat.start();

  // 自动更新：启动 30 秒后首次检查，之后每 24 小时一次；托盘菜单可手动触发
  updater = new UpdateService({ onStatus: onUpdateStatus });
  updater.start();

  // 提醒窗关闭按钮 → 收起提醒窗、解除"正在显示"（专注动画自身持续循环，无需通知渲染层切换）
  ipcMain.on('drink-water:dismiss', () => {
    closeReminderWindow();
    if (scheduler) scheduler.dismiss();
  });

  // ── 设置面板 IPC（对应 mac 版 SettingsPanel 的喝水提醒分区）──
  // 读：当前间隔 + 预设 + 合法区间
  ipcMain.handle('settings:load', () => settings.load());

  // 写：校验 → 持久化 → 立即重启计时（与 mac 版 restartDrinkWaterReminder 行为一致）
  ipcMain.handle('settings:set-interval', (event, minutes) => {
    const result = settings.setInterval(minutes);
    console.log(`[settings] drinkWaterInterval -> ${JSON.stringify(result)}`);
    return result;
  });

  // 立即弹一次提醒（设置面板「测试提醒」）
  ipcMain.on('settings:test-reminder', () => settings.testReminder());

  ipcMain.on('settings:close', () => closeSettingsWindow());

  // ── 宠物信息：名称 / 形象 ──
  ipcMain.handle('settings:set-pet-name', (event, name) => {
    const result = settings.setPetName(name);
    if (result.ok) console.log(`[settings] petName -> ${result.name}`);
    return result;
  });

  ipcMain.handle('settings:set-pet-state', (event, state) => {
    if (!isValidPetState(state)) {
      return { ok: false, error: '不支持的形象', state: petState };
    }
    return applyPetState(state);
  });

  // ── 通用设置：宠物大小 / 开机自启 / 检查更新 ──
  ipcMain.handle('settings:set-pet-scale', (event, scale) => {
    const result = settings.setPetScale(scale);
    if (result.ok) applyPetScale(petWindow, result.scale);
    console.log(`[settings] petScale -> ${JSON.stringify(result)}`);
    return result;
  });

  ipcMain.handle('settings:set-auto-launch', (event, enabled) => {
    const on = Boolean(enabled);
    try {
      app.setLoginItemSettings({ openAtLogin: on });
    } catch (e) {
      return { ok: false, error: '当前系统不支持设置开机自启', enabled: isAutoLaunchEnabled() };
    }
    const actual = isAutoLaunchEnabled();
    console.log(`[settings] autoLaunch -> ${actual}`);
    return { ok: true, enabled: actual };
  });

  ipcMain.handle('settings:check-update', async () => {
    app.focus({ steal: true });
    await updater.checkForUpdate({ userInitiated: true });
    return { ok: true };
  });

  // ── 鼠标交互 IPC：手动拖窗 + 右键菜单（事件源在渲染层，见 pet.js / preload.js）──
  // 不用 CSS -webkit-app-region: drag，也不用 webContents 的 context-menu 事件：
  // 原生拖拽区会吞鼠标事件，之前 sendInputEvent 验证绕过了这条链路导致误判可用
  ipcMain.on('pet:drag-start', (event, { x, y }) => petDrag && petDrag.start(x, y));
  ipcMain.on('pet:drag-move', (event, { x, y }) => petDrag && petDrag.move(x, y));
  ipcMain.on('pet:drag-end', () => petDrag && petDrag.end());

  ipcMain.on('pet:context-menu', () => {
    console.log('[context-menu] 右键宠物窗，弹原生菜单');
    showPetContextMenu();
  });

  // 测试触发：Ctrl+Alt+W（Cmd+Alt+W on mac）立即弹一次，便于验证
  globalShortcut.register('CommandOrControl+Alt+W', () => {
    if (scheduler) scheduler.triggerNow();
  });

  // 托盘「系统信息」：CPU / 内存 / 磁盘 / 网络采集 + 勾选显示在顶栏（勾选状态持久化到配置）。
  // 采集在 fork 的子进程里跑（top/netstat 等同步 spawn 会阻塞调用线程），
  // 主进程只读 worker 投喂的缓存 → 点托盘菜单不再卡住整个应用
  sysinfo = new SysInfoMonitor({
    getOption: (key) => config.get(key),
    setOption: (key, value) => config.set(key, value),
    setTitle: setTrayTitle,
    readers: {}, // 主进程不采集：快照全部来自 cacheOnly
  });
  sysinfoCache = createCacheOnlySnapshot();
  sysinfo.setCacheOnly(sysinfoCache);
  sysinfoWorker = startWorker({
    getOption: (key) => config.get(key),
    onSnapshot: (snap) => sysinfoCache.apply(snap),
    onTitle: (title) => setTrayTitle(title),
  });

  // 菜单栏托盘：提供可见图标 + 检查更新 + 退出入口
  createTray({
    togglePet,
    openSettings: () => openSettings(),
    checkUpdate: () => {
      app.focus({ steal: true });
      updater.checkForUpdate({ userInitiated: true });
    },
    quit: () => app.quit(),
    version: info.currentVersion(),
    // 菜单文案 / tooltip 要反映实时显隐状态
    isPetVisible: () => Boolean(petWindow && !petWindow.isDestroyed() && petWindow.isVisible()),
    // 原生菜单弹出时先让两层，否则 Windows 上宠物会被抬到菜单上面
    onMenuOpen: () => petGuard && petGuard.pause(10000),
    // 系统信息二级菜单：数值读 worker 投喂的缓存；勾选变化同步给 worker 重算顶栏标题
    buildSysInfoTemplate: () => sysinfo.buildMenuTemplate(() => sysinfoWorker && sysinfoWorker.postEnabled()),
  });

  // 全局快捷键：宠物隐藏 / 被挡住时的兵家必争逃生口（托盘图标在 Win11 会折进隐藏区）
  globalShortcut.register('CommandOrControl+Alt+P', togglePet);

  // 仅测试用：PET_TEST_REMINDER=1 时启动 2 秒后自动弹一次提醒
  if (process.env.PET_TEST_REMINDER === '1') {
    setTimeout(() => scheduler && scheduler.triggerNow(), 2000);
  }

  // 仅测试用：PET_TEST_SETTINGS=1 时启动 2.5 秒后自动打开设置面板
  if (process.env.PET_TEST_SETTINGS === '1') {
    setTimeout(() => openSettingsWindow(), 2500);
  }

  // 仅调试用：PET_TEST_SETTINGS_SHOT=/path.png 时打开面板并截图落盘，完成后自退
  // 注意：capturePage 只取页面本身，会把透明区填成白色，看不出窗口层底板；
  // 要验外边距是否真透明，得用 screencapture 抓系统画面（按 getBounds 的 point 坐标）
  // 可选 PET_TEST_SETTINGS_SECTION=general|reminder|menu|social|pet 指定截哪个分区
  if (process.env.PET_TEST_SETTINGS_SHOT) {
    setTimeout(async () => {
      const win = openSettingsWindow();
      try {
        await new Promise((r) => setTimeout(r, 1200));
        if (process.env.PET_TEST_SETTINGS_DARK) {
          // 本机不是深色外观时手动预置 .dark，验证深色分支样式
          await win.webContents.executeJavaScript(
            'document.documentElement.classList.add("dark"); true'
          );
        }
        const section = process.env.PET_TEST_SETTINGS_SECTION;
        if (section) {
          await win.webContents.executeJavaScript(
            `document.querySelector('.nav-item[data-section="${section}"]').click(); true`
          );
          await new Promise((r) => setTimeout(r, 300));
        }
        const image = await win.webContents.capturePage();
        require('fs').writeFileSync(process.env.PET_TEST_SETTINGS_SHOT, image.toPNG());
        console.log('[settings-shot] 已保存', process.env.PET_TEST_SETTINGS_SHOT);
      } catch (err) {
        console.error('[settings-shot] 失败', err);
      }
      app.quit();
    }, 2500);
  }

  // 仅测试用：PET_TEST_CONTEXT_MENU=1 时启动 2.5 秒后自动弹一次右键菜单
  if (process.env.PET_TEST_CONTEXT_MENU === '1') {
    setTimeout(showPetContextMenu, 2500);
  }

  // 仅测试用：PET_TEST_TRAY_MENU=1 时启动 2.5 秒后自动弹一次托盘菜单（验证系统信息二级菜单）
  if (process.env.PET_TEST_TRAY_MENU === '1') {
    setTimeout(() => popUpTrayMenu(), 2500);
  }

  // 仅测试用：PET_TEST_RCLICK=1 时启动 3 秒后注入一次右键输入（验证 context-menu → 菜单链路），完成后自退
  if (process.env.PET_TEST_RCLICK === '1') {
    setTimeout(() => {
      const wc = petWindow && !petWindow.isDestroyed() ? petWindow.webContents : null;
      if (!wc) return;
      wc.sendInputEvent({ type: 'mouseDown', x: 100, y: 100, button: 'right', clickCount: 1 });
      wc.sendInputEvent({ type: 'mouseUp', x: 100, y: 100, button: 'right', clickCount: 1 });
      setTimeout(() => {
        console.log('[rclick-probe] done');
        app.quit();
      }, 1500);
    }, 3000);
  }

  // 仅测试用：PET_TEST_UPDATE=1 时启动 3 秒后立刻检查更新（跳过 30 秒首检等待）
  if (process.env.PET_TEST_UPDATE === '1') {
    setTimeout(() => updater && updater.checkForUpdate({ userInitiated: true }), 3000);
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      ensurePetWindow();
    }
  });
});

app.on('will-quit', () => {
  petting.cancel();
  globalShortcut.unregisterAll();
  if (petGuard) petGuard.stop();
  if (scheduler) scheduler.stop();
  if (heartbeat) heartbeat.stop();
  if (updater) updater.stop();
  if (sysinfoWorker) sysinfoWorker.kill();
});

// 非 macOS：所有窗口关闭即退出。macOS 保持常驻（后续接托盘控制）
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});
