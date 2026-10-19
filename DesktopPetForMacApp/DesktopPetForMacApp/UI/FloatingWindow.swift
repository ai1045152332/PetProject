// FloatingWindow.swift — 纯 AppKit + CALayer 逐帧渲染，无闪烁
import SwiftUI
import AppKit

// MARK: - 无边框浮动窗口（支持成为 key/main window）
class FloatingPanel: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingWindow {
    private var window: NSWindow?
    private let viewModel: PetViewModel
    private let baseWindowSize = NSSize(width: 160, height: 160)
    private var catView: CatView?
    private var updateTimer: Timer?
    
    init(viewModel: PetViewModel) {
        self.viewModel = viewModel
    }
    
    func show() {
        let scale = viewModel.catScale
        let windowSize = NSSize(width: baseWindowSize.width * scale, height: baseWindowSize.height * scale)
        let win = FloatingPanel(
            contentRect: NSRect(origin: initialPosition(), size: windowSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        win.level = .popUpMenu
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.ignoresMouseEvents = false
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        
        let cv = CatView(frame: NSRect(origin: .zero, size: windowSize))
        // 纯 AppKit draw(_:) 渲染，不手动配置 layer（避免 layer 渲染 bug）
        cv.setupLayerHosting()
        cv.viewModel = viewModel
        cv.windowRef = win
        cv.autoresizingMask = [.width, .height]
        
        win.contentView = cv
        self.catView = cv
        self.window = win
        
        // 设置喝水提醒回调
        viewModel.onDrinkWaterReminder = { [weak cv] in
            cv?.showDrinkWaterAlert()
        }
        
        // 设置新闻查询回调
        viewModel.onShowHotNews = { [weak cv] _ in
            cv?.fetchAndShowHotNews()
        }
        
        // 设置背单词回调
        viewModel.onStartWordLearning = { [weak cv] in
            cv?.startWordLearning()
        }
        
        // 设置初始帧
        cv.updateLayerImage()
        
        // 定时刷新动画帧（使用 displaylink 级别的 timer）
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/12.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.catView?.updateLayerImage()
            }
        }
        
        // 定位由 WeatherService 内部缓存，无需预加载
        
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }
    
    func hide() { window?.orderOut(nil) }
    var isVisible: Bool { window?.isVisible ?? false }
    func keepInFront() { window?.orderFrontRegardless() }
    /// 恢复窗口层级（设置面板关闭后调用）
    func restoreLevel() {
        window?.level = .popUpMenu
        window?.orderFront(nil)
    }

    /// 根据缩放比例调整窗口大小（保持底部中心位置不变）
    func resizeWindow(scale: Double) {
        guard let win = window else { return }
        let newSize = NSSize(
            width: baseWindowSize.width * scale,
            height: baseWindowSize.height * scale
        )
        let oldFrame = win.frame
        let newOrigin = NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.minY
        )
        win.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }
    func close() {
        updateTimer?.invalidate()
        window?.close()
        window = nil
    }
    
    private func initialPosition() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 200, y: 200) }
        let frame = screen.visibleFrame
        return NSPoint(x: frame.midX - baseWindowSize.width / 2, y: frame.minY + 40)
    }
}

// MARK: - 右键菜单项展示配置（设置面板 > 菜单设置 可勾选开关）

enum ContextMenuPrefs {
    /// 右键菜单功能项定义：key 为持久化标识（标题文案统一在此维护，菜单与设置面板共用）
    static let items: [(key: String, title: String)] = [
        ("pet", "抚摸 🐾"),
        ("feed", "喂猫条 🍡"),
        ("word", "背单词 📚"),
        ("problem", "苦练基本功 🧩"),
        ("news", "今日热点新闻 📰"),
        ("weather", "查看天气 ☀️"),
        ("todo", "Todo 清单 📝"),
        ("stock", "输入股票代码查询 📈"),
    ]

    static func title(forKey key: String) -> String {
        items.first { $0.key == key }?.title ?? key
    }

    /// 默认展示策略：除「苦练基本功」外全部展示
    private static func defaultVisible(_ key: String) -> Bool {
        key != "problem"
    }

    private static func prefsKey(_ key: String) -> String {
        "settings.contextMenu.\(key)"
    }

    /// 读取某菜单项是否展示（未设置过时回退默认策略）
    static func isVisible(key: String) -> Bool {
        let pk = prefsKey(key)
        if UserDefaults.standard.object(forKey: pk) == nil {
            return defaultVisible(key)
        }
        return UserDefaults.standard.bool(forKey: pk)
    }

    static func setVisible(_ visible: Bool, key: String) {
        UserDefaults.standard.set(visible, forKey: prefsKey(key))
    }
}

// MARK: - 投喂期间的全屏拦截视图
/// 透明全屏视图：投喂期间接住落在桌面/其他 App 区域的鼠标事件，取消投喂且事件不透传
final class FeedOverlayView: NSView {
    weak var catView: CatView?
    private let transparentCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1)),
        hotSpot: .zero
    )

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// 整个区域使用透明光标（猫条即光标）
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: transparentCursor)
    }

override func mouseDown(with event: NSEvent) {
// 左键（单击）取消：猫条掉地上了
catView?.requestCancelFeeding(byRightClick: false)
}
override func rightMouseDown(with event: NSEvent) {
// 右键（双击）取消：为什么不喂我
catView?.requestCancelFeeding(byRightClick: true)
}
override func otherMouseDown(with event: NSEvent) {
catView?.requestCancelFeeding(byRightClick: false)
}
    /// 拖拽/滚轮在投喂期间直接吞掉（不透传给其他 App）
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

// MARK: - Cat View (CALayer 渲染 + 鼠标拖拽 + 右键菜单)

class CatView: NSView {
    weak var viewModel: PetViewModel?
    weak var windowRef: NSWindow?
    private var dragOffset: NSPoint = .zero
    private var isDragging = false
    private var trackingArea: NSTrackingArea?

    // MARK: - 纯 AppKit 绘制（不使用 CALayer / transform / 子视图）
    // 彻底避免 layer 相关的所有渲染问题
    private var currentImage: NSImage?
    /// 上一次渲染的帧标识（state + frameIndex），用于跳过未变化的重绘
    private var lastRenderedState: String = ""
    private var lastRenderedFrameIndex: Int = -1
    private var lastRenderedSpriteRevision: Int = -1

    func setupLayerHosting() {
        // 不需要任何子视图或 layer，全部通过 draw(_:) 绘制
        FileLogger.log("[DesktopPet] setup: pure draw(_:) rendering")
    }

    // 注意：不使用 NSTrackingArea / mouseEntered / mouseExited
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 已移除"看向鼠标"翻转，猫固定朝右，这里原样绘制即可
        // 素材帧已统一为单张基准图（消除 AI 逐帧抖动），动作幅度完全由渲染层呼吸控制（±1%，4 秒周期，几乎静止）
        guard let image = currentImage else { return }
        let t = Date().timeIntervalSinceReferenceDate
        let breathe = 1.0 + 0.010 * sin(t * 2.0 * .pi / 4.0)
        let w = bounds.width * breathe
        let h = bounds.height * breathe
        let rect = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        image.draw(in: rect)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        FileLogger.log("[DesktopPet] viewDidMoveToWindow: window=\(String(describing: window))")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        FileLogger.log("[DesktopPet] viewWillMoveToWindow: newWindow=\(String(describing: newWindow))")
    }

    /// 保存当前帧并触发重绘（帧未变化时跳过，减少 GPU 唤醒）
    func updateLayerImage() {
        guard let vm = viewModel else {
            FileLogger.log("[DesktopPet] updateLayerImage: viewModel is nil")
            return
        }
        // 帧未变化时跳过重绘（如 sleep 状态画面静止）
        let stateKey = vm.animationState.rawValue
        let frameIndex = vm.currentFrameIndex
        guard stateKey != lastRenderedState || frameIndex != lastRenderedFrameIndex || lastRenderedSpriteRevision != vm.spriteRevision else { return }
        lastRenderedState = stateKey
        lastRenderedFrameIndex = frameIndex
        lastRenderedSpriteRevision = vm.spriteRevision

        guard let image = vm.currentFrameImage else {
            FileLogger.log("[DesktopPet] updateLayerImage: currentFrameImage is nil, state=\(vm.animationState.displayName)")
            return
        }
        
        currentImage = image
        needsDisplay = true
    }

    // MARK: - Mouse Events
    
    override func mouseDown(with event: NSEvent) {
        guard let win = windowRef else { return }
        dragOffset = event.locationInWindow
        isDragging = false
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard let win = windowRef else { return }
        isDragging = true
        
        let mouseLocation = event.locationInWindow
        let currentOrigin = win.frame.origin
        
        let newX = currentOrigin.x + mouseLocation.x - dragOffset.x
        let newY = currentOrigin.y + mouseLocation.y - dragOffset.y
        
        win.setFrameOrigin(NSPoint(x: newX, y: newY))
        // 更新窗口位置，供朝向判断使用
        viewModel?.windowPosition = NSPoint(x: newX, y: newY)
    }
    
    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            // 投喂模式：点击小猫即吃掉猫条，走喂食互动而不是普通点击逻辑
            if isFeeding {
                performFeed()
                isDragging = false
                return
            }
            // 点击恢复 focus（从 warn 状态回来）
            viewModel?.transitionTo(.focus)
            
