// src/main/index.js
// DesktopPetElectron — 主进程入口
// 职责：应用生命周期 + 创建宠物窗口 + 喝水提醒调度 + Todo 待办与到期提醒 + 心跳上报 + 自动更新 + IPC
'use strict';

const { app, BrowserWindow, Menu, ipcMain, globalShortcut, dialog } = require('electron');
const path = require('path');
const { pathToFileURL } = require('url');
const { createPetWindow, applyPetScale, startOnTopGuard, createDragController } = require('./pet-window');
const { openReminderWindow, closeReminderWindow } = require('./reminder-window');
const { openSettingsWindow, closeSettingsWindow } = require('./settings-window');
const {
  SettingsService,
  currentPetScale,
  currentPetName,
  isValidPetState,
} = require('./settings-service');
const { ReminderScheduler } = require('./reminder-scheduler');
const todoStore = require('./todo-store');
const {
  openTodoWindow,
  syncTodoWindow,
  closeTodoWindow,
  isTodoOpen,
} = require('./todo-window');
const { openTodoReminderWindow, closeTodoReminderWindow } = require('./todo-reminder-window');
const { createTodoReminderLoop, formatDueLabel } = require('./todo-reminder');
const { createTray, setTrayStatus, setTrayTitle, popUpMenu: popUpTrayMenu } = require('./tray');
const { SysInfoMonitor } = require('./system-monitor');
const { startWorker, createCacheOnlySnapshot } = require('./sysinfo-worker');
const { popupPetContextMenu, createPettingOneShot } = require('./pet-context-menu');
const { HeartbeatService } = require('./heartbeat');
const { UpdateService } = require('./update-service');
const info = require('./app-info');
const config = require('./config-store');
const customSprites = require('./custom-sprite-store');
const spriteFrames = require('./sprite-frames');

let petWindow = null;
let petGuard = null;   // Windows 置顶守护（周期性抬回最上层）
let petDrag = null;    // 手动拖窗控制器（渲染层 mousedown/mousemove + IPC 搬窗）
let scheduler = null;
let todoReminder = null; // Todo 到期扫描循环（对标 mac 版 startTodoReminderLoop）
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

// 内置帧数：按 assets/Sprites 目录枚举，与 Swift 侧一样不在代码里写死
// （素材已统一到 SharedAssets/Sprites，idel / pet 是 24 帧，写死 8 会只播前三分之一）
// 启动时读一次即可：运行期素材不变（随安装包只读）
const frameCounts = spriteFrames.readFrameCounts(
  path.join(__dirname, '..', '..', 'assets', 'Sprites'),
);

// 右键「抚摸」一次性播放（对标 Swift playOneShot）：播完一圈自动回原状态，设置面板切形象仍是永久的
const petting = createPettingOneShot({
  getState: () => petState,
  setState: (state) => { applyPetState(state); },
  frames: frameCounts.pet || 8, // 读不到目录时兜底按 8 帧播一圈
});

// 向渲染进程发送事件（窗口存在才发）
function sendToRenderer(channel, payload) {
  if (petWindow && !petWindow.isDestroyed()) {
    petWindow.webContents.send(channel, payload);
  }
}

// 各状态自定义形象图 → file:// URL 映射（无自定义为 null，渲染层据此回退内置帧动画）。
// userData 不在安装包内，渲染层用 file: 读它（pet/index.html CSP 已放行 img-src file:）。
function spriteUrlMap() {
  const files = customSprites.snapshotFileMap();
  const urls = {};
  for (const id of Object.keys(files)) {
    urls[id] = files[id] ? pathToFileURL(files[id]).toString() : null;
  }
  return urls;
}

