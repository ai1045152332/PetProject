// PetViewModel.swift
// DesktopPetForMacApp — 小猫状态管理 + 动画调度
// 负责：动画状态机、鼠标响应、随机待机行为、互动反馈

import SwiftUI
import AppKit

/// 小猫动画状态（提醒已合并进专注：提醒触发时播放专注动画 + 气泡文案）
enum CatAnimationState: String, CaseIterable {
    case focus  = "focus"   // 专注
    case idel   = "idel"    // 休闲
    case sleep  = "sleep"   // 睡觉
    case pet    = "pet"     // 抚摸
    case hide   = "hide"    // 躲藏（贴屏幕侧边，只探出脑袋、一点前胸和一只小爪）

    /// 中文展示名
    var displayName: String {
        switch self {
        case .focus: return "专注"
        case .idel:  return "休闲"
        case .sleep: return "睡觉"
        case .pet:   return "抚摸"
        case .hide:  return "躲藏"
        }
    }
}

/// 小猫面向方向
enum CatFacing: String {
    case left  = "left"
    case right = "right"
}

@MainActor
final class PetViewModel: ObservableObject {
    // MARK: - Published State
    
    /// 当前动画状态
    @Published private(set) var animationState: CatAnimationState = .idel
    
    /// 面向方向
    @Published private(set) var facing: CatFacing = .right
    
    /// 当前帧索引（供 SpriteSheet 驱动）
    @Published private(set) var currentFrameIndex: Int = 0
    
    /// 窗口位置（用于跟随逻辑）
    @Published var windowPosition: CGPoint = CGPoint(
        x: NSScreen.main?.frame.midX ?? 400,
        y: 120 // 屏幕底部上方
    )
    
    /// 是否显示右键菜单
    @Published var showContextMenu: Bool = false
    
    /// 菜单弹出的位置（相对窗口）
    @Published var menuLocation: CGPoint = .zero
    
    // MARK: - Internal Properties
    
    /// 精灵图加载器，按状态持有
    var spriteSheets: [CatAnimationState: SpriteSheet] = [:]
    
    /// 镜像帧缓存（朝左时使用），加载精灵图后一次性生成
    private var flippedFrames: [CatAnimationState: [NSImage]] = [:]
    
    /// 当前要显示的图片帧
    /// 注意：不使用 @Published，由视图的定时器每帧读取
    /// 已移除“看向鼠标”翻转功能，固定显示原图（朝右）；
    /// 仅贴右边缘躲藏时改用镜像帧，让露在屏内的部分仍是脑袋
    var currentFrameImage: NSImage? {
        guard let sheet = spriteSheets[animationState] else { return nil }
        let index = currentFrameIndex
        if animationState == .hide, facing == .right,
           let mirrored = flippedFrames[animationState], mirrored.indices.contains(index) {
            return mirrored[index]
        }
        return sheet.frame(at: index)
    }
    
    /// 帧率：12 FPS
    private let frameRate: TimeInterval = 1.0 / 12.0
    
    /// 统一定时器调度器（frame / behavior / oneShot / idleSleep / 喝水 / 主动搭话 全部走这里）
    private let timers = PetTimerScheduler()

    /// 定时器名字常量，集中管理避免拼写漂移
    private enum TimerName {
        static let frame = "frame"
        static let behavior = "behavior"
        static let oneShot = "oneShot"
        static let idleSleep = "idleSleep"
        static let waterFirst = "waterFirst"
        static let waterRepeat = "waterRepeat"
        static let chatFirst = "chatFirst"
        static let chatRepeat = "chatRepeat"
        static let newsRefresh = "newsRefresh"
        static let todoCheck = "todoCheck"
    }

    /// 鼠标位置
    private var mousePosition: CGPoint = .zero
    
    /// 当前是否在执行一次性动画（如 jump）
    private var isPlayingOneShot: Bool = false

    /// 空闲进入睡觉的时长（秒）：连续无人互动超过该时长即进入睡觉状态
    static let idleSleepSeconds: TimeInterval = 1800

    /// 系统勿扰/专注模式是否开启（决定一次性动画播完后回到哪个基准状态）
    /// true = 专注（勿扰中），false = 休闲
    var systemFocusActive: Bool = false

    /// 朝向是否被锁定（喝水提醒期间禁止鼠标翻转）
    private var isFacingLocked: Bool = false