// 点击小猫：把小猫窗口及其相关弹窗（Todo/天气/做题等）全部放到最前
// 仅唤起仍可见的弹窗：已点 ✕ 关闭（orderOut 隐藏）的窗口不能被重新弹出，
// 否则其 JS 关闭 handler 已被移除，会出现"关了又弹出、再也关不上"的僵尸窗口
windowRef?.orderFrontRegardless()
for w in NSApp.windows where w is HTMLAlertWindow && w.isVisible {
    w.orderFrontRegardless()
}

            // 双击展示 Todo 清单
            if event.clickCount == 2 {
                showTodoList()
            }
        }
        isDragging = false
    }
    
    private var loadingLabel: NSTextField?
    
    private func showLoadingToast(_ text: String) {
        hideLoadingToast()
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        label.textColor = .black
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .center
        label.frame = NSRect(x: 0, y: bounds.height - 30, width: bounds.width, height: 24)
        addSubview(label)
        loadingLabel = label
    }
    
    private func hideLoadingToast() {
        loadingLabel?.removeFromSuperview()
        loadingLabel = nil
    }
    
    // MARK: - 喂猫条互动

    /// 是否处于投喂模式（猫条跟随鼠标，等待点击小猫）
    private var isFeeding = false
    /// 跟随鼠标的猫条窗口
    private var treatWindow: NSWindow?
    /// 猫条跟随鼠标的定时器（1/30s 采样全局鼠标位置）
    private var treatFollowTimer: Timer?
    /// 投喂期间的全屏透明拦截层（每屏一个窗口）：接住投喂中落在桌面/其他 App 的鼠标点击，
    /// 取消投喂且事件不透传（右键不会再触发桌面/其他 App 的菜单）
    private var feedOverlayWindows: [NSWindow] = []
    /// 透明光标（投喂时隐藏系统光标，猫条即光标）
    private let transparentCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1)),
        hotSpot: .zero
    )
    /// 小猫说话对话框窗口（粉色手绘气泡）：独立于小猫窗口——小猫窗口仅 160pt，宽气泡会被裁剪
    private var speechBubbleWindow: NSWindow?
    /// 气泡跟随定时器（1/30s）：拖动小猫时气泡同步跟随，悬浮期间轻微上下浮动
    private var speechBubbleFollowTimer: Timer?

    /// 进入投喂模式：猫条跟随鼠标，点击小猫完成喂食
    func startFeeding() {
        cancelFeeding()
        isFeeding = true
        FileLogger.log("[DesktopPet] 进入投喂模式")

        // 猫条窗口：透明无边界、不接鼠标事件（点击穿透到小猫）
        let treat = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 132, height: 92),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        treat.backgroundColor = .clear
        treat.isOpaque = false
        treat.hasShadow = false
        // 层级必须高于小猫窗口（.popUpMenu），投喂时猫条悬浮在小猫图层之上
        treat.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        treat.ignoresMouseEvents = true
        treat.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        treat.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 132, height: 92))

        let emoji = NSTextField(labelWithString: "🍡")
        emoji.font = .systemFont(ofSize: 44)
        emoji.alignment = .center
        emoji.frame = NSRect(x: 0, y: 36, width: 132, height: 56)
        container.addSubview(emoji)

        let hint = NSTextField(labelWithString: "点小猫投喂 · 点击取消")
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        hint.layer?.cornerRadius = 9
        hint.frame = NSRect(x: 11, y: 6, width: 110, height: 20)
        container.addSubview(hint)

        treat.contentView = container
        treatWindow = treat
        updateTreatPosition()
        treat.orderFrontRegardless()

        // 高频采样全局鼠标位置，让猫条贴着光标移动
        treatFollowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTreatPosition()
            }
        }

        // 投喂期间的全屏透明拦截层：层级在小猫窗口之下、其他 App 窗口之上，
        // 接住落在桌面/其他 App 的鼠标点击（取消投喂且不透传，右键不会弹出桌面菜单）
        for screen in NSScreen.screens {
            let overlay = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            overlay.backgroundColor = .clear
            overlay.isOpaque = false
            overlay.hasShadow = false
            overlay.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            overlay.ignoresMouseEvents = false
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            overlay.isReleasedWhenClosed = false
            overlay.hidesOnDeactivate = false
            let v = FeedOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.catView = self
            overlay.contentView = v
            overlay.orderFrontRegardless()
            feedOverlayWindows.append(overlay)
        }

        // 投喂期间隐藏系统光标（猫条即光标）
        transparentCursor.set()
        windowRef?.invalidateCursorRects(for: self)

        // 兜底：60 秒未投喂自动取消，避免猫条永远跟着鼠标
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            if self?.isFeeding == true {
                self?.cancelFeeding()
            }
        }
    }

    /// 猫条窗口贴着光标（猫条主体居中于光标，提示文字在下方）
    private func updateTreatPosition() {
        guard let treat = treatWindow else { return }
        let loc = NSEvent.mouseLocation
        // 猫条 emoji 位于窗口顶部（y 36~92，中心约在 64pt 处），对准光标位置
        treat.setFrameOrigin(NSPoint(x: loc.x - 66, y: loc.y - 64))
    }

    /// 当前全局鼠标是否在小猫窗口内
    private func mouseOverCat() -> Bool {
        guard let win = windowRef else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, win.frame, false)
    }

    /// 投喂期间在小猫区域也隐藏系统光标
    override func resetCursorRects() {
        if isFeeding {
            addCursorRect(bounds, cursor: transparentCursor)
        }
    }

    /// 退出投喂模式（取消喂食）：移除猫条窗口与全屏拦截层，恢复系统光标
