// PetViewModel.swift
// DesktopPetForMacApp — 小猫状态管理 + 动画调度
// 负责：动画状态机、鼠标响应、随机待机行为、互动反馈

import SwiftUI
import AppKit

/// 小猫动画状态
enum CatAnimationState: String, CaseIterable {
    case focus  = "focus"   // 专注
    case idel   = "idel"    // 休闲
    case warn   = "warn"    // 提醒
    case sleep  = "sleep"   // 睡觉
    case pet    = "pet"     // 抚摸

    /// 中文展示名
    var displayName: String {
        switch self {
        case .focus: return "专注"
        case .idel:  return "休闲"
        case .warn:  return "提醒"
        case .sleep: return "睡觉"
        case .pet:   return "抚摸"
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
    /// 已移除"看向鼠标"翻转功能，固定显示原图（朝右）
    var currentFrameImage: NSImage? {
        guard let sheet = spriteSheets[animationState] else { return nil }
        let index = currentFrameIndex
        return sheet.frame(at: index)
    }
    
    /// 帧率：12 FPS
    private let frameRate: TimeInterval = 1.0 / 12.0
    
    /// 动画定时器
    private var frameTimer: Timer?
    
    /// 行为决策定时器（眨眼、伸懒腰等）
    private var behaviorTimer: Timer?
    
    /// 鼠标位置
    private var mousePosition: CGPoint = .zero
    
    /// 当前是否在执行一次性动画（如 jump）
    private var isPlayingOneShot: Bool = false
    
    /// 系统勿扰/专注模式是否开启（决定一次性动画播完后回到哪个基准状态）
    /// true = 专注（勿扰中），false = 休闲
    var systemFocusActive: Bool = false

    /// 朝向是否被锁定（喝水提醒期间禁止鼠标翻转）
    private var isFacingLocked: Bool = false
    
    /// 喝水提醒定时器（每小时重复的那个）
    private var drinkWaterTimer: Timer?
    
    /// 首次等到整点的定时器
    private var firstWaterTimer: Timer?
    
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
    
    /// 新闻查询回调（供视图层展示弹窗）
    var onShowHotNews: ((String) -> Void)?
    
    /// 背单词回调（供视图层展示学习/测试弹窗）
    var onStartWordLearning: (() -> Void)?

    // MARK: - 小猫大小配置

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
    }
    
    deinit {
        frameTimer?.invalidate()
        behaviorTimer?.invalidate()
        drinkWaterTimer?.invalidate()
        firstWaterTimer?.invalidate()
    }
    
    // MARK: - Sprite Sheet Loading
    
    /// 加载所有动画精灵图
    /// 替换资源说明：将透明背景 PNG 放入 Resources/Sprites/，命名规则如下
    ///   focus_0.png ~ focus_N.png
    ///   idel_0.png ~ idel_N.png
    ///   warn_0.png ~ warn_N.png
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
        frameTimer = Timer.scheduledTimer(withTimeInterval: frameRate, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.advanceFrame()
            }
        }
    }
    
    private func advanceFrame() {
        guard let sheet = spriteSheets[animationState] else { return }
        
        let nextIndex = (currentFrameIndex + 1) % sheet.frameCount
        
        // 一次性动画（pet / warn 等）播完自动切回基准状态：
        // 系统勿扰开启时回专注，否则回休闲
        if isPlayingOneShot && nextIndex == 0 && currentFrameIndex == sheet.frameCount - 1 {
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
        behaviorTimer?.invalidate()
        behaviorTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.performRandomBehavior()
            }
        }
    }
    
    private func performRandomBehavior() {
        guard !isPlayingOneShot && animationState != .sleep else {
            scheduleNextBehavior()
            return
        }
        
        FileLogger.log("[DesktopPet] performRandomBehavior triggered, currentState=\(animationState.displayName)")
        // 每 30 分钟自动提醒一下，提醒完后不自动回 focus，等用户点击
        playOneShot(.warn)
        
        scheduleNextBehavior()
    }
    
    // MARK: - State Transitions
    
    func transitionTo(_ newState: CatAnimationState) {
        guard animationState != newState else { return }
        isFacingLocked = false
        animationState = newState
        currentFrameIndex = 0
        isPlayingOneShot = false
        // currentFrameImage 由计算属性根据当前 orientation 自动提供
        FileLogger.log("[DesktopPet] transitionTo(\((newState.displayName)), frameCount=\(spriteSheets[newState]?.frameCount ?? 0), hasImage=\(currentFrameImage != nil)")
        onStateChanged?(newState)
    }
    
    func playOneShot(_ state: CatAnimationState) {
        isPlayingOneShot = true
        animationState = state
        currentFrameIndex = 0
        // currentFrameImage 由计算属性根据当前 orientation 自动提供
        FileLogger.log("[DesktopPet] playOneShot(\(state.displayName), frameCount=\(spriteSheets[state]?.frameCount ?? 0), hasImage=\(currentFrameImage != nil)")
        onStateChanged?(state)
    }
    
    // MARK: - Mouse Interaction
    
    func updateMousePosition(_ point: CGPoint) {
        mousePosition = point
        guard !isFacingLocked else { return }
        
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
    
    /// 左键点击：提醒动画
    func handleLeftClick() {
        guard !isPlayingOneShot else { return }
        playOneShot(.warn)
    }
    
    /// 右键点击：弹出菜单
    func handleRightClick(at location: CGPoint) {
        menuLocation = location
        showContextMenu = true
    }
    
    // MARK: - Menu Actions
    
    func pet() {
        showContextMenu = false
        // 如果 pet 没有有效帧（只有1帧占位图），fallback 到 warn 动画
        if let sheet = spriteSheets[.pet], sheet.frameCount > 1 {
            playOneShot(.pet)
        } else {
            playOneShot(.warn)
        }
    }
    
    func sleep() {
        showContextMenu = false
        transitionTo(.sleep)
    }
    
    func wakeUp() {
        transitionTo(.idel)
    }
    
    func quit() {
        NSApp.terminate(nil)
    }
    
    // MARK: - Drink Water Reminder

    /// 启动喝水提醒（间隔由 reminderInterval 配置，默认 30 分钟）
    func startDrinkWaterReminder() {
        // 取消所有已存在的定时器，避免重复触发
        drinkWaterTimer?.invalidate()
        drinkWaterTimer = nil
        firstWaterTimer?.invalidate()
        firstWaterTimer = nil

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
        firstWaterTimer = Timer.scheduledTimer(withTimeInterval: effectiveDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.triggerDrinkWaterReminder()
                self.drinkWaterTimer?.invalidate()
                self.drinkWaterTimer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.triggerDrinkWaterReminder()
                    }
                }
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
        isFacingLocked = true
        facing = .right
        playOneShot(.warn)
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
    
    // MARK: - 背单词功能
    
    /// 开始背单词：进入专注状态，启动学习流程
    func startWordLearning() {
        showContextMenu = false
        transitionTo(.focus) // 进入专注状态
        onStartWordLearning?()
    }
}