    /// 上次喝水提醒时间（防重复弹窗）
    private var lastWaterReminderTime: Date?
    /// 喝水弹窗是否正在显示（未关闭则不弹下一次）
    var isWaterAlertShowing: Bool = false

    // MARK: - 喝水提醒间隔配置

    static let reminderIntervalKey = "settings.drinkWaterInterval"
    static let defaultReminderInterval: Int = 30

    /// 喝水提醒间隔（分钟），持久化到 UserDefaults
    var reminderInterval: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Self.reminderIntervalKey)
            return v > 0 ? v : Self.defaultReminderInterval
        }
        set {
            let clamped = max(1, min(newValue, 120))
            UserDefaults.standard.set(clamped, forKey: Self.reminderIntervalKey)
        }
    }
    
    /// 喝水提醒回调（供视图层展示弹窗）
    var onDrinkWaterReminder: (() -> Void)?
    
    /// 动画状态变化回调（供设置面板实时同步选中卡片）
    var onStateChanged: ((CatAnimationState) -> Void)?

    var spriteRevision = 0
    
    /// 新闻查询回调（供视图层展示弹窗）
    var onShowHotNews: ((String) -> Void)?
    
    /// 背单词回调（供视图层展示学习/测试弹窗）
    var onStartWordLearning: (() -> Void)?

    // MARK: - 宠物大小配置

    static let catScaleKey = "settings.catScale"
    static let defaultCatScale: Double = 1.0

    /// 小猫显示缩放（0.5 ~ 2.0），持久化到 UserDefaults
    var catScale: Double {
        get {
            let v = UserDefaults.standard.double(forKey: Self.catScaleKey)
            return v >= 0.5 && v <= 2.0 ? v : Self.defaultCatScale
        }
        set {
            let clamped = max(0.5, min(2.0, newValue))
            UserDefaults.standard.set(clamped, forKey: Self.catScaleKey)
        }
    }

    /// 窗口大小调整回调（设置面板滑块修改后触发）
    var onResizeWindow: ((Double) -> Void)?
    
    // MARK: - Initialization
    
    init() {
        loadSpriteSheets()
        // 首帧图片由 currentFrameImage 计算属性基于 currentFrameIndex=0 自动提供
        currentFrameIndex = 0
        startFrameLoop()
        startBehaviorLoop()
        startDrinkWaterReminder()
        startTodoReminderLoop()
        resetIdleSleepTimer()
        startProactiveChat()
        cloudRestoreObserver = NotificationCenter.default.addObserver(forName: AccessControl.accessLevelChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restoreCloudPet() }
        }
        restoreCloudPet()
    }
    
    deinit {
        cloudRestoreTask?.cancel()
        if let cloudRestoreObserver { NotificationCenter.default.removeObserver(cloudRestoreObserver) }
        timers.invalidateAll()
    }
    
    // MARK: - Sprite Sheet Loading
    
    /// 加载所有动画精灵图
    /// 替换资源说明：将透明背景 PNG 放入 Resources/Sprites/，命名规则如下
    ///   focus_0.png ~ focus_N.png
    ///   idel_0.png ~ idel_N.png
    ///   sleep_0.png ~ sleep_N.png
    ///   pet_0.png ~ pet_N.png
    private func loadSpriteSheets() {
        for state in CatAnimationState.allCases {
            if let sheet = SpriteSheet(state: state) {
                spriteSheets[state] = sheet
                // 预生成镜像帧，供朝左时使用（避免运行期翻转渲染）
                var mirrored: [NSImage] = []
                for i in 0..<sheet.frameCount {
                    mirrored.append(Self.mirrorImage(sheet.frame(at: i)))
                }
                flippedFrames[state] = mirrored
                FileLogger.log("[DesktopPet] loadSpriteSheets: \(state.displayName) loaded, frameCount=\(sheet.frameCount)")
            } else {
                FileLogger.log("[DesktopPet] loadSpriteSheets: \(state.displayName) FAILED to load sprite sheet")
            }
        }
    }

    /// 供设置面板本地直传/清除图片后即时重建素材并刷新宠物窗口
    @MainActor
    func reloadSpriteSheets() {
        loadSpriteSheets()
        spriteRevision += 1
        currentFrameIndex = 0
    }

    @MainActor
    func applyPetLibrary(_ library: PetImageLibrary) async throws {
        // 过滤历史遗留的未知状态键（如已移除的 warn），避免白下载与安装报错
        let selections = library.selections.filter { CatAnimationState(rawValue: $0.key) != nil }
        guard !selections.isEmpty else { return }
        var images: [String: Data] = [:]
        for id in Set(selections.values) where !id.isEmpty {
            images[id] = try await PetImageService.image(id)
        }
        try Task.checkCancellation()
        try CustomSpriteStore.installCloudImages(selections: selections, images: images)
        loadSpriteSheets()
        spriteRevision += 1
        currentFrameIndex = 0
    }

    private var cloudRestoreObserver: NSObjectProtocol?
    private var cloudRestoreTask: Task<Void, Never>?

    func cancelCloudRestore() { cloudRestoreTask?.cancel() }

    func restoreCloudPet() {
        cloudRestoreTask?.cancel()
        cloudRestoreTask = Task { @MainActor [weak self] in
            guard AccessControl.serverActivationCode != nil else { return }
            // 图片历史以本机为准：本机已有选中记录就不再拉服务端覆盖，
            // 只在换机/重装后本机一片空白时用服务端记录做一次恢复。
            guard !CustomSpriteStore.hasAnySelection() else { return }
            do {
                let library = try await PetImageService.library()
                try Task.checkCancellation()
                try await self?.applyPetLibrary(library)
                if let pending = library.images.first(where: { $0.isGenerating }) {
                    let finished = try await PetImageService.waitForGeneration(pending.id, initial: library)
                    try await self?.applyPetLibrary(finished)
                }
            } catch {
                FileLogger.log("[PetImages] 恢复失败，保留离线缓存: \(error.localizedDescription)")
            }
        }
    }

    /// 生成水平镜像图片（一次性预渲染，避免运行期翻转绘制）
    /// 使用 CoreGraphics 字节级镜像，最稳定可靠
    private static func mirrorImage(_ image: NSImage) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let w = cg.width
        let h = cg.height
        
        // 创建 RGBA 上下文
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        
        // 水平镜像：沿水平轴翻转坐标系后绘制
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        
        guard let mirroredCG = ctx.makeImage() else { return image }
        return NSImage(cgImage: mirroredCG, size: size)
    }
    
    // MARK: - Frame Animation Loop
    
    private func startFrameLoop() {
        timers.schedule(name: TimerName.frame, interval: frameRate, repeats: true) { [weak self] in
            self?.advanceFrame()
        }
    }
    
    private var frameElapsed: TimeInterval = 0
    private var lastFrameTimestamp: TimeInterval = 0

    private func advanceFrame() {
        guard let sheet = spriteSheets[animationState] else { return }
        
        let now = Date.timeIntervalSinceReferenceDate
        frameElapsed += lastFrameTimestamp == 0 ? frameRate : min(0.25, now - lastFrameTimestamp)
        lastFrameTimestamp = now
        let duration = sheet.frameDurations.indices.contains(currentFrameIndex) ? sheet.frameDurations[currentFrameIndex] : frameRate
        guard frameElapsed >= duration else { return }
        frameElapsed -= duration
        let nextIndex = (currentFrameIndex + 1) % sheet.frameCount
        
        // 一次性动画（pet / 提醒用的专注等）多帧素材播完自动切回基准状态：
        // 系统勿扰开启时回专注，否则回休闲（单帧素材由 oneShotTimer 负责回退，这里不处理）
        if isPlayingOneShot && sheet.frameCount > 1 && nextIndex == 0 && currentFrameIndex == sheet.frameCount - 1 {
            isPlayingOneShot = false
            transitionTo(systemFocusActive ? .focus : .idel)
            return
        }
        
        currentFrameIndex = nextIndex
        // currentFrameImage 由计算属性根据 currentFrameIndex + facing 自动提供
    }
    
    // MARK: - Behavior Loop (Random Idle Actions)
    
    private func startBehaviorLoop() {
        // 每 3~8 秒触发一次随机行为
        scheduleNextBehavior()
    }
    
    private func scheduleNextBehavior() {
        let delay = 1800.0 // 每 30 分钟触发一次
        timers.schedule(name: TimerName.behavior, interval: delay, repeats: false) { [weak self] in
            self?.performRandomBehavior()
        }
    }
    
    private func performRandomBehavior() {
        guard !isPlayingOneShot && animationState != .sleep && animationState != .hide else {
            scheduleNextBehavior()
            return
        }
        
        FileLogger.log("[DesktopPet] performRandomBehavior triggered, currentState=\(animationState.displayName)")
        // 每 30 分钟自动提醒一下：播放一段专注动画唤起注意（提醒状态已合并进专注）
        playOneShot(.focus)
        
        scheduleNextBehavior()
    }
    
    // MARK: - State Transitions
    
    func transitionTo(_ newState: CatAnimationState) {
        guard animationState != newState else { return }
        // 离开躲藏态时自动清除贴边标记（吸附进入 .hide 前已先置 true，不受影响）
        if newState != .hide { isHiding = false }
        isFacingLocked = false
        animationState = newState
        currentFrameIndex = 0
        isPlayingOneShot = false
        timers.cancel(TimerName.oneShot)
        // currentFrameImage 由计算属性根据当前 orientation 自动提供
        FileLogger.log("[DesktopPet] transitionTo(\((newState.displayName)), frameCount=\(spriteSheets[newState]?.frameCount ?? 0), hasImage=\(currentFrameImage != nil)")
        onStateChanged?(newState)
    }
    
    /// 播放一次性动画
    /// - 多帧素材：靠帧循环播完最后一帧自动回退（见 advanceFrame）
    /// - 单帧素材：frameCount==1 无法靠帧推进回退，用 hold 定时保持展示，避免"点了没反应"
    func playOneShot(_ state: CatAnimationState, hold: TimeInterval = 1.5) {
        isPlayingOneShot = true
        animationState = state
        currentFrameIndex = 0
        timers.cancel(TimerName.oneShot)
        // currentFrameImage 由计算属性根据当前 orientation 自动提供
        FileLogger.log("[DesktopPet] playOneShot(\(state.displayName), frameCount=\(spriteSheets[state]?.frameCount ?? 0), hasImage=\(currentFrameImage != nil))")
        onStateChanged?(state)

        // 单帧素材没有可推进的帧序列，用定时器等价"播完"后回到基准状态
        if spriteSheets[state]?.frameCount ?? 0 <= 1 {
            timers.schedule(name: TimerName.oneShot, interval: hold, repeats: false) { [weak self] in
                guard let self, self.isPlayingOneShot, self.animationState == state else { return }
                self.isPlayingOneShot = false
                self.transitionTo(self.systemFocusActive ? .focus : .idel)
            }
        }
    }
    
    /// 窗口拖动 / 缩放回调（由 FloatingWindow 注册，贴边躲藏与设置面板滑杆拖动时触发）
    var onMoveWindow: ((CGPoint) -> Void)?

    // MARK: - 贴边躲藏

    /// 可吸附的屏幕侧边（躲藏素材是从一侧探头，只支持左右）
    enum HideEdge {
        case left, right
    }

    /// 拖近屏幕侧边时自动贴边进入躲藏：素材只画了头、一点前胸和一只前爪，且裁切边就在素材左侧，
    /// 窗口直接对齐屏幕可见区域边缘，让“身体被屏幕挡住”的裁切边正好落在屏幕边上。
    /// 由视图层在拖拽结束时调用；requiresNearEdge=false 时（右键「躲起来」）直接吸附到最近一侧。
    @MainActor
    func snapToEdgeForHiding(windowOrigin: CGPoint, size: NSSize, requiresNearEdge: Bool = true) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(NSRect(origin: windowOrigin, size: size)) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let trigger: CGFloat = 60 // 距边缘小于该距离即触发吸附
        let dLeft = windowOrigin.x - vf.minX
        let dRight = vf.maxX - (windowOrigin.x + size.width)
        let edges: [(edge: HideEdge, dist: CGFloat)] = [(.left, dLeft), (.right, dRight)]
        guard let nearest = edges.min(by: { $0.dist < $1.dist }), !requiresNearEdge || nearest.dist < trigger else { return }
        let clampedY = min(max(windowOrigin.y, vf.minY), vf.maxY - size.height)
        let origin: CGPoint
        switch nearest.edge {
        case .left:
            facing = .left
            origin = CGPoint(x: vf.minX, y: clampedY)
        case .right:
            facing = .right
            origin = CGPoint(x: vf.maxX - size.width, y: clampedY)
        }
        isHiding = true
        onMoveWindow?(origin)
        windowPosition = origin
        transitionTo(.hide)
        FileLogger.log("[DesktopPet] 贴边躲藏: edge=\(nearest.edge), origin=\(origin)")
    }

    /// 是否正在贴边躲藏（视图层拖动时用于判定“拖回即现身”，拖拽结束时据此吸附/解除）
    private(set) var isHiding: Bool = false

    /// 宠物窗口当前尺寸（视图层在拖动 / 缩放时同步，贴边吸附按真实窗口宽度计算露出条）
    var windowSize: NSSize = NSSize(width: 160, height: 160)

    /// 从躲藏中现身：先把窗口完整收回屏内（可传入目标状态，默认回基准态）
    /// 拖出或点击露在外面的一小条身子时调用，避免醒来后仍然半个身子在屏幕外
    @MainActor
    func revealFromEdge(target: CatAnimationState? = nil) {
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(NSRect(origin: windowPosition, size: windowSize)) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            let x = min(max(windowPosition.x, vf.minX + 4), vf.maxX - windowSize.width - 4)
            let y = min(max(windowPosition.y, vf.minY + 4), vf.maxY - windowSize.height - 4)
            let origin = CGPoint(x: x, y: y)
            if origin != windowPosition {
                onMoveWindow?(origin)
                windowPosition = origin
            }
        }
        isHiding = false
        let next = target ?? (systemFocusActive ? .focus : .idel)
        if animationState != next { transitionTo(next) }
    }

    /// 进入躲藏：由右键菜单触发，直接吸附到最近的屏幕侧边
    func hideBehindEdge() {
        showContextMenu = false
        snapToEdgeForHiding(windowOrigin: windowPosition, size: windowSize, requiresNearEdge: false)
    }

    // MARK: - Mouse Interaction

    // MARK: - 空闲自动睡觉

    /// 记录一次互动：重置空闲计时；若正在睡觉则唤醒回基准状态（勿扰中→专注，否则→休闲）
    /// 躲藏态不在这里解除（弹菜单等交互不应把宠物拉回屏内），由拖回 / 点击单独现身
    /// 由视图层在点击 / 拖动 / 右键菜单等交互时调用
    func markInteraction() {
        if animationState == .sleep {
            transitionTo(systemFocusActive ? .focus : .idel)
        }
        resetIdleSleepTimer()
    }

    /// 重新开始空闲计时，超时后进入睡觉
    private func resetIdleSleepTimer() {
        timers.schedule(name: TimerName.idleSleep, interval: Self.idleSleepSeconds, repeats: false) { [weak self] in
            guard let self else { return }
            // 一次性动画（提醒 / 喝水 / 抚摸）播放中不打断，顺延到其结束后再判定
            guard !self.isPlayingOneShot else { self.resetIdleSleepTimer(); return }
            // 躲藏时半截身子贴着屏幕边，睡着会显得突兀，保持躲藏姿态直到被找出来
            guard self.animationState != .hide else { return }
            self.transitionTo(.sleep)
        }
    }

    func updateMousePosition(_ point: CGPoint) {
        mousePosition = point
        // 躲藏时朝向固定为贴边方向（决定镜像帧），不跟随鼠标翻转
        guard !isFacingLocked, animationState != .hide else { return }
        
        // 计算小猫窗口中心与鼠标的角度，决定朝向
        let catCenterX = windowPosition.x + 62 // 假设小猫宽度约 124pt
        let newFacing: CatFacing
        if point.x < catCenterX - 20 {
            newFacing = .left
        } else if point.x > catCenterX + 20 {
            newFacing = .right
        } else {
            newFacing = facing // 中心区域保持当前朝向
        }
        if newFacing != facing {
            facing = newFacing
            FileLogger.log("[DesktopPet] facing -> \(facing.rawValue), mouseX=\(point.x), catCenterX=\(catCenterX)")
        }
    }
    
    /// 左键点击：专注动画唤起注意（原提醒动画已合并进专注）
    func handleLeftClick() {
        guard !isPlayingOneShot else { return }
        playOneShot(.focus)
    }
    
    /// 右键点击：弹出菜单
    func handleRightClick(at location: CGPoint) {
        menuLocation = location
        showContextMenu = true
    }
    
    // MARK: - Menu Actions
    
    func pet() {
        showContextMenu = false
        // 抚摸：有 pet 素材（单帧也算有效）就播放抚摸动画，缺失才回退到专注动画
        if spriteSheets[.pet] != nil {
            playOneShot(.pet)
        } else {
            playOneShot(.focus)
        }
    }
    
    func sleep() {
        showContextMenu = false
        transitionTo(.sleep)
    }
    
    func wakeUp() {
        isHiding = false
        transitionTo(.idel)
    }
    
    func quit() {
        NSApp.terminate(nil)
    }
    
    // MARK: - Drink Water Reminder

    /// 启动喝水提醒（间隔由 reminderInterval 配置，默认 30 分钟）
    func startDrinkWaterReminder() {
        // 取消所有已存在的喝水定时器，避免重复触发
        timers.cancel(TimerName.waterFirst)
        timers.cancel(TimerName.waterRepeat)

        let intervalMinutes = reminderInterval
        let intervalSeconds = TimeInterval(intervalMinutes * 60)
        let now = Date()
        let calendar = Calendar.current
        let currentMinute = calendar.component(.minute, from: now)

        // 计算到下一个触发点的延迟（对齐到整除间隔的分钟数）
        let remainder = currentMinute % intervalMinutes
        let nextTriggerMinute: Int
        if remainder == 0 && calendar.component(.second, from: now) == 0 {
            nextTriggerMinute = currentMinute + intervalMinutes
        } else if remainder == 0 {
            nextTriggerMinute = currentMinute
        } else {
            nextTriggerMinute = currentMinute + (intervalMinutes - remainder)
        }
        let delay = TimeInterval((nextTriggerMinute - currentMinute) * 60 - calendar.component(.second, from: now))
        let effectiveDelay = delay > 0 ? delay : intervalSeconds

        // 首次等到下一个触发点，之后按配置间隔重复
        timers.schedule(name: TimerName.waterFirst, interval: effectiveDelay, repeats: false) { [weak self] in
            guard let self else { return }
            self.triggerDrinkWaterReminder()
            self.timers.schedule(name: TimerName.waterRepeat, interval: intervalSeconds, repeats: true) { [weak self] in
                self?.triggerDrinkWaterReminder()
            }
        }
    }

    /// 重启喝水提醒定时器（设置面板修改间隔后调用）
    func restartDrinkWaterReminder() {
        FileLogger.log("[DesktopPet] restartDrinkWaterReminder: interval=\(reminderInterval)min")
        startDrinkWaterReminder()
    }
    
    /// 触发喝水提醒
    func triggerDrinkWaterReminder() {
        // 弹窗未关闭时不弹下一次
        if isWaterAlertShowing { return }
        lastWaterReminderTime = Date()
        // 躲藏中只弹提醒窗，不把半截身子的宠物切回完整专注动画
        if animationState != .hide {
            isFacingLocked = true
            facing = .right
            // 提醒表现：播放专注动画 + 喝水弹窗气泡（原 warn 状态已合并进专注）
            playOneShot(.focus)
        }
        onDrinkWaterReminder?()
    }
    
    /// 测试喝水提醒（立即触发一次）
    func testDrinkWater() {
        showContextMenu = false
        triggerDrinkWaterReminder()
    }
    
    /// 查询并展示热点新闻
    func showHotNews() {
        showContextMenu = false
        onShowHotNews?("")
    }

    // MARK: - Todo 到期提醒（设定时间→主动触达）

    /// 到期检查周期（秒）：每隔该时长扫描一次是否有到点未提醒的待办
    static let todoCheckSeconds: TimeInterval = 30
    static let todoReminderRepeatMinutesKey = "settings.todoReminder.repeatMinutes"
    static let defaultTodoReminderRepeatMinutes: Int = 5
    /// 同一条到期后重复提醒的间隔（分钟），持久化到 UserDefaults
    var todoReminderRepeatMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Self.todoReminderRepeatMinutesKey)
            return v > 0 ? v : Self.defaultTodoReminderRepeatMinutes
        }
        set {
            let clamped = max(1, min(newValue, 240))
            UserDefaults.standard.set(clamped, forKey: Self.todoReminderRepeatMinutesKey)
        }
    }

    /// 启动到期提醒扫描（周期定时器，每次扫描到点的待办并触达）
    private func startTodoReminderLoop() {
        timers.schedule(name: TimerName.todoCheck, interval: Self.todoCheckSeconds, repeats: true) { [weak self] in
            self?.checkTodoReminders()
        }
    }

    /// 扫描到期待办：命中则播专注动画 + 回调触达，并记录本次触达时间以按间隔重复提醒
    private func checkTodoReminders() {
        // 复用“主动触达”总开关；勿扰/睡觉/躲藏时不打扰
        guard proactiveChatEnabled else { return }
        guard !systemFocusActive, animationState != .sleep, animationState != .hide, !isPlayingOneShot else { return }

        let now = Date()
        let repeatInterval = TimeInterval(todoReminderRepeatMinutes * 60)
        let todos = TodoManager.shared.load()
        // 只处理已到期且（从未提醒过 或 距上次提醒已超过重复间隔）的第一条
        guard let hit = todos.first(where: { item in
            guard let due = item.dueDate, due <= now else { return false }
            if let last = item.lastNotifiedAt { return now.timeIntervalSince(last) >= repeatInterval }
            return true
        }) else { return }

        TodoManager.shared.markNotified(id: hit.id, at: now)
        // 提醒表现：播放专注动画（躲藏中不切回完整姿态，仅靠气泡触达）
        if animationState != .hide {
            isFacingLocked = true
            facing = .right
            playOneShot(.focus)
        }
        FileLogger.log("[DesktopPet] Todo 到期提醒: 「\(hit.text)」")
        onTodoReminder?(hit)
    }
    
    // MARK: - 背单词功能
    
    /// 开始背单词：进入专注状态，启动学习流程
    func startWordLearning() {
        showContextMenu = false
        transitionTo(.focus) // 进入专注状态
        onStartWordLearning?()
    }

    // MARK: - 主动搭话（结合新闻 / Todo 的陪伴式提示）

    /// 主动搭话回调（供视图层用气泡展示台词）
    var onPetSay: ((String) -> Void)?

    /// Todo 到期提醒回调（供视图层用气泡强调触达；专注动画由 ViewModel 侧播放）
    var onTodoReminder: ((TodoItem) -> Void)?

    static let proactiveChatKey = "settings.proactiveChat.enabled"
    /// 是否开启主动搭话（默认开启），持久化到 UserDefaults
    var proactiveChatEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.proactiveChatKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.proactiveChatKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.proactiveChatKey) }
    }

    /// 启动后首次搭话延迟（秒），给热搜缓存拉取留出时间
    static let chatFirstDelaySeconds: TimeInterval = 20

    static let chatIntervalKey = "settings.proactiveChat.interval"
    static let defaultChatInterval: Int = 30
    /// 周期搭话间隔（分钟），持久化到 UserDefaults
    var chatIntervalMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Self.chatIntervalKey)
            return v >= 1 ? v : Self.defaultChatInterval
        }
        set {
            let clamped = max(1, min(newValue, 720))
            UserDefaults.standard.set(clamped, forKey: Self.chatIntervalKey)
        }
    }
    /// 热搜缓存刷新间隔（秒）
    static let newsRefreshSeconds: TimeInterval = 1800

    /// 缓存的热搜标题列表（后台刷新，搭话时随机挑一条，避免总是 Top1）
    private var cachedNewsHeadlines: [String] = []
    /// 上次搭话播过的热搜（连续两次不弹同一条）
    private var lastSpokenHeadline: String?
    /// 搭话轮换计数（新闻 / Todo 交替，避免总是同一主题）
    private var chatTick: Int = 0

    /// 启动主动搭话：先后台拉一次热搜做缓存，再安排首句与周期搭话
    private func startProactiveChat() {
        refreshNewsCache()
        // 周期刷新热搜缓存
        timers.schedule(name: TimerName.newsRefresh, interval: Self.newsRefreshSeconds, repeats: true) { [weak self] in
            self?.refreshNewsCache()
        }
        // 启动后一句：时段问候 +（若有）今日 Todo 数量；之后进入周期搭话
        timers.schedule(name: TimerName.chatFirst, interval: Self.chatFirstDelaySeconds, repeats: false) { [weak self] in
            guard let self else { return }
            self.sayGreeting()
            self.timers.schedule(name: TimerName.chatRepeat, interval: TimeInterval(self.chatIntervalMinutes * 60), repeats: true) { [weak self] in
                self?.performProactiveChat()
            }
        }
    }

    /// 修改间隔后重建周期搭话定时器（按新节奏立即生效，不重新跑启动首句）
    func restartProactiveChat() {
        timers.cancel(TimerName.chatRepeat)
        timers.schedule(name: TimerName.chatRepeat, interval: TimeInterval(chatIntervalMinutes * 60), repeats: true) { [weak self] in
            self?.performProactiveChat()
        }
    }

    /// 后台刷新热搜缓存（NewsFetcher 是阻塞网络请求，必须离开主线程）
    private func refreshNewsCache() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let titles = NewsFetcher.fetchHotNews().prefix(10).map { $0.title }
            FileLogger.log("[DesktopPet] 热搜缓存刷新: \(titles.count) 条\(titles.isEmpty ? "" : "，首条「\(titles[0])」")")
            DispatchQueue.main.async {
                self?.cachedNewsHeadlines = titles
            }
        }
    }

    /// 从缓存热搜里随机挑一条（非空，且避开上次播过的一条）
    private func randomNewsHeadline() -> String? {
        let pool = cachedNewsHeadlines.filter { !$0.isEmpty }
        guard !pool.isEmpty else { return nil }
        // 连续两次不弹同一条（与刷题抽题避重同一策略）；只剩一条候选时忽略该规则
        var candidates = pool
        if let last = lastSpokenHeadline, pool.count > 1 {
            candidates = pool.filter { $0 != last }
        }
        let picked = candidates.randomElement()
        lastSpokenHeadline = picked
        return picked
    }

    /// 启动首句：时段问候 +（若有）今日 Todo 数量
    private func sayGreeting() {
        guard proactiveChatEnabled, !systemFocusActive, animationState != .sleep, animationState != .hide else { return }
        let todoCount = TodoManager.shared.load().count
        let greet = Self.timeGreeting()
        if todoCount > 0 {
            onPetSay?("\(greet)｜今天你有 \(todoCount) 个 Todo 📝")
        } else {
            onPetSay?("\(greet)｜今天没有待办，轻松一下～")
        }
    }

    /// 周期主动搭话：在新闻 / Todo 之间轮换，勿扰、睡觉或躲藏时不打扰
    private func performProactiveChat() {
        guard proactiveChatEnabled else { return }
        // 陪伴式搭话只在“宠物醒着且未播动画”时进行，不打扰专注/勿扰，也不把睡觉或躲藏的自己喊出来
        guard !systemFocusActive, animationState != .sleep, animationState != .hide, !isPlayingOneShot else { return }

        chatTick += 1
        let todoCount = TodoManager.shared.load().count

        // 偶数优先聊热搜，奇数优先聊 Todo；缺失数据时相互兜底（热搜随机挑一条）
        if chatTick % 2 == 0, let headline = randomNewsHeadline() {
            FileLogger.log("[DesktopPet] 搭话热搜: 「\(headline)」池内\(cachedNewsHeadlines.count)条")
            onPetSay?("热搜在聊「\(Self.truncate(headline, 20))」🔥 右键看今日热点～")
            return
        }
        if todoCount > 0 {
            onPetSay?("今天你还有 \(todoCount) 个 Todo 没完成 📝 加油～")
            return
        }
        if let headline = randomNewsHeadline() {
            onPetSay?("热搜在聊「\(Self.truncate(headline, 20))」🔥")
            return
        }
        onPetSay?(Self.encouragement())
    }

    /// 按时段给出问候语
    private static func timeGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11:  return "早上好 ☀️"
        case 11..<13: return "中午好 🍚"
        case 13..<18: return "下午好 ☕"
        case 18..<23: return "晚上好 🌙"
        default:      return "夜深了 🌌"
        }
    }

    /// 兜底鼓励语（随机）
    private static func encouragement() -> String {
        let lines = ["休息一下，看看远处 🌿", "喝口水吧 💧", "你专注的样子很好看 ✨", "别太累，摸我一下放松下 🐾"]
        return lines.randomElement() ?? "喵～"
    }

    /// 截断过长标题，避免气泡过宽
    private static func truncate(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