func cancelFeeding() {
guard isFeeding || treatWindow != nil || !feedOverlayWindows.isEmpty else { return }
isFeeding = false
        // 移除全屏拦截层（恢复其他 App 的鼠标交互）
        for overlay in feedOverlayWindows {
            overlay.orderOut(nil)
            overlay.close()
        }
        feedOverlayWindows = []
        // 恢复系统箭头光标
        NSCursor.arrow.set()
        treatFollowTimer?.invalidate()
        treatFollowTimer = nil
        treatWindow?.orderOut(nil)
        treatWindow?.close()
        treatWindow = nil
    }

    /// 投喂成功：小猫吃掉猫条，播放开心动画 + 气泡 + 飘心，亲密度 +1
    private func performFeed() {
        cancelFeeding()
        FileLogger.log("[DesktopPet] 投喂成功，亲密度 +1")

        // 小猫开心动画（pet 无有效帧时内部会 fallback 到 warn）
        viewModel?.pet()

        // 亲密度持久化
        let key = "settings.affinity"
        let newCount = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(newCount, forKey: key)

        showFeedBubble(text: "喵呜～真好吃 😋 亲密度 +1")
        spawnHearts()
    }

    /// 在小猫头顶展示对话框（粉色手绘风气泡，所有和小猫的对话台词都走这里）：
    /// 弹入（70%→100% 带回弹放大 + 淡入）→ 悬浮 hold 秒（轻微浮动、跟随小猫拖动）→ fade 秒淡出移除
    private func showFeedBubble(text: String, hold: TimeInterval = 2.2, fade: TimeInterval = 0.5) {
        // 新气泡替换旧气泡：旧的立即关闭，避免两帧重叠
        dismissSpeechBubble(animated: false)
        guard let catWin = windowRef, catWin.isVisible else { return }

        let bubbleView = SpeechBubbleView(text: text)
        let size = bubbleView.frame.size

        let bubbleWin = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        bubbleWin.backgroundColor = .clear
        bubbleWin.isOpaque = false
        bubbleWin.hasShadow = false
        // 层级高于小猫窗口（.popUpMenu），悬浮在小猫头顶；纯展示不挡小猫的点击
        bubbleWin.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        bubbleWin.ignoresMouseEvents = true
        bubbleWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bubbleWin.isReleasedWhenClosed = false
        bubbleWin.hidesOnDeactivate = false
        bubbleWin.contentView = bubbleView

        speechBubbleWindow = bubbleWin
        repositionSpeechBubble()

        // 弹入动画：锚定尾巴底部，从 70% 放大到 100%（easeOutBack 过冲回弹），同时淡入
        bubbleWin.alphaValue = 0
        bubbleWin.orderFrontRegardless()
        let finalFrame = bubbleWin.frame
        let startSize = NSSize(width: size.width * 0.7, height: size.height * 0.7)
        let startFrame = NSRect(
            x: finalFrame.midX - startSize.width / 2,
            y: finalFrame.minY,
            width: startSize.width,
            height: startSize.height
        )
        bubbleWin.setFrame(startFrame, display: false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            // 过冲回弹曲线，营造「啵」地弹出的手感
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
            bubbleWin.animator().alphaValue = 1
            bubbleWin.animator().setFrame(finalFrame, display: true)
        }, completionHandler: { [weak self] in
            // 弹入完成后才开始跟随（避免 follow 的 setFrame 打断弹入动画）
            self?.startSpeechBubbleFollow()
        })

        // 悬浮 hold 秒（另加弹入时长）后淡出移除；只关闭当前这颗气泡，防止旧定时器误关新气泡
        DispatchQueue.main.asyncAfter(deadline: .now() + hold + 0.3) { [weak self, weak bubbleWin] in
            guard let self, let bubbleWin, self.speechBubbleWindow === bubbleWin else { return }
            self.dismissSpeechBubble(animated: true, fade: fade)
        }
    }

    /// 将气泡定位到小猫头顶（水平居中、尾巴尖轻搭猫头），并夹在屏幕可视范围内
    private func repositionSpeechBubble() {
        guard let bubbleWin = speechBubbleWindow, let catWin = windowRef else { return }
        let catFrame = catWin.frame
        let bubbleSize = bubbleWin.frame.size

        // 悬浮期间轻微上下浮动（±2pt 正弦呼吸）
        let t = Date().timeIntervalSinceReferenceDate
        let bob = 2.0 * sin(t * 2.0 * .pi / 1.8)

        let x = catFrame.midX - bubbleSize.width / 2
        let y = catFrame.maxY - 4 + bob

        // 限制在气泡所在屏幕的可视范围内（不超出屏幕、不顶进菜单栏）
        let screen = NSScreen.screens.first { $0.frame.intersects(catFrame) } ?? NSScreen.main
        var px = x
        var py = y
        if let vf = screen?.visibleFrame {
            px = min(max(x, vf.minX + 4), vf.maxX - bubbleSize.width - 4)
            py = min(y, vf.maxY - bubbleSize.height - 4)
        }
        bubbleWin.setFrameOrigin(NSPoint(x: px, y: py))
    }

    /// 启动气泡跟随定时器：拖动小猫时气泡同步跟随，并保持轻微浮动
    private func startSpeechBubbleFollow() {
        guard speechBubbleWindow != nil else { return }
        speechBubbleFollowTimer?.invalidate()
        speechBubbleFollowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.repositionSpeechBubble()
            }
        }
    }

    /// 移除对话气泡（animated=true 时先淡出再关闭窗口）
    private func dismissSpeechBubble(animated: Bool, fade: TimeInterval = 0.5) {
        speechBubbleFollowTimer?.invalidate()
        speechBubbleFollowTimer = nil
        guard let bubbleWin = speechBubbleWindow else { return }
        speechBubbleWindow = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = fade
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                bubbleWin.animator().alphaValue = 0
            }, completionHandler: {
                bubbleWin.orderOut(nil)
                bubbleWin.close()
            })
        } else {
            bubbleWin.orderOut(nil)
            bubbleWin.close()
        }
    }

