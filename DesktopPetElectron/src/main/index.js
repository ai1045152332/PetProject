// src/main/index.js
// DesktopPetElectron — 主进程入口
// 职责：应用生命周期 + 创建宠物窗口 + 喝水提醒调度 + Todo 待办与到期提醒 + 心跳上报 + 自动更新 + 权限校验码 + 每日天气提醒 + 主动搭话气泡 + IPC
'use strict';

const { app, BrowserWindow, Menu, ipcMain, globalShortcut, dialog, shell, screen, clipboard } = require('electron');
const path = require('path');
const { pathToFileURL } = require('url');
const { createPetWindow, applyPetScale, startOnTopGuard, createDragController } = require('./pet-window');
const { openReminderWindow, closeReminderWindow } = require('./reminder-window');
const { openSettingsWindow, closeSettingsWindow, sendToSettingsWin } = require('./settings-window');
const {
  SettingsService,
  currentPetScale,
  currentPetName,
  isValidPetState,
  isSwitchablePetState,
  panelPetStates,
  HIDE_STATE,
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
const contextMenuPrefs = require('./context-menu-prefs');
const { createSpeechBubble } = require('./speech-bubble');
const { createProactiveChat } = require('./proactive-chat');
const { startFocusModeMonitor, detectFocusMode, petStateForFocusMode } = require('./focus-mode-monitor');
const { snapToEdgeForHiding, revealFromEdge } = require('./edge-snap');
const { createCardWindow } = require('./card-window');
const { createNewsService } = require('./news-service');
const { createWeatherService } = require('./weather-service');
const access = require('./access-service');
const { createWeatherReminder } = require('./weather-reminder');
const { HeartbeatService } = require('./heartbeat');
const { UpdateService } = require('./update-service');
const { createSocialService } = require('./social-service');
const {
  setFriendChatAPI,
  openFriendChat,
  presentFriendMessages,
  closeFriendChat,
} = require('./friend-chat-window');
const {
  setFriendRequestHandlers,
  openFriendRequestCard,
  closeFriendRequestWindow,
} = require('./friend-request-window');
const { createPetImageService } = require('./pet-image-service');
const { createPetImageFlow, unlockNotice } = require('./pet-image-flow');
const {
  setPetImageHistoryAPI,
  openPetImageHistory,
  closePetImageHistory,
  refreshPetImageHistory,
} = require('./pet-image-history-window');
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
let weatherReminder = null; // 每日天气提醒调度（对标 mac 版 WeatherReminderService，需解锁）
let bubble = null;      // 宠物头顶气泡窗（对标 mac 版 showFeedBubble / catSay）
let chat = null;        // 主动搭话调度器（对标 mac 版 startProactiveChat）
let social = null;      // 好友与宠物消息客户端（对标 mac 版 FriendService）
let petImages = null;   // 自定义状态图片流程（对标 mac 版 PetImageService + 面板图片区的 busy/配额/状态文案）
// 已推给面板的宠物号（面板开着才推得动，变化去重避免心跳每分钟重推同一个号）
let pushedPetNo = 0;
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
 * 单例复用的卡片窗（新闻 / 天气）被反复 open 时只挂一次 closed 钩子，防止计数被重复扣减。
 */
function yieldTopTo(win) {
  if (!win || !petGuard) return;
  topYieldCount += 1;
  petGuard.pause(Infinity);
  if (win.__topYielded) return;
  win.__topYielded = true;
  win.once('closed', () => {
    topYieldCount = Math.max(0, topYieldCount - 1);
    if (topYieldCount === 0 && petGuard) petGuard.resume();
  });
}

// 宠物当前状态与贴边躲藏朝向由主进程状态机持有（对标 mac 版 PetViewModel），渲染层只是执行者
let petState = 'focus';
let petFacing = 'right';
// 系统勿扰 / 专注模式是否开启（决定基准态走 focus 还是 idel，对标 systemFocusActive）
let focusModeActive = false;
let focusMonitor = null;
// 正在贴边躲藏 / 一次性动画（抚摸）结束后该回到的状态
let isHiding = false;
let hideReturnState = null;

/** 当前基准态：勿扰/专注中→专注，否则→休闲（mac 版 systemFocusActive ? .focus : .idel） */
function basePetState() {
  return petStateForFocusMode(focusModeActive);
}

// 切换宠物形象：换帧目录（focus / idel / sleep / pet / hide）+ 推躲藏朝向。
// 设置面板、右键「抚摸」、专注跟随、贴边躲藏共用这一条链路。
// facing 只在躲藏态有意义（素材只画一侧探头，贴右边时镜像），其余状态原样带上以免丢朝向。
function applyPetState(state) {
  if (state === HIDE_STATE) {
    // 躲藏只能由贴边吸附 / 右键「躲起来」进入，面板能预览该态但不能手动切
    isHiding = true;
  } else if (state) {
    isHiding = false;
    hideReturnState = null;
  }
  petState = state;
  sendToRenderer('pet:state', { state, facing: petFacing });
  // 面板开着时同步当前形象：躲藏 / 专注跟随这些不经过面板的切换也要能看到
  sendToSettingsWin('settings:pet-state', { state, facing: petFacing });
  console.log(`[settings] petState -> ${state}`);
  return { ok: true, state };
}

/** 把专注跟随的结果只施加在专注/休闲两态上，不打断睡觉/抚摸/躲藏 */
function applyFocusState() {
  if (petState === 'focus' || petState === 'idel') applyPetState(basePetState());
}

// 内置帧数：按 assets/Sprites 目录枚举，与 Swift 侧一样不在代码里写死
// （素材已统一到 SharedAssets/Sprites，idel / pet 是 24 帧，写死 8 会只播前三分之一）
// 启动时读一次即可：运行期素材不变（随安装包只读）
const frameCounts = spriteFrames.readFrameCounts(
  path.join(__dirname, '..', '..', 'assets', 'Sprites'),
);

// 右键「抚摸」一次性播放（对标 Swift playOneShot）：播完一圈自动回原状态，设置面板切形象仍是永久的
// 躲藏中抚完回到躲藏（getRestoreState），不把只探头的猫拉回屏内
const petting = createPettingOneShot({
  getState: () => petState,
  setState: (state) => { applyPetState(state); },
  getRestoreState: () => (hideReturnState && hideReturnState !== 'pet' ? hideReturnState : basePetState()),
  frames: frameCounts.pet || 8, // 读不到目录时兜底按 8 帧播一圈
});

// ── 贴边躲藏（对标 mac 版 PetViewModel.snapToEdgeForHiding / revealFromEdge）──
// 窗口位置/尺寸在主进程，所以吸附判断也在主进程；渲染层只负责把画面贴到那条边 + 镜像。

/** 拿窗口所在显示器的工作区（DIP，与 getBounds 同一坐标系） */
function workAreaOf(win) {
  return screen.getDisplayMatching(win.getBounds()).workArea;
}

/**
 * 贴边进入躲藏：requiresNearEdge=false（右键「躲起来」）时不看距离直接吸到最近一侧。
 * @param {boolean} requiresNearEdge 是否要求已拖近屏幕侧边
 * @returns {boolean} 是否真的吸附了（没贴边返回 false，状态不变）
 */
function snapToEdgeForHide(requiresNearEdge = true) {
  const win = ensurePetWindow();
  if (win.isDestroyed()) return false;
  const snapped = snapToEdgeForHiding({
    bounds: win.getBounds(),
    area: workAreaOf(win),
    requiresNearEdge,
  });
  if (!snapped) return false;
  petFacing = snapped.facing;
  // 先存返回态再切状态：applyPetState 进躲藏时不会动它，离开躲藏才会清空
  hideReturnState = petState === HIDE_STATE ? basePetState() : petState;
  win.setBounds(snapped.bounds);
  applyPetState(HIDE_STATE);
  console.log(`[pet] 贴边躲藏: edge=${snapped.facing}, 边距=${snapped.gap}px, 吸附到 ${snapped.bounds.x},${snapped.bounds.y}`);
  return true;
}

/** 从躲藏中现身：窗口完整收回屏内，并回到躲藏前的状态（默认基准态） */
function revealFromHiding() {
  const win = ensurePetWindow();
  if (win.isDestroyed()) return;
  const target = hideReturnState || basePetState();
  hideReturnState = null;
  isHiding = false;
  const bounds = revealFromEdge({ bounds: win.getBounds(), area: workAreaOf(win) });
  win.setBounds(bounds);
  applyPetState(target);
  console.log(`[pet] 从躲藏现身 -> ${target}`);
}

/**
 * 拖动结束：躲藏中被拖动即视为拖出现身；否则松手位置贴屏幕侧边就吸附探头
 *（对齐 mac 版 CatView.mouseUp 拖动分支）。
 */
function handleDragEnd() {
  if (!petDrag) return;
  const moved = petDrag.dragging;
  petDrag.end();
  if (!moved) return;
  if (isHiding) revealFromHiding();
  else snapToEdgeForHide(true);
}

// 向渲染进程发送事件（窗口存在才发）
function sendToRenderer(channel, payload) {
  if (petWindow && !petWindow.isDestroyed()) {
    petWindow.webContents.send(channel, payload);
  }
}

// 状态 id → 中文名（图片对话框标题与各态文案统一用它，与面板形象区同一份字典）
const spriteStateLabels = Object.fromEntries(panelPetStates().map((s) => [s.id, s.label]));

// 各状态自定义形象图 → file:// URL 映射（无自定义为 null，渲染层据此回退内置帧动画）。
// 存储不在安装包内（mac 与 mac 版 App 共用 Application Support 目录，Win 在 userData），
// 升级/换版本都不会碰它；渲染层用 file: 读（pet/index.html CSP 已放行 img-src file:）。
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

/** 宠物号变化时推给开着的面板（没开就静默丢弃，下次打开走 settings:load 兜底） */
function broadcastPetNo(petNo) {
  const value = Number(petNo) || 0;
  if (value <= 0 || value === pushedPetNo) return;
  pushedPetNo = value;
  sendToSettingsWin('settings:pet-no', { petNo: value });
}

/**
 * 申请卡上的「同意 / 拒绝」：主进程直接打服务端，结果推给停在好友区的面板对齐列表
 * （面板不必自己再拉一次网络，只按回传的好友列表与待移除的申请 ID 重排）。
 */
async function decideFriendRequestFromCard(action, req) {
  if (!social || !req) return;
  const res = await social.decideRequest(action, req.fromPetNo).catch(() => null);
  if (!res || !res.ok) {
    console.warn(`[social] 申请卡 ${action} #${req.fromPetNo} ✗ ${(res && res.error) || '未知错误'}`);
    return;
  }
  console.log(`[social] 申请卡 ${action} #${req.fromPetNo} ✓`);
  sendToSettingsWin('settings:social-changed', {
    friends: res.friends || [],
    removeRequestId: req.id || '',
    notice: action === 'accept'
      ? `已同意 ${req.display} 的申请，你们互为好友了`
      : `已拒绝 ${req.display} 的申请`,
  });
}

/**
 * 心跳下发内容统一入口（对标 mac 版 HeartbeatService.consume）：
 * 宠物号先缓存，同一条好友申请在用户做出选择前会被持续下发，靠本地「已弹过 ID」去重只弹一次；
 * 留言整批交给常驻会话窗展示（未确认已读前服务端会重投，所以弹不完也不会丢）。
 */
function handleHeartbeatDelivery(data) {
  if (!social) return;
  const petNo = Number(data.petNo) || 0;
  if (petNo > 0) {
    social.setMyPetNo(petNo);
    broadcastPetNo(petNo);
  }
  const delivery = social.parseDelivery(data);
  for (const req of social.markRequestsShown(delivery.requests)) {
    console.log(`[social] 收到好友申请 #${req.fromPetNo} ${req.fromName}`);
    yieldTopTo(openFriendRequestCard(req));
  }
  if (delivery.messages.length) {
    console.log(`[social] 收到好友消息 ${delivery.messages.length} 条`);
    yieldTopTo(presentFriendMessages(delivery.messages));
  }
}

// 切换宠物窗显示 / 隐藏（托盘 / 右键菜单 / 快捷键用）
function togglePet() {
  const win = ensurePetWindow();
  if (win.isVisible()) {
    // 收起气泡：气泡浮在一只看不见的猫头顶没意义（立即关，不等淡出）
    if (bubble) bubble.dismiss();
    win.hide();
  } else {
    // 躲藏中走「显示宠物」：半截身子在屏外，直接显示会看着像只残猫，先现身
    if (isHiding) revealFromHiding();
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
    openNews: () => openNews(),
    openWeather: () => openWeather(),
    openTodo: () => openTodoList(),
    hide: () => snapToEdgeForHide(false),
    // 「菜单设置」区的勾选结果：被关掉的项不进菜单，标题与面板共用同一份 prefs
    menuVisible: (key) => contextMenuPrefs.isVisible(key),
    menuTitle: (key) => contextMenuPrefs.title(key),
    // 权限控制（对标 Swift rightMouseDown）：新闻/天气属高级功能，基础权限置灰并尾部加解锁引导
    fullAccess: access.isFullAccess(),
    openAccessSettings: () => openSettings(),
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
  // 躲藏中的猫被提醒拉回专注时，窗口要同时收回屏内，不能只探个头在屏外喝水
  if (isHiding) revealFromHiding();
  else applyPetState('focus'); // 专注动画从帧头重播唤起注意（对齐 mac 版提醒走专注）
}

// 打开设置面板（打开期间宠物让出置顶，否则宠物会盖住面板）
function openSettings() {
  yieldTopTo(openSettingsWindow());
}

// 打开 Todo 清单（双击宠物 / 右键菜单入口，对标 mac 版 showTodoList）：同样让出置顶层
function openTodoList() {
  yieldTopTo(openTodoWindow(todoStore.load()));
}

// ── 热点新闻 / 天气（对标 mac 版 NewsFetcher + WeatherService + HTMLAlertWindow）──
// 两个结果卡都是单例复用卡片窗：抓取/查询在主进程，渲染页只展示 IPC 推来的内容
const newsService = createNewsService();
const weatherService = createWeatherService();

const newsWin = createCardWindow({
  name: 'news',
  title: '今日热点新闻',
  width: 460,
  height: 560,
  htmlFile: 'news.html',
  preloadFile: 'news-preload.js',
  updateChannel: 'news:update',
});

const weatherWin = createCardWindow({
  name: 'weather',
  title: '查看天气',
  width: 380,
  // 预报卡实测约 470 高（含输入行与卡片内边距），窗口再高会在底板下方留大片空白
  height: 520,
  htmlFile: 'weather.html',
  preloadFile: 'weather-preload.js',
  updateChannel: 'weather:update',
});

// 打开新闻卡：先弹「加载中」并把窗体立起来，抓完再推列表（对标 mac 版 showLoadingToast 体验）
async function openNews() {
  // 高级功能（按量付费）：菜单置灰之外再在入口兜一道，防其它触发点绕过权限
  if (!access.isFullAccess()) {
    openAccessGuide();
    return;
  }
  const win = newsWin.open({ items: [], loading: true });
  yieldTopTo(win);
  const items = await newsService.fetchHotNews();
  if (newsWin.isOpen()) newsWin.open({ items, loading: false });
}

// 推天气内容给窗体（窗没开则忽略）
function pushWeather(content) {
  if (weatherWin.isOpen() && weatherWin.getWindow()) {
    weatherWin.getWindow().webContents.send('weather:update', content);
  }
}

// 按城市查天气并推结果（空串 = 本地 IP 定位；对标 mac 版 fetchWeatherAndShow）
async function queryWeather(city) {
  const target = String(city || '').trim();
  pushWeather({ message: target ? `🌤️ 正在查询 ${target} 的天气...` : '🌤️ 正在加载本地天气...' });
  const forecast = target
    ? await weatherService.fetchByCity(target)
    : await weatherService.fetchLocal();
  pushWeather(forecast
    ? { forecast }
    : { message: '天气获取失败，请稍后再试' });
}

// 打开天气窗：先弹带「本地天气加载中」的窗，随后自动查本地天气；输入城市同窗切换（对标 mac 版 showWeatherInput）
function openWeather() {
  if (!access.isFullAccess()) {
    openAccessGuide();
    return;
  }
  const win = weatherWin.open({ message: '🌤️ 正在加载本地天气...' });
  yieldTopTo(win);
  queryWeather('');
}

// 基础权限下碰到高级功能：不开卡窗，直接引导到设置面板权限区（对齐 Swift 解锁引导）
function openAccessGuide() {
  console.log('[access] 基础权限拦截高级功能调用，引导去解锁');
  openSettings();
}

// 每日天气提醒推送（对标 Swift WeatherReminderService.deliver）：按配置城市（留空按定位）查天气，同窗展示结果
function deliverWeatherReminder() {
  const city = String(config.get('weatherReminderCity') || '').trim();
  const win = weatherWin.open({ message: '🌤️ 正在获取今日天气...' });
  yieldTopTo(win);
  queryWeather(city);
}

// Todo 到期触达：弹常驻提醒卡（需用户点 ✕ 才收起），并让宠物专注动画从头播放唤起注意
// 睡 / 隐藏中也要弹，否则会漏提醒（与 mac 版 checkTodoReminders 一致）
function fireTodoReminder(item) {
  yieldTopTo(openTodoReminderWindow({
    id: item.id,
    text: item.text,
    subtitle: item.due ? `约定时间 ${formatDueLabel(item.due)}` : '',
  }));
  sendToRenderer('todo:remind', { state: 'focus', reset: true });
  if (isHiding) revealFromHiding(); // 同喝水提醒：躲藏中被拉回专注时先把身子收回屏内
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

  // 系统勿扰 / 专注模式跟随（对标 mac 版 FocusModeMonitor.start）：
  // 开着勿扰→专注，关掉→休闲；只施加在专注/休闲两态上，不打断睡觉 / 躲藏
  focusMonitor = startFocusModeMonitor({
    onChange: (active) => {
      focusModeActive = active;
      applyFocusState();
    },
  });
  // 启动时先对齐一次实际系统状态（Windows 走子进程读注册表，只能异步）
  detectFocusMode().then((active) => {
    focusModeActive = active;
    applyFocusState();
  });

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

  // 设置面板业务逻辑（提醒间隔 / 宠物名称 / 宠物大小 / 天气提醒），与 IPC 接线分离
  settings = new SettingsService({
    scheduler,
    providers: {
      version: () => info.currentVersion(),
      petNo: () => config.get('petNo') || 0,
      petState: () => petState,
      autoLaunch: isAutoLaunchEnabled,
      heartbeat: () => (heartbeat ? heartbeat.getStatus() : null),
      isFullAccess: access.isFullAccess,
      // 图片区快照：flow 在 app ready 后才建，面板首次 load 时必定已就绪（闭包里现取）
      petImages: () => (petImages ? petImages.snapshot() : {}),
    },
  });

  // 每日天气提醒：开关/时间存 config，到点先过权限守卫再推（基础权限不提醒，天气接口按量付费）
  weatherReminder = createWeatherReminder({
    isEnabled: () => Boolean(config.get('weatherReminderEnabled')),
    getHour: () => config.get('weatherReminderHour'),
    getMinute: () => config.get('weatherReminderMinute'),
    isFullAccess: access.isFullAccess,
    fire: deliverWeatherReminder,
  });
  weatherReminder.start();

  // 宠物头顶气泡（对标 mac 版 FloatingWindow.catSay / showFeedBubble）：所有「小猫说话」都从这里出
  bubble = createSpeechBubble({ getPetWindow: () => petWindow });

  // 主动搭话（对标 mac 版 startProactiveChat）：启动 20 秒后一句时段问候，
  // 之后按面板设的间隔在热搜 / Todo 之间轮换冒泡；勿扰、睡觉、躲藏、抚摸中都不打扰
  chat = createProactiveChat({
    say: (text) => (bubble ? bubble.say(text) : false),
    // 热搜源与新闻卡共用同一份抓取链路（后台只存标题做缓存，失败保留旧缓存）
    fetchHeadlines: () => newsService.fetchHotNews(),
    todoCount: () => todoStore.load().length,
    isSystemFocusActive: () => focusModeActive,
    getPetState: () => petState,
    isPlayingOneShot: () => petting.isPlaying(),
  });
  // 回填给设置面板：改开关 / 间隔后按新节奏立即重挂周期定时器
  settings.proactiveChat = chat;
  chat.start();

  // 好友与宠物消息（对标 mac 版 FriendService）：取宠物号、好友与申请、留言收发都走加密信封打服务端
  social = createSocialService({
    // 宠物号变化（register / 心跳下发）时同步推给开着的面板
    onPetNo: (petNo) => broadcastPetNo(petNo),
    petName: () => info.petName(),
  });

  // 会话窗能力注入：本模块只管窗口与排版，网络全部回到 social 这一条链路
  setFriendChatAPI({
    history: (petNo) => social.conversationHistory(petNo),
    send: (petNo, text) => social.sendMessage(petNo, text),
    confirmRead: (ids) => social.confirmRead(ids),
    myPetNo: () => social.myPetNo(),
    petName: () => info.petName(),
  });

  // 申请卡：用户做出选择才服务端建立（或取消）双向好友关系
  setFriendRequestHandlers({
    onAccept: (req) => decideFriendRequestFromCard('accept', req),
    onReject: (req) => decideFriendRequestFromCard('reject', req),
  });

  // 自定义状态图片（对标 mac 版 PetImageService + CustomSpriteStore）：
  // AI 生成 / 重试走 pet-image-service（加密信封打 /api/pet-images），落盘与历史走 custom-sprite-store，
  // 本处只把两侧变化扇出去：宠物窗立刻换图、面板与历史窗拿同一份快照
  petImages = createPetImageFlow({
    service: createPetImageService(),
    sprites: customSprites,
    onSpritesChanged: () => {
      sendSpriteSnapshot();
      refreshPetImageHistory();
    },
    onSnapshot: (snapshot) => {
      sendToSettingsWin('settings:pet-images', snapshot);
      refreshPetImageHistory();
    },
  });

  // 历史图片窗能力注入：本模块只管窗口与排版，判定与网络都回到 flow 这一条链路
  setPetImageHistoryAPI({
    snapshot: () => petImages.snapshot(),
    applyImage: (key, state) => petImages.applyHistoryImage(key, state),
    deleteImage: (key) => petImages.deleteHistoryImage(key),
    retry: (state) => petImages.retryGeneration(state),
    clearFailure: (state) => petImages.clearHistoryFailure(state),
    setHistoryVisible: (visible) => petImages.setHistoryVisible(visible),
  });

  // 应用菜单：mac 上提供「设置…」与 Cmd+,（保留编辑菜单，设置面板的输入框才支持复制粘贴）
  buildAppMenu();

  // 心跳上报：启动即报一次，之后每 1 分钟一次（与 mac 版同节奏、同上报体）
  // 响应顺带回传宠物号 / 好友申请 / 好友留言，统一交给 handleHeartbeatDelivery
  heartbeat = new HeartbeatService({ getState: () => petState, onDelivery: handleHeartbeatDelivery });
  heartbeat.start();

  // 自动更新：启动 30 秒后首次检查，之后每 24 小时一次；托盘菜单可手动触发
  // 同节奏顺带复核激活码（对标 mac 版 UpdateService 里 AccessControl.revalidate）：
  // 被收回时推一次权限变化给开着的面板，控件随即回到置灰态
  updater = new UpdateService({
    onStatus: onUpdateStatus,
    revalidateAccess: async () => {
      const result = await access.revalidate();
      if (result === 'revoked') sendToSettingsWin('settings:access-changed', { fullAccess: false });
      return result;
    },
  });
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

  // ── 热点新闻 IPC（对标 mac 版 showHotNewsAlert：主进程抓回 Top10，渲染层纯展示）──
  ipcMain.handle('news:payload', () => newsWin.getWindow()?.__cardPayload || { items: [], loading: true });
  ipcMain.on('news:dismiss', () => newsWin.close());
  // 热搜条目的链接走系统浏览器（渲染层 CSP 锁 self，外链统一交给 shell）
  ipcMain.on('news:open-link', (event, url) => {
    if (/^https?:\/\//i.test(String(url || ''))) {
      shell.openExternal(url);
    }
  });

  // ── 天气 IPC（对标 mac 版 showWeatherInput：窗内输入城市 → 同窗刷新内容）──
  ipcMain.handle('weather:payload', () => weatherWin.getWindow()?.__cardPayload
    || { message: '🌤️ 正在加载本地天气...' });
  ipcMain.on('weather:dismiss', () => weatherWin.close());
  ipcMain.handle('weather:query-city', (event, city) => {
    queryWeather(city);
    return { ok: true };
  });

  // ── 气泡窗 IPC（台词由主进程推，渲染层只排版）──
  // 窗刚加载完主动拉一次当前台词：避开「先 send 后挂监听」丢第一句
  ipcMain.handle('bubble:payload', () => ({ text: bubble ? bubble.currentText() : '' }));
  // 渲染层量完文字尺寸回报：主进程据此改盒大小、贴到猫头顶并显形
  ipcMain.on('bubble:resize', (event, payload) => {
    const p = payload || {};
    if (bubble) bubble.handleResize(p.width, p.height);
  });
  // 点一下气泡：播淡出动画收起（与 mac 版 bubbleView.onClick 一致）
  ipcMain.on('bubble:dismiss', () => {
    if (bubble) bubble.fadeOut();
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

  // 菜单设置：勾 / 取消宠物右键菜单的功能项（写盘即生效，下次弹菜单就是新内容）
  ipcMain.handle('settings:set-menu-item', (event, payload) => {
    const p = payload || {};
    const result = settings.setMenuItemVisible(p.key, p.visible);
    console.log(`[settings] contextMenu ${p.key} -> ${result.ok ? (result.visible ? '展示' : '隐藏') : `✗ ${result.error}`}`);
    return result;
  });

  // 主动搭话：写开关 / 间隔（主进程收敛 1~720 分钟）→ 立即按新节奏重建周期搭话
  ipcMain.handle('settings:set-proactive-chat', (event, patch) => {
    const result = settings.setProactiveChat(patch);
    console.log(`[settings] proactiveChat -> ${JSON.stringify(patch)} ${result.ok ? '✓' : `✗ ${result.error}`}`);
    return result;
  });

  ipcMain.on('settings:close', () => closeSettingsWindow());

  // ── 好友消息 IPC（对应 mac 版 SettingsPanel 好友分区 + FriendChatWindow）──
  // 一次拉齐宠物号 + 好友列表 + 待处理申请（服务端不可用时只回 error，面板保留现有列表）
  ipcMain.handle('social:sync', () => social.syncAll());

  // 复制宠物号：渲染层读不到系统剪贴板，统一在主进程写（没号时给明确提示）
  ipcMain.handle('social:copy-pet-no', () => {
    const petNo = social.myPetNo();
    if (petNo <= 0) return { ok: false, error: '宠物号尚未分配，先点「刷新」获取' };
    clipboard.writeText(String(petNo));
    return { ok: true, petNo };
  });

  ipcMain.handle('social:add', (event, payload) => social.addFriend((payload || {}).petNo));

  ipcMain.handle('social:decide', (event, payload) => {
    const p = payload || {};
    return social.decideRequest(p.action === 'reject' ? 'reject' : 'accept', p.fromPetNo);
  });

  ipcMain.handle('social:remove', (event, payload) => social.removeFriend((payload || {}).petNo));

  // 打开会话窗（已开着同一位好友时只并入消息并前置，不重开）
  ipcMain.handle('social:open-chat', (event, payload) => {
    const p = payload || {};
    yieldTopTo(openFriendChat({ petNo: p.petNo, display: p.display }));
    return { ok: true };
  });

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
    if (!isSwitchablePetState(state)) {
      // 面板上的「躲藏」格只用于预览/上传探头图：没吸附就切过去，等于半个身子还在屏外
      return {
        ok: false,
        error: '躲藏形象由拖到屏幕边缘或右键「躲起来」触发，不能手动切换',
        state: petState,
      };
    }
    // 躲藏中从面板切形象：先把身子收回屏内，否则新动画会有一半画在屏幕外
    if (isHiding) revealFromHiding();
    return applyPetState(state);
  });

  // ── 自定义状态图片（直接上传 / 恢复默认，存本机 CustomSprites 目录，App 更新不丢）──
  // 面板预览：返回各状态当前生效图的 file:// URL（无自定义为 null），
  // 渲染层据此显示自定义图，为 null 时回落到内置 frame_00 预览
  ipcMain.handle('settings:list-custom-sprite', () => spriteUrlMap());

  // 直接上传：原图（含 GIF 动图）只存本机，不需要激活码、不占生成配额、即时生效
  ipcMain.handle('settings:pick-custom-sprite', async (event, state) => {
    if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
    if (petImages.isBusy()) return { ok: false, error: '正在处理图片，请稍候' };
    const win = BrowserWindow.fromWebContents(event.sender);
    const label = spriteStateLabels[state] || state;
    const res = await dialog.showOpenDialog(win, {
      title: `选择${label}状态图片`,
      message: `PNG/JPEG/GIF，最大 10 MB；原图直接作为${label}状态图片，仅保存在本机`,
      properties: ['openFile'],
      filters: [{ name: '图片', extensions: ['png', 'jpg', 'jpeg', 'gif'] }],
    });
    if (res.canceled || !res.filePaths.length) return { ok: false, canceled: true };
    const result = petImages.uploadLocal(state, res.filePaths[0]);
    // 快照与宠物窗换图都由 flow 的回调统一扇出，这里不再重复推
    console.log(`[custom-sprite] ${state} 直接上传 ${result.ok ? '✓' : `✗ ${result.error}`}`);
    return result;
  });

  // 恢复默认：完全本地——清掉该状态的直传图与选中标识，不改动服务端
  ipcMain.handle('settings:clear-custom-sprite', (event, state) => {
    if (!isValidPetState(state)) return { ok: false, error: '不支持的形象' };
    const result = petImages.restoreDefault(state);
    console.log(`[custom-sprite] ${state} 恢复默认 ${result.ok ? '✓' : `✗ ${result.error}`}`);
    return result;
  });

  // ── 云端形象图：配额 / AI 生成 / 历史图片窗（对标 mac 版 generateAllStatesWithAI + showPetImageHistory）──
  // 面板停在图片区时刷一次剩余生成次数（无码 / 生成中由 flow 自己回落，不报错不打扰）
  ipcMain.handle('pet-image:refresh', () => petImages.refreshQuota());

  // AI 生成所有状态：一张照片 → 服务端逐状态各生成一张 → 全部落本机并生效
  ipcMain.handle('pet-image:generate-all', async (event) => {
    // 面板已拦一道，这里再兜一次：无码时不该让用户白选一张照片
    if (!access.serverActivationCode()) return { ok: false, error: unlockNotice() };
    if (petImages.isBusy()) return { ok: false, error: '正在处理图片，请稍候' };
    const win = BrowserWindow.fromWebContents(event.sender);
    const res = await dialog.showOpenDialog(win, {
      title: '选择宠物照片',
      message: 'PNG/JPEG，最大 10 MB；照片将为全部 5 个状态各生成一张图片（姿态按状态区分），整批仅消耗 1 次生成配额',
      properties: ['openFile'],
      filters: [{ name: '图片', extensions: ['png', 'jpg', 'jpeg'] }],
    });
    if (res.canceled || !res.filePaths.length) return { ok: false, canceled: true };
    const result = await petImages.generateAllStates(res.filePaths[0]);
    console.log(`[pet-image] AI 生成 ${result.ok ? `✓ 应用 ${result.applied} 个/失败 ${result.failed} 个` : `✗ ${result.error}`}`);
    return result;
  });

  // 打开历史图片窗（已开着就前置复用）：按当前形象定位，开完后台补一次旧图归属
  ipcMain.handle('pet-image:open-history', (event, payload) => {
    const raw = String((payload || {}).state || petState);
    const state = isValidPetState(raw) ? raw : '';
    yieldTopTo(openPetImageHistory({ state }));
    petImages.backfillOwnership();
    return { ok: true };
  });

  // 宠物窗刚加载完主动拉一次当前自定义形象（上传/清除期间再通过 pet:sprite 推送增量）
  ipcMain.handle('pet:sprite-snapshot', () => spriteUrlMap());

  // 宠物窗拉内置帧数清单（pet.js 据此循环，不再写死 8 帧）
  ipcMain.handle('pet:frame-counts', () => frameCounts);

  // ── 通用设置：宠物大小 / 开机自启 / 检查更新 ──
  ipcMain.handle('settings:set-pet-scale', (event, scale) => {
    const result = settings.setPetScale(scale);
    if (result.ok) {
      // 返回值非空 = 原本贴边躲藏，已按新尺寸重新吸附（推一次把朝向 / 状态同步给渲染层）
      const snapped = applyPetScale(petWindow, result.scale);
      if (snapped) sendToRenderer('pet:state', { state: petState, facing: petFacing });
    }
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

  // ── 权限（校验码解锁）与每日天气提醒 IPC（对标 mac 版 unlockAccess / clearAccess / 天气提醒卡片）──
  // 解锁/清除的判定全在 access-service（本地码 456 直过；否则加密后走 /api/access/verify），
  // 面板只拿结果码回填提示；解锁成功立刻重排天气提醒（开关可能早已开着）
  ipcMain.handle('settings:unlock-access', async (event, code) => {
    const result = await access.unlock(code);
    if (result === 'success') {
      sendToSettingsWin('settings:access-changed', { fullAccess: true });
      if (weatherReminder) weatherReminder.reschedule();
    }
    console.log(`[access] unlock -> ${result}`);
    return { ok: result === 'success', result, fullAccess: access.isFullAccess() };
  });

  ipcMain.handle('settings:clear-access', () => {
    access.clearAccess();
    sendToSettingsWin('settings:access-changed', { fullAccess: false });
    console.log('[access] 权限已清除，回到基础权限');
    return { ok: true, fullAccess: false };
  });

  // 每日天气提醒：写配置（主进程二次把关：未解锁拒改）→ 重排调度
  ipcMain.handle('settings:set-weather-reminder', (event, patch) => {
    const result = settings.setWeatherReminder(patch);
    if (result.ok && weatherReminder) weatherReminder.reschedule();
    console.log(`[settings] weatherReminder -> ${JSON.stringify(patch)} ${result.ok ? '✓' : `✗ ${result.error}`}`);
    return result;
  });

  // 预览：立刻按配置推一次今日天气（对标 previewWeatherReminder，仅解锁可用）
  ipcMain.handle('settings:preview-weather', () => {
    if (!access.isFullAccess()) {
      return { ok: false, error: '需解锁全部功能后可用（天气接口按量付费）' };
    }
    deliverWeatherReminder();
    return { ok: true };
  });

  // ── 鼠标交互 IPC：手动拖窗 + 右键菜单（事件源在渲染层，见 pet.js / preload.js）──
  // 不用 CSS -webkit-app-region: drag，也不用 webContents 的 context-menu 事件：
  // 原生拖拽区会吞鼠标事件，之前 sendInputEvent 验证绕过了这条链路导致误判可用
  ipcMain.on('pet:drag-start', (event, { x, y }) => petDrag && petDrag.start(x, y));
  ipcMain.on('pet:drag-move', (event, { x, y }) => petDrag && petDrag.move(x, y));
  // 松手：拖动过→贴边判定 / 拖出现身；原地点松手→当作单击（pet:pet-click）
  ipcMain.on('pet:drag-end', () => handleDragEnd());

  // 单击小猫（对标 mac 版 CatView.mouseUp 非拖动分支）：
  // 躲藏中被点 -> 先现身；否则点一下走专注动作唤起注意
  ipcMain.on('pet:pet-click', () => {
    if (isHiding) {
      revealFromHiding();
      return;
    }
    applyPetState('focus');
  });

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
    readers: {}, // 主进程不采集：快照全部来自 cacheOnly
  });
  sysinfoCache = createCacheOnlySnapshot();
  sysinfo.setCacheOnly(sysinfoCache);
  sysinfoWorker = startWorker({
    getOption: (key) => config.get(key),
    onSnapshot: (snap) => sysinfoCache.apply(snap),
    // title：无素材时的纯文字回落；parts：mac 顶栏合成图（猫 + SF Symbol 瓦片 + 数字）的输入
    onTitle: (title, parts) => setTrayTitle(title, parts),
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
  // 可选 PET_TEST_SETTINGS_CLICK_STATE=<state> 预先点一下某一格形象
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
        // 可选 PET_TEST_SETTINGS_CLICK_STATE=hide：预先点一下某一格形象（验证躲藏格「只选中不切换」）
        const clickState = process.env.PET_TEST_SETTINGS_CLICK_STATE;
        if (clickState) {
          await win.webContents.executeJavaScript(
            `document.querySelector('.sprite-tile[data-state="${clickState}"]').click(); true`
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

  // 仅测试用：PET_TEST_NEWS=1 / PET_TEST_WEATHER=1 时启动 2 秒后自动打开新闻卡 / 天气窗
  if (process.env.PET_TEST_NEWS === '1') {
    setTimeout(openNews, 2000);
  }
  if (process.env.PET_TEST_WEATHER === '1') {
    setTimeout(openWeather, 2000);
  }

  // 仅调试用：截图落盘验证新闻卡 / 天气窗（完成后自退）
  // 新闻在 openNews 内部等抓回后再截；天气等本地查询链路（IP 定位 + 后端）给 8 秒
  const shotWindow = async (envPath, win, settleMs, label) => {
    try {
      await new Promise((r) => setTimeout(r, settleMs));
      if (!win || win.isDestroyed()) throw new Error('窗口未打开');
      const image = await win.webContents.capturePage();
      require('fs').writeFileSync(envPath, image.toPNG());
      console.log(`[${label}] 已保存`, envPath);
    } catch (err) {
      console.error(`[${label}] 失败`, err);
    }
    app.quit();
  };
  if (process.env.PET_TEST_NEWS_SHOT) {
    setTimeout(async () => {
      await openNews();
      shotWindow(process.env.PET_TEST_NEWS_SHOT, newsWin.getWindow(), 300, 'news-shot');
    }, 2000);
  }
  if (process.env.PET_TEST_WEATHER_SHOT) {
    setTimeout(() => {
      // PET_TEST_WEATHER_MOCK=1：只验 UI 排版，推一份假预报数据，不打按量付费的 /api/weather
      if (process.env.PET_TEST_WEATHER_MOCK === '1') {
        const mockForecast = {
          city: '杭州（模拟）', nowTemp: '21', nowText: '多云', todayMax: '25', todayMin: '15',
          hourly: [
            { time: '15:00', temp: '22', text: '晴', icon: '☀️' },
            { time: '16:00', temp: '22', text: '多云', icon: '⛅' },
            { time: '17:00', temp: '21', text: '阴', icon: '☁️' },
            { time: '18:00', temp: '19', text: '小雨', icon: '🌧️' },
            { time: '19:00', temp: '18', text: '雷阵雨', icon: '🌧️' },
            { time: '20:00', temp: '17', text: '雾', icon: '🌫️' },
          ],
          daily: [
            { dayName: '今天', textDay: '多云', tempMax: '25', tempMin: '15', icon: '⛅' },
            { dayName: '明天', textDay: '晴', tempMax: '31', tempMin: '18', icon: '☀️' },
            { dayName: '后天', textDay: '小雨', tempMax: '22', tempMin: '12', icon: '🌧️' },
          ],
        };
        // 假数据直接放进初始 payload：渲染层加载完主动 invoke 拉到，不依赖推送时序
        const w = weatherWin.open({ forecast: mockForecast });
        yieldTopTo(w);
        shotWindow(process.env.PET_TEST_WEATHER_SHOT, w, 1500, 'weather-shot');
        return;
      }
      openWeather();
      shotWindow(process.env.PET_TEST_WEATHER_SHOT, weatherWin.getWindow(), 8000, 'weather-shot');
    }, 2000);
  }

  // 仅调试用：PET_TEST_SAY="台词" 时启动 2 秒后让猫冒一句气泡（验排版与跟随，不必等搭话周期）
  // 可选 PET_TEST_SAY_SHOT=/path.png：气泡显形后截图落盘，完成后自退
  if (process.env.PET_TEST_SAY) {
    setTimeout(() => {
      bubble && bubble.say(process.env.PET_TEST_SAY);
      const shot = process.env.PET_TEST_SAY_SHOT;
      if (!shot) return;
      setTimeout(async () => {
        const w = bubble && bubble.getWindow();
        try {
          if (!w) throw new Error('气泡窗未打开');
          const image = await w.webContents.capturePage();
          require('fs').writeFileSync(shot, image.toPNG());
          console.log('[bubble-shot] 已保存', shot);
        } catch (err) {
          console.error('[bubble-shot] 失败', err);
        }
        app.quit();
      }, 900);
    }, 2000);
  }

  // 仅调试用：PET_TEST_CHAT=1 时启动 1.5 秒后立刻跑一次搭话逻辑（跳过 20 秒首句与周期等待）
  if (process.env.PET_TEST_CHAT === '1') {
    setTimeout(() => chat && chat.performProactiveChat(), 1500);
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

  // 仅测试用：PET_TEST_FOCUS=1 时启动 2 秒后强制把宠物切到专注、再 3 秒后切回休闲
  //（验证专注链路，不需要真开系统勿扰；不依赖监视器的轮询节奏）
  if (process.env.PET_TEST_FOCUS === '1') {
    setTimeout(() => { focusModeActive = true; applyFocusState(); }, 2000);
    setTimeout(() => { focusModeActive = false; applyFocusState(); }, 5000);
  }

  // 仅测试用：PET_TEST_HIDE=1 时启动 2 秒后模拟一次「拖到屏幕右边缘松手」：
  // 先把窗推到右边缘 30px 处（小于触发阈值 60），再走拖动结束链路吸附
  if (process.env.PET_TEST_HIDE === '1') {
    setTimeout(() => {
      const win = ensurePetWindow();
      const area = workAreaOf(win);
      const [w, h] = win.getSize();
      win.setBounds({ x: area.x + area.width - w - 30, y: area.y + 40, width: w, height: h });
      if (petDrag) petDrag.start(win.getBounds().x + 10, win.getBounds().y + 10);
      handleDragEnd();
      console.log('[test-hide] 已模拟贴右边松手，bounds=', JSON.stringify(win.getBounds()), 'state=', petState);
    }, 2000);
  }

  // 仅测试用：PET_TEST_REVEAL=1 时，在 PET_TEST_HIDE 的基础上再 4 秒后注入一次原地点点击（渲染层→ pet:pet-click）
  // 验证「点一下探头猫就现身」；需要与 PET_TEST_HIDE=1 同时开
  if (process.env.PET_TEST_REVEAL === '1') {
    setTimeout(() => {
      const win = petWindow && !petWindow.isDestroyed() ? petWindow : null;
      if (!win) return;
      win.webContents.sendInputEvent({ type: 'mouseDown', x: 100, y: 100, button: 'left', clickCount: 1 });
      win.webContents.sendInputEvent({ type: 'mouseUp', x: 100, y: 100, button: 'left', clickCount: 1 });
      setTimeout(() => console.log('[test-reveal] 注入点击后 bounds=', JSON.stringify(win.getBounds()), 'state=', petState), 300);
    }, 6000);
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
  if (focusMonitor) focusMonitor.stop();
  globalShortcut.unregisterAll();
  if (petGuard) petGuard.stop();
  if (scheduler) scheduler.stop();
  if (todoReminder) todoReminder.stop();
  if (weatherReminder) weatherReminder.stop();
  if (chat) chat.stop();
  if (bubble) bubble.stop();
  // 会话窗直接关卡（不走 ✕）：没看完的消息不标已读，服务端到点会重投
  closeFriendChat();
  closeFriendRequestWindow();
  // 历史图片窗里的待完成生成不因为关窗而取消（flow 自己跑完并落盘），退出时直接关窗
  closePetImageHistory();
  if (heartbeat) heartbeat.stop();
  if (updater) updater.stop();
  if (sysinfoWorker) sysinfoWorker.kill();
  newsWin.close();
  weatherWin.close();
});

// 非 macOS：所有窗口关闭即退出。macOS 保持常驻（后续接托盘控制）
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});
