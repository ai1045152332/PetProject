// PetViewModel.swift
// DesktopPetForMacApp — 小猫状态管理 + 动画调度
// 负责：动画状态机、鼠标响应、随机待机行为、互动反馈

import SwiftUI
import AppKit

/// 小猫动画状态
enum CatAnimationState: String, CaseIterable {
    case idle   = "idle"    // 待机
    case walk   = "walk"    // 走动
    case jump   = "jump"    // 跳跃/开心
    case sleep  = "sleep"   // 睡觉
    case pet    = "pet"     // 抚摸
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
    @Published private(set) var animationState: CatAnimationState = .idle
    
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
    
    /// 当前要显示的图片帧（直接暴露给视图，避免 SwiftUI Image(nsImage:) 刷新问题）
    @Published var currentFrameImage: NSImage? = nil
    
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
    
    /// 喝水提醒回调（供视图层展示弹窗）
    var onDrinkWaterReminder: (() -> Void)?
    
    /// 新闻查询回调（供视图层展示弹窗）
    var onShowHotNews: ((String) -> Void)?
    
    // MARK: - Initialization
    
    init() {
        loadSpriteSheets()
        // 初始化首帧图片
        if let sheet = spriteSheets[.idle] {
            currentFrameImage = sheet.frame(at: 0)
        }
        startFrameLoop()
        startBehaviorLoop()
        startDrinkWaterReminder()
    }
    
    // MARK: - Sprite Sheet Loading
    
    /// 加载所有动画精灵图
    /// 替换资源说明：将透明背景 PNG 放入 Resources/Sprites/，命名规则如下
    ///   idle_0.png ~ idle_N.png
    ///   walk_0.png ~ walk_N.png
    ///   jump_0.png ~ jump_N.png
    ///   sleep_0.png ~ sleep_N.png
    ///   eat_0.png ~ eat_N.png
    private func loadSpriteSheets() {
        for state in CatAnimationState.allCases {
            if let sheet = SpriteSheet(state: state) {
                spriteSheets[state] = sheet
            }
        }
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
        
        // 一次性动画（pet）播完自动切回 idle
        // jump 不自动回 idle，等用户点击
        if isPlayingOneShot && animationState != .jump && nextIndex == 0 && currentFrameIndex == sheet.frameCount - 1 {
            isPlayingOneShot = false
            transitionTo(.idle)
            return
        }
        
        currentFrameIndex = nextIndex
        currentFrameImage = sheet.frame(at: currentFrameIndex)
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
        
        // 每 30 分钟自动跳一下，跳完后不自动回 idle，等用户点击
        playOneShot(.jump)
        
        scheduleNextBehavior()
    }
    
    // MARK: - State Transitions
    
    func transitionTo(_ newState: CatAnimationState) {
        guard animationState != newState else { return }
        isFacingLocked = false
        animationState = newState
        currentFrameIndex = 0
        isPlayingOneShot = false
        if let sheet = spriteSheets[newState] {
            currentFrameImage = sheet.frame(at: 0)
        }
    }
    
    func playOneShot(_ state: CatAnimationState) {
        isPlayingOneShot = true
        animationState = state
        currentFrameIndex = 0
        if let sheet = spriteSheets[state] {
            currentFrameImage = sheet.frame(at: 0)
        }
    }
    
    // MARK: - Mouse Interaction
    
    func updateMousePosition(_ point: CGPoint) {
        mousePosition = point
        guard !isFacingLocked else { return }
        
        // 计算小猫窗口中心与鼠标的角度，决定朝向
        let catCenterX = windowPosition.x + 64 // 假设小猫宽度约 128pt
        if point.x < catCenterX - 20 {
            facing = .left
        } else if point.x > catCenterX + 20 {
            facing = .right
        }
    }
    
    /// 左键点击：开心跳跃
    func handleLeftClick() {
        guard !isPlayingOneShot else { return }
        playOneShot(.jump)
    }
    
    /// 右键点击：弹出菜单
    func handleRightClick(at location: CGPoint) {
        menuLocation = location
        showContextMenu = true
    }
    
    // MARK: - Menu Actions
    
    func feed() {
        showContextMenu = false
        // 如果 pet 没有有效帧（只有1帧占位图），fallback 到 jump 动画
        if let sheet = spriteSheets[.pet], sheet.frameCount > 1 {
            playOneShot(.pet)
        } else {
            playOneShot(.jump)
        }
    }
    
    func sleep() {
        showContextMenu = false
        transitionTo(.sleep)
    }
    
    func wakeUp() {
        transitionTo(.idle)
    }
    
    func quit() {
        NSApp.terminate(nil)
    }
    
    // MARK: - Drink Water Reminder
    
    /// 启动每半小时的喝水提醒
    func startDrinkWaterReminder() {
        // 取消所有已存在的定时器，避免重复触发
        drinkWaterTimer?.invalidate()
        drinkWaterTimer = nil
        firstWaterTimer?.invalidate()
        firstWaterTimer = nil

        let now = Date()
        let calendar = Calendar.current
        let currentMinute = calendar.component(.minute, from: now)

        // 计算到下一个"整点或半点"的延迟
        var delay: TimeInterval
        if currentMinute < 30 {
            // 下一个半点
            delay = TimeInterval((30 - currentMinute) * 60 - calendar.component(.second, from: now))
        } else {
            // 下一个整点
            delay = TimeInterval((60 - currentMinute) * 60 - calendar.component(.second, from: now))
        }

        // 首次等到下一个触发点，之后每 30 分钟重复
        firstWaterTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.triggerDrinkWaterReminder()
                self.drinkWaterTimer?.invalidate()
                self.drinkWaterTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.triggerDrinkWaterReminder()
                    }
                }
            }
        }
    }
    
    /// 触发喝水提醒
    func triggerDrinkWaterReminder() {
        // 弹窗未关闭时不弹下一次
        if isWaterAlertShowing { return }
        lastWaterReminderTime = Date()
        isFacingLocked = true
        facing = .right
        playOneShot(.jump)
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
}