/// 拦截层点击取消投喂：左键（单击）取消说“猫条掉地上啦”，右键（双击）取消说“为什么不喂我～”
func requestCancelFeeding(byRightClick: Bool) {
cancelFeeding()
catSay(byRightClick ? "为什么不喂我～" : "掉地上啦，不吃～")
}

    /// 小猫说话：统一走粉色对话框（弹入 → 悬浮 2s → 1s 淡出）
    private func catSay(_ text: String) {
        showFeedBubble(text: text, hold: 2.0, fade: 1.0)
    }

    /// 飘心特效：3 颗爱心从小猫身上缓缓升起并淡出
    private func spawnHearts() {
        let symbols = ["💗", "💖", "💕"]
        for (i, sym) in symbols.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) { [weak self] in
                guard let self else { return }
                let heart = NSTextField(labelWithString: sym)
                heart.font = .systemFont(ofSize: 16)
                heart.alignment = .center
                let x = self.bounds.width * (0.25 + 0.25 * CGFloat(i))
                let startY = self.bounds.height * 0.3
                heart.frame = NSRect(x: x - 12, y: startY, width: 24, height: 20)
                heart.alphaValue = 0.95
                self.addSubview(heart)

                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 1.1
                    heart.animator().alphaValue = 0
                    heart.animator().frame = NSRect(
                        x: heart.frame.origin.x,
                        y: startY + 44,
                        width: heart.frame.width,
                        height: heart.frame.height
                    )
                }, completionHandler: {
                    heart.removeFromSuperview()
                })
            }
        }
    }

    /// 显示喝水提醒弹窗（HTML 样式）
    func showDrinkWaterAlert() {
        viewModel?.isWaterAlertShowing = true
        let htmlBody = """
        <div class="water-icon">💧</div>
        <div class="water-text">该喝水啦！</div>
        <div class="water-tips">久坐对身体不好<br>起来倒杯水，活动一下吧～</div>
        """
        HTMLAlertWindow.show(title: "喝水提醒", htmlBody: htmlBody, width: 340) { [weak self] in
            self?.viewModel?.isWaterAlertShowing = false
            self?.viewModel?.transitionTo(.focus)
        }
    }
    
    /// 获取并展示今日热点新闻 Top10
    func fetchAndShowHotNews() {
        showLoadingToast("📰 加载热点新闻...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = NewsFetcher.fetchHotNews()
            DispatchQueue.main.async {
                self?.hideLoadingToast()
                self?.showHotNewsAlert(items)
            }
        }
    }

    /// 展示热点新闻弹窗（表格 + 可点击超链接）
    private func showHotNewsAlert(_ items: [NewsItem]) {
        guard !items.isEmpty else {
            HTMLAlertWindow.showResizable(title: "今日热点新闻", htmlBody: "<div style=\"text-align:center;padding:30px 0;color:#c0c0d0;\">加载失败，请检查网络连接</div>", width: 400)
            return
        }
        var rows: [String] = []
        for item in items {
            let escapedTitle = item.title
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#x27;")
            rows.append("""
                <tr>
                    <td><span class="news-rank">\(item.rank)</span></td>
                    <td><a href="\(item.url)" class="news-link">\(escapedTitle)</a></td>
                </tr>
            """)
        }
        let htmlBody = """
        <table class="news-table">
            <thead>
                <tr><th style="width:48px">排名</th><th>标题</th></tr>
            </thead>
            <tbody>
                \(rows.joined(separator: "\n"))
            </tbody>
        </table>
        """
        HTMLAlertWindow.showResizable(title: "今日热点新闻 Top10", htmlBody: htmlBody, width: 480, maxHeight: 640)
    }
    
    /// 显示 Todo 清单弹窗
    func showTodoList() {
        let todos = TodoManager.shared.load()
        HTMLAlertWindow.showTodo(title: "Todo 清单 📝", todos: todos, onAdd: { text in
            TodoManager.shared.add(text: text)
        }, onDelete: { id in
            TodoManager.shared.delete(id: id)
        })
    }
    
    // MARK: - 股票查询
    
    func showStockInput() {
        let history = StockHistoryManager.shared.load()
        var extraHTML = ""
        if !history.isEmpty {
            var tags = ""
            for item in history {
                let display = item.name.isEmpty ? item.code : "\(item.name) (\(item.code.uppercased()))"
                tags += "<span class=\"history-tag\" onclick=\"document.getElementById('locationInput').value='\(item.code)';window.webkit.messageHandlers.confirm.postMessage(document.getElementById('locationInput').value)\">\(display)</span>"
            }
            extraHTML = """
            <div style="margin-top:12px;">
                <div style="font-size:11px;color:#666680;margin-bottom:8px;">最近查询</div>
                <div style="display:flex;flex-wrap:wrap;gap:6px;">\(tags)</div>
            </div>
            <style>
                .history-tag {
                    background: rgba(102,126,234,0.15);
                    border: 1px solid rgba(102,126,234,0.25);
                    color: #a0a8e0;
                    font-size: 12px;
                    padding: 4px 10px;
                    border-radius: 16px;
                    cursor: pointer;
                    transition: all 0.2s;
                }
                .history-tag:hover {
                    background: rgba(102,126,234,0.3);
                    color: #d0d4f0;
                }
            </style>
            """
        }
        HTMLAlertWindow.showInput(title: "输入股票代码", placeholder: "如：600000、000001、300001", okLabel: "查询 📈", extraHTML: extraHTML) { [weak self] input in
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            self?.fetchAndShowStock(code: trimmed)
        }
    }
    
    private func fetchAndShowStock(code: String) {
        showLoadingToast("正在查询股票...")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let info = StockService.fetchStockInfo(code: code) else {
                DispatchQueue.main.async { [weak self] in
                    self?.hideLoadingToast()
                    HTMLAlertWindow.show(title: "查询失败", htmlBody: "<div style=\"text-align:center;padding:20px 0;color:#c0c0d0;\">查询失败，请检查股票代码是否正确</div>", width: 300)
                }
                return
            }
            StockHistoryManager.shared.add(code: info.code, name: info.name)
            DispatchQueue.main.async { [weak self] in
                self?.hideLoadingToast()
                self?.showStockAlert(info)
            }
        }
    }
    
    private func showStockAlert(_ info: StockInfo) {
        let color = info.change >= 0 ? "#ff4d4f" : "#52c41a"
        let sign = info.change >= 0 ? "+" : ""
        let arrow = info.change >= 0 ? "▲" : "▼"
        
        let formatVolume: String
        if info.volume >= 100000000 {
            formatVolume = String(format: "%.2f亿", info.volume / 100000000)
        } else if info.volume >= 10000 {
            formatVolume = String(format: "%.2f万", info.volume / 10000)
        } else {
            formatVolume = String(format: "%.0f", info.volume)
        }
        
        let formatTurnover: String
        if info.turnover >= 100000000 {
            formatTurnover = String(format: "%.2f亿", info.turnover / 100000000)
        } else if info.turnover >= 10000 {
            formatTurnover = String(format: "%.2f万", info.turnover / 10000)
        } else {
            formatTurnover = String(format: "%.0f", info.turnover)
        }
        
        let body = """
        <div style="text-align:center;margin-bottom:18px;">
            <div style="font-size:22px;font-weight:700;color:#f0f0f5;">\(info.name)</div>
            <div style="font-size:12px;color:#666680;margin-top:4px;">\(info.code.uppercased())</div>
        </div>
        <div style="text-align:center;margin-bottom:20px;">
            <div style="font-size:36px;font-weight:800;color:\(color);letter-spacing:-1px;">\(String(format: "%.2f", info.currentPrice))</div>
            <div style="font-size:14px;color:\(color);margin-top:6px;">
                \(arrow) \(sign)\(String(format: "%.2f", info.change)) (\(sign)\(String(format: "%.2f", info.changePercent))%)
            </div>
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;">
            <div class="stock-cell">
                <div class="stock-label">今开</div>
                <div class="stock-value">\(String(format: "%.2f", info.openPrice))</div>
            </div>
            <div class="stock-cell">
                <div class="stock-label">昨收</div>
                <div class="stock-value">\(String(format: "%.2f", info.prevClose))</div>
            </div>
            <div class="stock-cell">
                <div class="stock-label">最高</div>
                <div class="stock-value">\(String(format: "%.2f", info.high))</div>
            </div>
            <div class="stock-cell">
                <div class="stock-label">最低</div>
                <div class="stock-value">\(String(format: "%.2f", info.low))</div>
            </div>
            <div class="stock-cell">
                <div class="stock-label">成交量</div>
                <div class="stock-value">\(formatVolume)</div>
            </div>
            <div class="stock-cell">
                <div class="stock-label">成交额</div>
                <div class="stock-value">\(formatTurnover)</div>
            </div>
        </div>
        """
        
        let extraCSS = """
            .stock-cell {
                background: rgba(255,255,255,0.04);
                border-radius: 10px;
                padding: 10px 12px;
                text-align: center;
            }
            .stock-label {
                font-size: 11px;
                color: #666680;
                margin-bottom: 4px;
            }
            .stock-value {
                font-size: 15px;
                font-weight: 600;
                color: #e0e0e8;
            }
        """
        
        HTMLAlertWindow.show(title: "\(info.name) \(info.code.uppercased())", htmlBody: body + "<style>\(extraCSS)</style>", width: 340, maxHeight: 520)
    }

    /// 获取天气并渲染进当前天气窗口（默认本地 / 指定城市）
    private func fetchWeatherAndShow(for cityInput: String? = nil) {
        HTMLAlertWindow.showWeatherLoading(cityInput == nil ? "🌤️ 正在加载本地天气..." : "🌤️ 正在查询 \"\(cityInput!)\" 天气...")
        DispatchQueue.global(qos: .userInitiated).async {
            let forecast: WeatherForecast?
            if let input = cityInput {
                forecast = WeatherService.fetchWeatherForecast(forCity: input)
            } else {
                // 默认城市：GPS/Wi-Fi 定位优先（准确），权限拒绝或超时回退 IP 定位（可能偏到别处）
                forecast = WeatherService.fetchWeatherForecastWithGPS()
                    ?? WeatherService.fetchWeatherForecastWithLocation()
            }
            DispatchQueue.main.async {
                if let f = forecast {
                    HTMLAlertWindow.renderWeatherCard(f)
                } else if let input = cityInput {
                    HTMLAlertWindow.showWeatherMessage("未找到城市 \"\(input)\"<br>请尝试其他名称")
                } else {
                    HTMLAlertWindow.showWeatherMessage("定位失败，无法获取当前位置<br>请在上方输入城市名查询")
                }
            }
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {
        // 投喂模式中右键：取消投喂，不弹菜单
        if isFeeding {
            cancelFeeding()
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let fullAccess = AccessControl.isFullAccess

        // 菜单项定义：标识 key、action、权限等级（fullOnly = 需校验码解锁的高级功能），标题由 ContextMenuPrefs 统一维护
        typealias MenuEntry = (key: String, action: Selector, fullOnly: Bool)
        let entries: [MenuEntry] = [
            ("pet", #selector(petAction(_:)), false),
            ("feed", #selector(feedAction(_:)), false),
            ("word", #selector(wordLearningAction(_:)), true),
            ("problem", #selector(problemAction(_:)), true),
            ("news", #selector(hotNewsAction(_:)), true),
            ("weather", #selector(showWeatherAction(_:)), true),
            ("todo", #selector(todoAction(_:)), false),
            ("stock", #selector(stockAction(_:)), true),
        ]

        // 按「设置面板 > 菜单设置」的展示配置过滤（如「苦练基本功」默认不展示）
        let visibleEntries = entries.filter { ContextMenuPrefs.isVisible(key: $0.key) }

        // 按权限处理：可用功能排最前，待解锁的置灰功能统一排到最后（组内保持原顺序）
        let ordered = visibleEntries.enumerated()
            .sorted { a, b in
                if a.element.fullOnly != b.element.fullOnly {
                    return !a.element.fullOnly
                }
                return a.offset < b.offset
            }
            .map(\.element)

        for entry in ordered {
            let item = NSMenuItem(title: ContextMenuPrefs.title(forKey: entry.key), action: entry.action, keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.fullOnly ? fullAccess : true
            menu.addItem(item)
        }

        // 未解锁：尾部追加「解锁更多功能」引导（点击打开设置锚定权限栏；解锁成功后本项不再出现）
        if !fullAccess {
            menu.addItem(NSMenuItem.separator())
            let unlockItem = NSMenuItem(title: "解锁更多功能 🔓", action: #selector(unlockMoreAction(_:)), keyEquivalent: "")
            unlockItem.target = self
            menu.addItem(unlockItem)
        }

        let quitItem = NSMenuItem(title: "关闭 ❌", action: #selector(quitAction(_:)), keyEquivalent: "")
        quitItem.target = self
        quitItem.isEnabled = true  // 退出是最基础功能，任何权限下都允许
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        // 使用事件中的窗口坐标直接转换到视图坐标，最可靠
        let location = self.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: location, in: self)
    }
    
    @objc private func petAction(_ sender: NSMenuItem) { viewModel?.pet() }
    /// 「喂猫条」：进入投喂模式，猫条跟随鼠标，点小猫完成喂食
    @objc private func feedAction(_ sender: NSMenuItem) { startFeeding() }
    /// 「解锁更多功能」：通知 AppDelegate 打开设置面板并锚定闪烁「权限」栏
    @objc private func unlockMoreAction(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .init("DesktopPet.ShowAccessSettings"), object: nil)
    }
    @objc private func wordLearningAction(_ sender: NSMenuItem) { viewModel?.startWordLearning() }
    @objc private func problemAction(_ sender: NSMenuItem) { showRandomProblem() }
    @objc private func hotNewsAction(_ sender: NSMenuItem) { viewModel?.showHotNews() }
    @objc private func showWeatherAction(_ sender: NSMenuItem) { showWeatherInput() }
    @objc private func todoAction(_ sender: NSMenuItem) { showTodoList() }
    @objc private func stockAction(_ sender: NSMenuItem) { showStockInput() }

    // MARK: - 天气查询

    /// 显示天气查询弹窗（默认本地天气，输入城市后同窗口切换）
    private func showWeatherInput() {
        HTMLAlertWindow.showWeatherInput(title: "查看天气 ☀️", width: 380, maxHeight: 640,
            onQuery: { [weak self] city in
                let trimmed = city.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                self?.fetchWeatherAndShow(for: trimmed)
            },
            onClose: nil
        )
        // 打开窗口后立即加载本地天气
        fetchWeatherAndShow(for: nil)
    }

    // MARK: - 苦练基本功（LeetCode 热题 100）

    /// 当前做题弹窗引用
    private var problemWindow: HTMLAlertWindow?

    /// 随机抽一题并展示（换一题时重入，避开上一题）
    /// 题干由 LeetCodeService 后台拉取（图片内联 base64），完成后弹完整卡片
    private func showRandomProblem() {
        guard let problem = ProblemBankManager.randomProblem() else {
            FileLogger.log("[ProblemBank] 题库未加载，无法出题")
            problemWindow = HTMLAlertWindow.showProblem(title: "苦练基本功 🧩", htmlBody: """
            <div style="text-align:center;padding:40px 20px;">
                <div style="font-size:48px;margin-bottom:16px;">📭</div>
                <div style="font-size:18px;font-weight:600;color:#f0f0f5;margin-bottom:12px;">题库加载失败</div>
                <div style="font-size:14px;color:#888;">未找到热题 100 题库文件，请重新安装应用</div>
            </div>
            """)
            return
        }
        FileLogger.log("[ProblemBank] 抽题: \(problem.id). \(problem.title)（\(problem.difficulty)）")

        // 首次拉取需请求 LeetCode 接口并下载图片，用 toast 提示加载中
        showLoadingToast("正在拉取题干…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detail = LeetCodeService.fetchDetail(slug: problem.slug)
            DispatchQueue.main.async {
                guard let self else { return }
                self.hideLoadingToast()
                let htmlBody = Self.problemCardHTML(problem: problem, detail: detail)
                self.problemWindow?.close()
                self.problemWindow = HTMLAlertWindow.showProblem(
                    title: "苦练基本功 🧩",
                    htmlBody: htmlBody,
                    width: 520
                ) { [weak self] in
                    self?.showRandomProblem()
                }
            }
        }
    }

    /// 拼装题干卡片 HTML（题干内容 + 深色卡片适配样式 + 换一题按钮）
    private static func problemCardHTML(problem: LeetCodeProblem, detail: LeetCodeService.ProblemDetail?) -> String {
        // 难度徽章配色：简单-绿 / 中等-琥珀 / 困难-玫红
        let badgeColor: String
        switch problem.difficulty {
        case "简单": badgeColor = "#52c41a"
        case "困难": badgeColor = "#e0526a"
        default:    badgeColor = "#e8a33d"
        }

        // 题干主体：拉取失败时给出提示（可点换一题重试）
        let contentHTML: String
        if let detail {
            contentHTML = "<div class=\"problem-content\">\(detail.contentHTML)</div>"
        } else {
            contentHTML = """
            <div style="text-align:center;padding:30px 16px;">
                <div style="font-size:40px;margin-bottom:12px;">📡</div>
                <div style="font-size:15px;font-weight:600;color:#f0f0f5;margin-bottom:10px;">题干拉取失败</div>
                <div style="font-size:13px;color:#888;">可能是网络问题或 LeetCode 接口限流<br>点击下方「换一题」重试</div>
            </div>
            """
        }

        return """
        <div class="quiz-meta">
            <span>LeetCode 热题 100</span>
            <span>\(problem.id) · \(problem.difficulty)</span>
        </div>
        <div class="problem-header">
            <div class="problem-badge" style="background:\(badgeColor)">\(problem.difficulty)</div>
            <div class="problem-title">\(problem.id). \(problem.title)</div>
        </div>
        \(contentHTML)
        <button class="btn-swap" onclick="window.webkit.messageHandlers.problemNext.postMessage('')">换一题 🔄</button>
        <style>
            .quiz-meta { display: flex; justify-content: space-between; font-size: 12px; color: #888; margin-bottom: 12px; padding: 0 2px; }
            .problem-header { text-align: center; padding: 14px 10px 18px; border-bottom: 1px solid rgba(255,255,255,0.08); margin-bottom: 14px; }
            .problem-badge { display: inline-block; font-size: 12px; font-weight: 600; color: white; padding: 3px 12px; border-radius: 10px; margin-bottom: 10px; }
            .problem-title { font-size: 22px; font-weight: 700; color: #a0e8ff; line-height: 1.4; }
            /* LeetCode 题干样式适配深色卡片 */
            .problem-content { font-size: 14px; color: #d0d0dc; line-height: 1.8; margin-bottom: 16px; }
            .problem-content p { margin: 8px 0; }
            .problem-content img { max-width: 100%; height: auto; border-radius: 8px; margin: 8px 0; }
            .problem-content pre { background: rgba(0,0,0,0.35); padding: 12px; border-radius: 8px; overflow-x: auto; font-size: 12px; color: #d8d8e8; white-space: pre-wrap; word-break: break-word; }
            .problem-content code { background: rgba(255,255,255,0.08); padding: 1px 5px; border-radius: 4px; font-size: 13px; color: #a0e8ff; }
            .problem-content pre code { background: none; padding: 0; color: #d8d8e8; }
            .problem-content ul, .problem-content ol { padding-left: 22px; margin: 8px 0; }
            .problem-content li { margin: 4px 0; }
            .problem-content strong { color: #f0f0f8; }
            .problem-content table { border-collapse: collapse; margin: 8px 0; }
            .problem-content td, .problem-content th { border: 1px solid rgba(255,255,255,0.15); padding: 6px 10px; font-size: 13px; }
            .btn-swap { background: rgba(255,255,255,0.08); color: #c0c0d0; border: 1px solid rgba(255,255,255,0.12); padding: 10px 32px; border-radius: 20px; font-size: 14px; cursor: pointer; transition: all 0.2s; width: 100%; }
            .btn-swap:hover { background: rgba(255,255,255,0.14); }
        </style>
        """
    }

    // MARK: - 背单词功能
        
    /// 当前学习/答题序号
    private var quizIndex: Int = 0
    /// 当前学习卡片序号（学习阶段）
    private var learningIndex: Int = 0
    /// 本轮学习的单词（学习 + 考试共用）
    private var learningWords: [Word] = []
    /// 总答题数
    private var quizTotal: Int = 3
    /// 得分
    private var quizScore: Int = 0
    /// 当前背单词弹窗引用
    private var wordLearningWindow: HTMLAlertWindow?
        
    /// 开始背单词：先学 3 个，再考 3 个
    func startWordLearning() {
        let category = WordService.shared.currentCategory
        let words = WordService.shared.getWords(for: category)
            
        guard words.count >= 3 else {
            FileLogger.log("[DesktopPet] 词库不足 3 个单词: \(category.rawValue)，共 \(words.count) 个")
            let htmlBody = """
            \(categoryBarHTML())
            <div style="text-align:center;padding:20px;">
                <div style="font-size:48px;margin-bottom:16px;">📭</div>
                <div style="font-size:18px;font-weight:600;color:#f0f0f5;margin-bottom:12px;">词库单词不足</div>
                <div style="font-size:14px;color:#888;">至少需要 3 个单词才能开始学习<br>可点击上方其他分类，或添加单词到词库</div>
            </div>
            """
            wordLearningWindow = HTMLAlertWindow.showWordLearning(
                title: "背单词 📚",
                htmlBody: htmlBody,
                width: 360,
                onSwitchCategory: { [weak self] raw in self?.handleSwitchCategory(raw) }
            )
            return
        }
            
        // 随机选 3 个单词用于学习和考试
        learningWords = Array(words.shuffled().prefix(3))
        learningIndex = 0
        quizIndex = 0
        quizScore = 0
        quizTotal = learningWords.count
        
        // 学习开始即后台并行预取本轮单词详情（音标/例句/发音），
        // 用户看学习卡片时数据陆续就绪，考试阶段全部命中缓存、0 网络等待
        DictionaryService.shared.prefetch(words: learningWords.map { $0.word })

        // 开始学习阶段
        showLearningCard(index: 0)
    }
        
    /// 关闭当前背单词弹窗
    private func closeWordLearningWindow() {
        wordLearningWindow?.orderOut(nil)
        wordLearningWindow?.close()
        wordLearningWindow = nil
    }

    /// 背单词弹窗顶部的分类切换栏：点击分类即刻切换并以新词库重新开始本轮学习
    private func categoryBarHTML() -> String {
        let current = WordService.shared.currentCategory
        var chips = ""
        for cat in WordCategory.allCases {
            let active = cat == current ? " active" : ""
            chips += "<button class=\"cat-chip\(active)\" onclick=\"switchCategory('\(cat.rawValue)')\">\(cat.displayName)</button>"
        }
        return """
        <div class="cat-bar">
            <span class="cat-title">分类</span>
            \(chips)
        </div>
        <style>
            .cat-bar { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; margin-bottom: 14px; }
            .cat-title { font-size: 12px; color: #888; margin-right: 2px; }
            .cat-chip { background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.1); color: #b0b0c0; font-size: 12px; padding: 5px 10px; border-radius: 14px; cursor: pointer; transition: all 0.2s; font-family: inherit; }
            .cat-chip:hover { background: rgba(255,255,255,0.12); color: #e0e0e8; }
            .cat-chip.active { background: linear-gradient(135deg, #667eea, #764ba2); border-color: transparent; color: #fff; font-weight: 600; cursor: default; }
        </style>
        <script>
            function switchCategory(raw) {
                if (window.webkit && window.webkit.messageHandlers.switchCategory) {
                    window.webkit.messageHandlers.switchCategory.postMessage(raw);
                }
            }
        </script>
        """
    }

    /// 窗口内切换分类：持久化选择，关闭当前卡片并以新词库重新开始
    private func handleSwitchCategory(_ raw: String) {
        guard let category = WordCategory(rawValue: raw),
              category != WordService.shared.currentCategory else { return }
        FileLogger.log("[DesktopPet] 窗口内切换背单词分类: \(WordService.shared.currentCategory.rawValue) → \(category.rawValue)")
        WordService.shared.currentCategory = category
        closeWordLearningWindow()
        startWordLearning()
    }
    
    // MARK: - 学习阶段（先学 3 个）
    
    /// 显示学习卡片
    /// 音标/例句优先读预取缓存；未就绪时先隐藏占位，数据到达后通过 JS 热更新
    private func showLearningCard(index: Int) {
        guard index < learningWords.count else {
            // 学习完成，进入考试阶段
            fetchAndShowQuiz()
            return
        }
        
        let word = learningWords[index]
        learningIndex = index
        
        // 预取缓存中的详情（命中则直接展示，未命中由下方热更新补上）
        let detail = DictionaryService.shared.cachedDetail(for: word.word)

        // 音标
        let phoneticHTML: String
        if let ph = detail?.phonetic {
            phoneticHTML = "<span id=\"card-phonetic\" class=\"word-phonetic\">\(ph)</span>"
        } else {
            phoneticHTML = "<span id=\"card-phonetic\" class=\"word-phonetic\" style=\"display:none\"></span>"
        }
        
        // 例句
        let exampleHTML: String
        if let ex = detail?.firstExample {
            exampleHTML = "<div id=\"card-example\" class=\"word-example\">\"\(ex)\"</div>"
        } else {
            exampleHTML = "<div id=\"card-example\" class=\"word-example\" style=\"display:none\"></div>"
        }
        
        let isLast = index == learningWords.count - 1
        let btnText = isLast ? "开始考试 📝" : "下一个单词 →"
        
        let htmlBody = """
        \(categoryBarHTML())
        <div class="quiz-progress-bar">
            <div class="quiz-progress-fill" style="width:\(Double(index + 1) / Double(learningWords.count) * 100)%"></div>
        </div>
        <div class="quiz-meta">
            <span>学习 \(index + 1) / \(learningWords.count)</span>
            <span>📖 记忆模式</span>
        </div>
        <div class="word-card">
            <div class="word-row">
                <span class="word-text">\(word.word)</span>
                \(phoneticHTML)
                <button class="audio-btn" onclick="playAudio('\(word.word)')">🔊</button>
            </div>
            <div class="word-meaning">\(word.meaning)</div>
            \(exampleHTML)
        </div>
        <button class="btn-next" onclick="nextLearning()">\(btnText)</button>
        <style>
            .quiz-progress-bar { height: 4px; background: rgba(255,255,255,0.08); border-radius: 2px; margin-bottom: 12px; }
            .quiz-progress-fill { height: 100%; background: linear-gradient(90deg, #667eea, #764ba2); border-radius: 2px; transition: width 0.3s; }
            .quiz-meta { display: flex; justify-content: space-between; font-size: 12px; color: #888; margin-bottom: 16px; padding: 0 2px; }
            .word-card { background: rgba(255,255,255,0.04); border-radius: 14px; padding: 22px; margin-bottom: 20px; text-align: center; border: 1px solid rgba(255,255,255,0.06); }
            .word-row { display: flex; align-items: baseline; justify-content: center; gap: 10px; flex-wrap: wrap; margin-bottom: 14px; }
            .word-text { font-size: 28px; font-weight: 700; color: #a0e8ff; }
            .word-phonetic { font-size: 14px; color: #888; }
            .audio-btn { background: rgba(160,232,255,0.15); border: none; border-radius: 50%; width: 30px; height: 30px; font-size: 16px; cursor: pointer; transition: all 0.2s; }
            .audio-btn:hover { background: rgba(160,232,255,0.3); transform: scale(1.1); }
            .word-meaning { font-size: 18px; color: #e0e0e8; line-height: 1.6; }
            .word-example { font-size: 12px; color: #777; font-style: italic; margin-top: 12px; padding-top: 12px; border-top: 1px solid rgba(255,255,255,0.06); }
            .btn-next { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; border: none; padding: 12px 32px; border-radius: 20px; font-size: 15px; font-weight: 600; cursor: pointer; transition: all 0.2s; width: 100%; }
            .btn-next:hover { transform: scale(1.02); opacity: 0.95; }
        </style>
        <script>
            function playAudio(word) {
                if (window.webkit && window.webkit.messageHandlers.playAudio) {
                    window.webkit.messageHandlers.playAudio.postMessage(word);
                }
            }
            function nextLearning() {
                if (window.webkit && window.webkit.messageHandlers.nextQuiz) {
                    window.webkit.messageHandlers.nextQuiz.postMessage('next');
                }
            }
        </script>
        """
        
        let window = HTMLAlertWindow.showWordLearning(
            title: "背单词 📚",
            htmlBody: htmlBody,
            width: 380,
            onNextQuiz: { [weak self] _ in
                self?.closeWordLearningWindow()
                self?.showLearningCard(index: index + 1)
            },
            onSwitchCategory: { [weak self] raw in self?.handleSwitchCategory(raw) }
        )
        wordLearningWindow = window

        // 详情尚未就绪：API 数据到达后热更新当前卡片；
        // 若用户已翻页（wordLearningWindow 换成了新窗口），weak 引用比对会自动跳过
        if detail == nil {
            let targetWord = word.word
            Task { [weak self, weak window] in
                guard let fetched = await DictionaryService.shared.fetchWordDetail(word: targetWord) else { return }
                guard let self = self, let win = window, self.wordLearningWindow === win else { return }

                var js = ""
                if let ph = fetched.phonetic {
                    js += "var p=document.getElementById('card-phonetic');"
                    js += "if(p){p.textContent='\(Self.jsEscaped(ph))';p.style.display='inline';}"
                }
                if let ex = fetched.firstExample {
                    js += "var e=document.getElementById('card-example');"
                    js += "if(e){e.textContent='\"\(Self.jsEscaped(ex))\"';e.style.display='block';}"
                }
                guard !js.isEmpty else { return }
                win.evaluateScript(js)
            }
        }
    }
    
    /// JS 字符串字面量转义（防止单词/例句中的引号破坏注入的脚本）
    private static func jsEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - 考试阶段（再考 3 个）
        
    /// 生成选择题并显示考试界面（纯本地，无需网络）
    private func fetchAndShowQuiz() {
        guard quizIndex < quizTotal else {
            showQuizResult()
            return
        }
        
        let category = WordService.shared.currentCategory
        let word = learningWords[quizIndex]
        
        // 生成选择题（纯本地，同步完成）
        let quiz = DictionaryService.shared.generateQuiz(word: word, category: category)
        if let q = quiz {
            showQuizCard(quiz: q)
        } else {
            FileLogger.log("[DesktopPet] 生成选择题失败，跳过: \(word.word)")
            quizIndex += 1
            fetchAndShowQuiz()
        }
    }
    
    /// 显示答题卡片
    private func showQuizCard(quiz: QuizData) {
        let options = quiz.shuffledOptions
        let correctIdx = quiz.correctIndex
            
        // 构建选项 HTML（labels 按选项数量动态生成，避免下标越界崩溃）
        var optionsHTML = ""
        let labelChars: [String] = ["A", "B", "C", "D", "E"]
        for (i, opt) in options.enumerated() {
            let escaped = opt.replacingOccurrences(of: "\"", with: "&quot;")
            let lb = i < labelChars.count ? labelChars[i] : "\(i + 1)"
            optionsHTML += """
            <button class="quiz-option" onclick="selectAnswer(\(i), \(correctIdx))">
                <span class="option-label">\(lb)</span>
                <span class="option-text">\(escaped)</span>
            </button>
            """
        }
            
        // 例句
        let exampleHTML: String
        if let ex = quiz.example {
            exampleHTML = "<div class=\"word-example\">\"\(ex)\"</div>"
        } else {
            exampleHTML = ""
        }
            
        // 音标
        let phoneticHTML: String
        if let ph = quiz.phonetic {
            phoneticHTML = "<span class=\"word-phonetic\">\(ph)</span>"
        } else {
            phoneticHTML = ""
        }
            
        // 音频按钮（点击时按需调 API 获取发音）
        let audioHTML = "<button class=\"audio-btn\" onclick=\"playAudio('\(quiz.word)')\">🔊</button>"
            
        let htmlBody = """
        \(categoryBarHTML())
        <div class="quiz-progress-bar">
            <div class="quiz-progress-fill" style="width:\(Double(quizIndex + 1) / Double(quizTotal) * 100)%"></div>
        </div>
        <div class="quiz-meta">
            <span>第 \(quizIndex + 1) / \(quizTotal) 题</span>
            <span>得分: \(quizScore)</span>
        </div>
        <div class="word-card">
            <div class="word-row">
                <span class="word-text">\(quiz.word)</span>
                \(phoneticHTML)
                \(audioHTML)
            </div>
            \(exampleHTML)
        </div>
        <div class="quiz-question">选择正确的中文释义</div>
        <div class="quiz-options">
            \(optionsHTML)
        </div>
        <style>
            .quiz-progress-bar { height: 4px; background: rgba(255,255,255,0.08); border-radius: 2px; margin-bottom: 12px; }
            .quiz-progress-fill { height: 100%; background: linear-gradient(90deg, #667eea, #764ba2); border-radius: 2px; transition: width 0.3s; }
            .quiz-meta { display: flex; justify-content: space-between; font-size: 12px; color: #888; margin-bottom: 16px; padding: 0 2px; }
            .word-card { background: rgba(255,255,255,0.04); border-radius: 14px; padding: 18px; margin-bottom: 18px; text-align: center; border: 1px solid rgba(255,255,255,0.06); }
            .word-row { display: flex; align-items: baseline; justify-content: center; gap: 10px; flex-wrap: wrap; }
            .word-text { font-size: 28px; font-weight: 700; color: #a0e8ff; }
            .word-phonetic { font-size: 14px; color: #888; }
            .audio-btn { background: rgba(160,232,255,0.15); border: none; border-radius: 50%; width: 30px; height: 30px; font-size: 16px; cursor: pointer; transition: all 0.2s; }
            .audio-btn:hover { background: rgba(160,232,255,0.3); transform: scale(1.1); }
            .word-example { font-size: 12px; color: #777; font-style: italic; margin-top: 10px; padding-top: 10px; border-top: 1px solid rgba(255,255,255,0.06); }
            .quiz-question { font-size: 14px; color: #aaa; text-align: center; margin-bottom: 14px; }
            .quiz-options { display: flex; flex-direction: column; gap: 10px; }
            .quiz-option { display: flex; align-items: center; gap: 12px; background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; padding: 13px 16px; font-size: 14px; color: #e0e0e8; text-align: left; cursor: pointer; transition: all 0.2s; }
            .quiz-option:hover { background: rgba(160,232,255,0.08); border-color: rgba(160,232,255,0.25); transform: translateX(3px); }
            .option-label { display: inline-flex; align-items: center; justify-content: center; width: 26px; height: 26px; border-radius: 50%; background: rgba(255,255,255,0.08); font-size: 12px; font-weight: 600; color: #aaa; flex-shrink: 0; }
            .option-text { flex: 1; line-height: 1.4; }
            .quiz-option.correct { background: rgba(82,196,26,0.15); border-color: #52c41a; }
            .quiz-option.correct .option-label { background: #52c41a; color: white; }
            .quiz-option.wrong { background: rgba(255,77,79,0.15); border-color: #ff4d4f; }
            .quiz-option.wrong .option-label { background: #ff4d4f; color: white; }
        </style>
        <script>
            function playAudio(word) {
                if (window.webkit && window.webkit.messageHandlers.playAudio) {
                    window.webkit.messageHandlers.playAudio.postMessage(word);
                }
            }
            function selectAnswer(selected, correct) {
                var buttons = document.querySelectorAll('.quiz-option');
                buttons.forEach(function(btn, i) {
                    btn.onclick = null;
                    btn.style.cursor = 'default';
                    if (i === correct) btn.classList.add('correct');
                    if (i === selected && i !== correct) btn.classList.add('wrong');
                });
                setTimeout(function() {
                    if (window.webkit && window.webkit.messageHandlers.nextQuiz) {
                        window.webkit.messageHandlers.nextQuiz.postMessage(selected === correct ? 'correct' : 'wrong');
                    }
                }, 1200);
            }
        </script>
        """
            
        let window = HTMLAlertWindow.showWordLearning(
            title: "背单词 📚",
            htmlBody: htmlBody,
            width: 380,
            onNextQuiz: { [weak self] isCorrect in
                if isCorrect { self?.quizScore += 1 }
                self?.quizIndex += 1
                self?.closeWordLearningWindow()
                self?.fetchAndShowQuiz()
            },
            onSwitchCategory: { [weak self] raw in self?.handleSwitchCategory(raw) }
        )
        wordLearningWindow = window
    }
        
    /// 显示测试结果
    private func showQuizResult() {
        let total = quizTotal
        let percentage = total > 0 ? Int(Double(quizScore) / Double(total) * 100) : 0
            
        var emoji = "🎉"
        var message = "太棒了！"
        if percentage < 60 {
            emoji = "💪"
            message = "继续加油！"
        } else if percentage < 100 {
            emoji = "👍"
            message = "不错哦！"
        }
            
        let htmlBody = """
        \(categoryBarHTML())
        <div class="result-container">
            <div class="result-emoji">\(emoji)</div>
            <div class="result-title">\(message)</div>
            <div class="result-score">
                <span class="score-number">\(quizScore)</span>
                <span class="score-total">/ \(total)</span>
            </div>
            <div class="result-percentage">正确率 \(percentage)%</div>
            <button class="btn-retry" onclick="retryLearning()">再来一次 🔄</button>
        </div>
        <style>
            .result-container { text-align: center; padding: 20px 0; }
            .result-emoji { font-size: 64px; margin-bottom: 16px; }
            .result-title { font-size: 22px; font-weight: 700; color: #f0f0f5; margin-bottom: 20px; }
            .result-score { margin-bottom: 12px; }
            .score-number { font-size: 48px; font-weight: 800; color: #a0e8ff; }
            .score-total { font-size: 20px; color: #888; margin-left: 4px; }
            .result-percentage { font-size: 16px; color: #888; margin-bottom: 24px; }
            .btn-retry { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; border: none; padding: 12px 32px; border-radius: 20px; font-size: 15px; font-weight: 600; cursor: pointer; transition: all 0.2s; }
            .btn-retry:hover { transform: scale(1.05); }
        </style>
        <script>
            function retryLearning() {
                if (window.webkit && window.webkit.messageHandlers.retryLearning) {
                    window.webkit.messageHandlers.retryLearning.postMessage('retry');
                }
            }
        </script>
        """
            
        let window = HTMLAlertWindow.showWordLearning(
            title: "测试结果 🎯",
            htmlBody: htmlBody,
            width: 360,
            onRetryLearning: { [weak self] in
                self?.closeWordLearningWindow()
                self?.startWordLearning()
            },
            onSwitchCategory: { [weak self] raw in self?.handleSwitchCategory(raw) }
        )
        wordLearningWindow = window
    }
    
    @objc private func sleepAction(_ sender: NSMenuItem) {
        if viewModel?.animationState == .sleep {
            viewModel?.wakeUp()
        } else {
            viewModel?.sleep()
        }
    }
    @objc private func quitAction(_ sender: NSMenuItem) { viewModel?.quit() }
    
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 小猫说话对话框（粉色手绘风气泡视图）

/// 仿素材风格的对话气泡：胖圆泡泡 + 左下弯钩尾巴 + 左上→右下粉白渐变 + 釉面高光
/// 优先加载 Resources/SpeechBubble.png 素材整图铺底（自动裁掉底部 AI 水印条，效果与素材 100% 一致）；
/// 素材缺失时回退为贝塞尔矢量手绘。文案居中、自动换行、尺寸自适应。
final class SpeechBubbleView: NSView {
    private let text: String
    /// 文案排版后的实际尺寸（init 时计算，draw 时用于居中）
    private let textSize: NSSize

    /// 文案字体：系统圆体更贴近素材的手绘感
    private static var textFont: NSFont {
        let base = NSFont.systemFont(ofSize: 13, weight: .semibold)
        if let desc = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: desc, size: 13) {
            return rounded
        }
        return base
    }
    /// 配色取自素材：左上近白粉 → 右下暖粉渐变 / 暖棕描边 / 深棕文字
    private static var fillTop: NSColor { NSColor(red: 1.00, green: 0.97, blue: 0.96, alpha: 1) }
    private static var fillBottom: NSColor { NSColor(red: 0.98, green: 0.88, blue: 0.86, alpha: 1) }
    private static var strokeColor: NSColor { NSColor(red: 0.545, green: 0.43, blue: 0.36, alpha: 1) }
    private static var textColor: NSColor { NSColor(red: 0.42, green: 0.31, blue: 0.25, alpha: 1) }

    /// 素材图（可选）：Resources/SpeechBubble.png
    /// 大图（AI 生成原图 ≥800pt 高）自动裁掉底部 8%，去掉右下角「AI 生成」水印徽标
    private static var assetImage: NSImage? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "SpeechBubble", withExtension: "png"),
            Bundle.main.resourceURL?.appendingPathComponent("SpeechBubble.png"),
            // swift build 直跑兑底：源码树 …/DesktopPetForMacApp/Resources/SpeechBubble.png
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/SpeechBubble.png")
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let raw = NSImage(contentsOf: url) else { return nil }
        guard raw.size.height > 800 else { return raw }
        let cropH = floor(raw.size.height * 0.92)
        let cropped = NSImage(size: NSSize(width: raw.size.width, height: cropH))
        cropped.lockFocus()
        raw.draw(in: NSRect(x: 0, y: cropH - raw.size.height, width: raw.size.width, height: raw.size.height),
                 from: .zero, operation: .copy, fraction: 1)
        cropped.unlockFocus()
        return cropped
    }

    /// 排版度量：文案尺寸 + 气泡整体尺寸
    private static func metrics(for text: String) -> (bubbleSize: NSSize, textSize: NSSize) {
        let maxTextWidth: CGFloat = 180
        let bound = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont]
        )
        let ts = NSSize(width: min(max(ceil(bound.width), 40), maxTextWidth),
                        height: max(ceil(bound.height), 18))
        // 素材模式：整图等比铺底，按文案需要的安全区反推整体尺寸（保持素材比例不变形）
        if let img = assetImage, img.size.width > 0 {
            let aspect = img.size.width / img.size.height
            let w = max(ts.width / 0.85, (ts.height / 0.50) * aspect, 190)
            return (NSSize(width: w, height: w / aspect), ts)
        }
        // 矢量模式：胖泡泡（上下留白大于左右）
        let hPadding: CGFloat = 18
        let vPadding: CGFloat = 22
        let tailDrop: CGFloat = 14
        let size = NSSize(width: max(ts.width + hPadding * 2, 110),
                          height: ts.height + vPadding * 2 + tailDrop)
        return (size, ts)
    }

    /// 根据文案计算气泡整体尺寸，供外层窗口定位用
    static func fittingSize(for text: String) -> NSSize { metrics(for: text).bubbleSize }

    init(text: String) {
        self.text = text
        let m = Self.metrics(for: text)
        self.textSize = m.textSize
        super.init(frame: NSRect(origin: .zero, size: m.bubbleSize))
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 8, bounds.height > 8 else { return }

        // ── 素材模式：原图整张铺底（等比），文案叠在泡泡身体中心 ──
        if let img = Self.assetImage {
            img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            drawText(centerY: bounds.height * 0.52, textWidth: bounds.width * 0.90, textX: bounds.width * 0.05)
            return
        }

        // ── 矢量模式：手绘胖泡泡（素材缺失时的兑底）──
        let stroke: CGFloat = 3.5
        let x0 = stroke / 2 + 1
        let x1 = bounds.width - stroke / 2 - 1
        let y0: CGFloat = 14                       // 底部让位给弯钩尾巴
        let y1 = bounds.height - stroke / 2 - 1
        let bw = x1 - x0
        let bh = y1 - y0
        // 胖泡泡：上圆角比下圆角更大（素材是上圆下略平的蛋形）；限宽避免尾巴压进圆角
        let rTop = min(bh * 0.55, bw * 0.24)
        let rBottom = min(bh * 0.38, bw * 0.24)
        let k: CGFloat = 0.5523                    // 贝塞尔近似圆弧系数

        // 尾巴锚点与尖端（弯钩朝左下，带一点外弓）
        let aL = x0 + bw * 0.30
        let aR = x0 + bw * 0.55
        let tipX = x0 + bw * 0.42
        let tipY = bounds.minY + 3

        // 单一闭合轮廓：泡泡主体 + 尾巴一体成形，填充描边无衔接痕
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x0 + rTop, y: y1))                // 顶边左端
        path.line(to: NSPoint(x: x1 - rTop, y: y1))                // 顶边
        path.curve(to: NSPoint(x: x1, y: y1 - rTop),               // 右上大圆角
                   controlPoint1: NSPoint(x: x1 - rTop + k * rTop, y: y1),
                   controlPoint2: NSPoint(x: x1, y: y1 - rTop + k * rTop))
        path.line(to: NSPoint(x: x1, y: y0 + rBottom))             // 右边
        path.curve(to: NSPoint(x: x1 - rBottom, y: y0),            // 右下圆角
                   controlPoint1: NSPoint(x: x1, y: y0 + rBottom - k * rBottom),
                   controlPoint2: NSPoint(x: x1 - rBottom + k * rBottom, y: y0))
        path.line(to: NSPoint(x: aR, y: y0))                       // 底边右段 → 尾巴
        path.curve(to: NSPoint(x: tipX, y: tipY),                  // 尾巴右弧（微内收）
                   controlPoint1: NSPoint(x: aR - 1, y: y0 - 4),
                   controlPoint2: NSPoint(x: tipX + 9, y: tipY + 3))
        path.curve(to: NSPoint(x: aL, y: y0),                      // 尾巴左弧（外弓出弯钩）
                   controlPoint1: NSPoint(x: tipX - 7, y: tipY + 2),
                   controlPoint2: NSPoint(x: aL - 3, y: y0 - 7))
        path.line(to: NSPoint(x: x0 + rBottom, y: y0))             // 底边左段
        path.curve(to: NSPoint(x: x0, y: y0 + rBottom),            // 左下圆角
                   controlPoint1: NSPoint(x: x0 + rBottom - k * rBottom, y: y0),
                   controlPoint2: NSPoint(x: x0, y: y0 + rBottom - k * rBottom))
        path.line(to: NSPoint(x: x0, y: y1 - rTop))                // 左边
        path.curve(to: NSPoint(x: x0 + rTop, y: y1),               // 左上大圆角
                   controlPoint1: NSPoint(x: x0, y: y1 - rTop + k * rTop),
                   controlPoint2: NSPoint(x: x0 + rTop - k * rTop, y: y1))
        path.close()

        // 渐变填充：左上近白 → 右下暖粉
        NSGradient(colors: [Self.fillTop, Self.fillBottom])?.draw(in: path, angle: -60)

        // 暖棕描边
        Self.strokeColor.setStroke()
        path.lineWidth = stroke
        path.stroke()

        // 左上釉面高光：一道斜长弧 + 一枚小圆点（仿素材反光）
        if let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: x0 + bw * 0.24, yBy: y1 - bh * 0.30)
            t.rotate(byDegrees: -32)
            t.concat()
            NSColor.white.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: NSRect(x: -bw * 0.14, y: -6.5, width: bw * 0.28, height: 13)).fill()
            ctx.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: x0 + bw * 0.11, y: y1 - bh * 0.55, width: 11, height: 9)).fill()
        }

        // 文案：泡泡身体垂直居中
        drawText(centerY: (y0 + y1) / 2, textWidth: bw, textX: x0)
    }

    /// 居中绘制文案（自动换行；素材模式 / 矢量模式共用）
    private func drawText(centerY: CGFloat, textWidth: CGFloat, textX: CGFloat = 0) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(string: text, attributes: [
            .font: Self.textFont,
            .foregroundColor: Self.textColor,
            .paragraphStyle: para
        ])
        let rect = NSRect(x: textX, y: centerY - textSize.height / 2, width: textWidth, height: textSize.height)
        attr.draw(in: rect)
    }
}