// 上传/清除后立即把最新映射推给宠物窗，正在显示的状态实时换图
function sendSpriteSnapshot() {
  sendToRenderer('pet:sprite', spriteUrlMap());
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
// 抚摸=切 pet 帧、Todo=开本地清单、关闭=退出；显隐/设置/检查更新同 Swift 版只放托盘；弹出期间让出置顶层
// Windows 额外走兜底：Win11 会把托盘图标折进通知区溢出面板，用户找不到托盘就无入口，
// 故右键菜单补上显隐/设置/检查更新（trayFallback），mac 菜单栏常驻可见不需要
function showPetContextMenu() {
  const win32 = process.platform === 'win32';
  popupPetContextMenu(ensurePetWindow(), {
    pet: () => petting.play(),
    openTodo: () => openTodoList(),
    quit: () => app.quit(),
    trayFallback: win32,
    isPetVisible: () => Boolean(petWindow && !petWindow.isDestroyed() && petWindow.isVisible()),
    togglePet,
    openSettings: () => openSettings(),
    checkUpdate: () => {
      app.focus({ steal: true });
      updater.checkForUpdate({ userInitiated: true });
    },
    version: info.currentVersion(),
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

// 打开 Todo 清单（双击宠物 / 右键菜单入口，对标 mac 版 showTodoList）：同样让出置顶层
function openTodoList() {
  yieldTopTo(openTodoWindow(todoStore.load()));
}

// Todo 到期触达：弹常驻提醒卡（需用户点 ✕ 才收起），并让宠物专注动画从头播放唤起注意
// 睡 / 隐藏中也要弹，否则会漏提醒（与 mac 版 checkTodoReminders 一致）
function fireTodoReminder(item) {
  yieldTopTo(openTodoReminderWindow({
    id: item.id,
    text: item.text,
    subtitle: item.due ? `约定时间 ${formatDueLabel(item.due)}` : '',
  }));
  sendToRenderer('todo:remind');
  // 到期标记 lastNotifiedAt 已写盘，清单开着的话同步刷一下
  if (isTodoOpen()) syncTodoWindow(todoStore.load());
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
  // 首次启动的一次性默认值：默认开启开机自启，并随机取一个宠物名（两者用户之后都可在面板里改）
  if (!config.get('autoLaunchInitialized')) {
    try {
      app.setLoginItemSettings({ openAtLogin: true });
    } catch (e) {
      // 部分系统或打包环境不支持登录项，忽略即可
    }
    config.set('autoLaunchInitialized', true);
  }
  currentPetName(); // 无名字时随机取一个并持久化，供心跳与面板共用

  ensurePetWindow();

  // 喝水提醒：从持久化配置读取间隔，启动调度器
  scheduler = new ReminderScheduler({
    getIntervalMinutes: () => config.get('drinkWaterInterval'),
    send: fireReminder,
  });
  scheduler.start();

  // Todo 到期扫描：每 30 秒扫一次，到点的待办弹常驻提醒卡，按配置的间隔重复提醒直到被删除
  todoReminder = createTodoReminderLoop({
    load: () => todoStore.load(),
    markNotified: (id, atMs) => todoStore.markNotified(id, atMs),
    fire: fireTodoReminder,
    getRepeatMinutes: () => config.get('todoReminderRepeatMinutes'),
  });
  todoReminder.start();

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

  // ── Todo 清单 IPC（对应 mac 版 TodoManager + HTMLAlertWindow.showTodo）──
  // 页面加载完主动拉一次全量；增删都回灌最新列表（主进程是唯一数据源，渲染层不自改状态）
  ipcMain.handle('todo:list-fetch', () => todoStore.load());

  ipcMain.handle('todo:add', (event, payload) => {
    const p = payload || {};
    const result = todoStore.add(p.text, p.due);
    const items = todoStore.load();
    if (result.ok) syncTodoWindow(items); // 顺手按条数调窗口高度
    console.log(`[todo] add ${result.ok ? '✓' : '✗'} ${result.error || p.text}`);
    return { ...result, items };
  });

  ipcMain.handle('todo:delete', (event, id) => {
    const result = todoStore.remove(id);
    const items = todoStore.load();
    syncTodoWindow(items);
    console.log(`[todo] delete ${id} ${result.ok ? '✓' : '✗'}`);
    return { ...result, items };
  });

  ipcMain.on('todo:close', () => closeTodoWindow());

  // 到期提醒卡「✅ 完成」：删除该待办 + 收起卡片，逾期重复提醒随即停止
  ipcMain.on('todo-reminder:complete', (event, id) => {
    todoStore.remove(id);
    closeTodoReminderWindow();
    if (isTodoOpen()) syncTodoWindow(todoStore.load());
    console.log(`[todo] complete from reminder ${id}`);
  });

  // 双击宠物 → 开 Todo 清单（事件源在渲染层，见 pet.js）
  ipcMain.on('pet:open-todo', () => openTodoList());

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

  // ── 自定义形象图（上传自己的小猫，落 userData，App 更新后保留）──
  // 面板预览：返回各状态当前自定义图的 file:// URL（无自定义为 null），
  // 渲染层据此显示自定义图，为 null 时回落到内置 frame_00 预览
  ipcMain.handle('settings:list-custom-sprite', () => spriteUrlMap());

  // 选图 → 拷贝进 userData → 推快照给宠物窗
  ipcMain.handle('settings:pick-custom-sprite', async (event, state) => {
    if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
    const win = BrowserWindow.fromWebContents(event.sender);
    const res = await dialog.showOpenDialog(win, {
      title: '选择宠物形象图片',
      properties: ['openFile'],
      filters: [{ name: '图片', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'] }],
    });
    if (res.canceled || !res.filePaths.length) return { ok: false, canceled: true };
    const result = customSprites.installLocalImage(state, res.filePaths[0]);
    if (result.ok) {
      console.log(`[custom-sprite] ${state} <- ${result.file}`);
      sendSpriteSnapshot();
    }
    return result;
  });

  // 恢复默认：删掉该状态的自定义图，推快照让宠物窗回到内置帧动画
  ipcMain.handle('settings:clear-custom-sprite', (event, state) => {
    const result = customSprites.clearLocalImage(state);
    if (result.ok) {
      console.log(`[custom-sprite] ${state} 已恢复默认`);
      sendSpriteSnapshot();
    }
    return result;
  });

  // 宠物窗刚加载完主动拉一次当前自定义形象（上传/清除期间再通过 pet:sprite 推送增量）
  ipcMain.handle('pet:sprite-snapshot', () => spriteUrlMap());

  // 宠物窗拉内置帧数清单（pet.js 据此循环，不再写死 8 帧）
  ipcMain.handle('pet:frame-counts', () => frameCounts);

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
    // Win11 首启引导气泡：只在 Windows 且从未弹过时弹一次，弹后置位持久化避免反复打扰
    shouldShowTrayHint: () => process.platform === 'win32' && !config.get('winTrayHintShown'),
    onTrayHintShown: () => config.set('winTrayHintShown', true),
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
        // 可选 PET_TEST_SETTINGS_SCROLL=1：滚到内容区底部，验证靠后的卡片（如自定义形象图）
        if (process.env.PET_TEST_SETTINGS_SCROLL) {
          await win.webContents.executeJavaScript(
            'const c=document.getElementById("content"); c.scrollTop=c.scrollHeight; true'
          );
          await new Promise((r) => setTimeout(r, 200));
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

  // 仅调试用：PET_TEST_TODO_SHOT=/path.png 时打开 Todo 清单并截图落盘，完成后自退
  // 可选 PET_TEST_TODO_TEXT="内容" PET_TEST_TODO_DUE=<epoch 秒> 预置一条带提醒的待办，验证时间徽章排版
  // 可选 PET_TEST_TODO_PICKER=1 展开提醒时间弹层；PET_TEST_TODO_CARD=1 改为截到期提醒卡
  if (process.env.PET_TEST_TODO_SHOT) {
    setTimeout(async () => {
      let seeded = null;
      if (process.env.PET_TEST_TODO_TEXT) {
        const added = todoStore.add(process.env.PET_TEST_TODO_TEXT, process.env.PET_TEST_TODO_DUE);
        if (added.ok) seeded = added.item.id;
      }
      let win;
      if (process.env.PET_TEST_TODO_CARD === '1') {
        win = openTodoReminderWindow({
          text: process.env.PET_TEST_TODO_TEXT || '给宠物倒粮（测试提醒）',
          subtitle: `约定时间 ${formatDueLabel(Math.floor(Date.now() / 1000) - 60)}`,
        });
      } else {
        win = openTodoWindow(todoStore.load());
      }
      try {
        await new Promise((r) => setTimeout(r, 1200));
        if (process.env.PET_TEST_TODO_PICKER === '1') {
          await win.webContents.executeJavaScript('document.getElementById("remindBtn").click(); true');
          await new Promise((r) => setTimeout(r, 200));
        }
        const image = await win.webContents.capturePage();
        require('fs').writeFileSync(process.env.PET_TEST_TODO_SHOT, image.toPNG());
        console.log('[todo-shot] 已保存', process.env.PET_TEST_TODO_SHOT);
      } catch (err) {
        console.error('[todo-shot] 失败', err);
      }
      if (seeded) todoStore.remove(seeded); // 不把调试待办留在用户数据里
      app.quit();
    }, 2500);
  }

  // 仅测试用：PET_TEST_TODO=1 时启动 2.5 秒后自动打开 Todo 清单
  if (process.env.PET_TEST_TODO === '1') {
    setTimeout(() => openTodoList(), 2500);
  }

  // 仅测试用：PET_TEST_TODO_REMINDER=1 时启动 2 秒后直接弹一张到期提醒卡（不写盘、不造样本数据）
  if (process.env.PET_TEST_TODO_REMINDER === '1') {
    setTimeout(() => fireTodoReminder({
      id: 'test',
      text: '给宠物倒粮（测试提醒）',
      due: Math.floor(Date.now() / 1000) - 60,
    }), 2000);
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
  if (todoReminder) todoReminder.stop();
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
