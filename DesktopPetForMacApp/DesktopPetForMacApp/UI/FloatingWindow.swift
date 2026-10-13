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
        guard stateKey != lastRenderedState || frameIndex != lastRenderedFrameIndex else { return }
        lastRenderedState = stateKey
        lastRenderedFrameIndex = frameIndex

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
            // 点击恢复 focus（从 warn 状态回来）
            viewModel?.transitionTo(.focus)
            
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
    
    /// 显示喝水提醒弹窗（HTML 样式）
    func showDrinkWaterAlert() {
        viewModel?.isWaterAlertShowing = true
        let htmlBody = """
        <div class="water-icon">💧</div>
        <div class="water-text">该喝水啦！</div>
        <div class="water-tips">久坐对身体不好<br>起来倒杯水，活动一下吧～</div>
        """
        HTMLAlertWindow.show(title: "小猫喝水提醒", htmlBody: htmlBody, width: 340) { [weak self] in
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
    
    // MARK: - Weather Display

    private func showWeatherAlert(_ forecast: WeatherForecast) {
        let htmlBody = buildWeatherCardHTML(forecast: forecast)
        HTMLAlertWindow.show(title: "小猫天气预报", htmlBody: htmlBody, width: 380)
    }

    private func showWeatherAlertSimple(_ message: String) {
        let htmlBody = "<div style=\"text-align:center;padding:20px 0;color:#c0c0d0;\">\(message)</div>"
        HTMLAlertWindow.show(title: "小猫天气预报", htmlBody: htmlBody, width: 340)
    }

    private func buildWeatherCardHTML(forecast: WeatherForecast) -> String {
        let hourlyItems = forecast.hourly.prefix(6).map { h in
            """
            <div class="hw-item">
                <div class="hw-time">\(h.time)</div>
                <div class="hw-icon">\(h.icon)</div>
                <div class="hw-temp">\(h.temp)°</div>
            </div>
            """
        }.joined(separator: "\n")

        // 计算全局温度范围用于温度条
        let allTemps = forecast.daily.flatMap { [Int($0.tempMin) ?? 0, Int($0.tempMax) ?? 0] }
        let globalMin = allTemps.min() ?? 0
        let globalMax = allTemps.max() ?? 1
        let globalRange = max(globalMax - globalMin, 1)

        let dailyRows = forecast.daily.map { d in
            let minT = Int(d.tempMin) ?? 0
            let maxT = Int(d.tempMax) ?? 0
            let leftP = Double(minT - globalMin) / Double(globalRange) * 100.0
            let widthP = Double(maxT - minT) / Double(globalRange) * 100.0
            let barColor = maxT >= 30 ? "linear-gradient(90deg, #f6d365, #ff6b6b)" : "linear-gradient(90deg, #4facfe, #00f2fe)"
            return """
            <div class="dw-row">
                <div class="dw-day">\(d.dayName)</div>
                <div class="dw-icon">\(d.icon)</div>
                <div class="dw-min">\(d.tempMin)°</div>
                <div class="dw-bar-track">
                    <div class="dw-bar" style="left:\(String(format: "%.1f", leftP))%;width:\(String(format: "%.1f", widthP))%;background:\(barColor);"></div>
                </div>
                <div class="dw-max">\(d.tempMax)°</div>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <style>
        .w-card { background: linear-gradient(180deg, #5a6a7a 0%, #4a5568 100%); border-radius: 20px; padding: 18px; color: white; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        .w-top { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 16px; }
        .w-loc { font-size: 16px; font-weight: 600; opacity: 0.9; }
        .w-main { display: flex; align-items: center; gap: 12px; }
        .w-temp-big { font-size: 48px; font-weight: 300; line-height: 1; }
        .w-meta { text-align: right; }
        .w-desc { font-size: 16px; margin-bottom: 4px; }
        .w-hl { font-size: 13px; opacity: 0.8; }
        .w-divider { height: 1px; background: rgba(255,255,255,0.15); margin: 12px 0; }
        .w-hourly { display: flex; justify-content: space-between; margin-bottom: 12px; }
        .hw-item { text-align: center; flex: 1; }
        .hw-time { font-size: 11px; opacity: 0.7; margin-bottom: 6px; }
        .hw-icon { font-size: 20px; margin-bottom: 4px; }
        .hw-temp { font-size: 13px; font-weight: 500; }
        .w-daily { display: flex; flex-direction: column; gap: 10px; }
        .dw-row { display: flex; align-items: center; gap: 10px; font-size: 14px; }
        .dw-day { width: 36px; font-weight: 500; }
        .dw-icon { width: 24px; text-align: center; font-size: 18px; }
        .dw-min { width: 30px; text-align: right; opacity: 0.7; font-size: 13px; }
        .dw-max { width: 30px; text-align: left; font-weight: 500; font-size: 13px; }
        .dw-bar-track { flex: 1; height: 4px; background: rgba(255,255,255,0.12); border-radius: 2px; position: relative; }
        .dw-bar { position: absolute; height: 100%; border-radius: 2px; }
        </style>
        <div class="w-card">
            <div class="w-top">
                <div>
                    <div class="w-loc">📍 \(forecast.city)</div>
                    <div class="w-temp-big">\(forecast.nowTemp)°</div>
                </div>
                <div class="w-meta">
                    <div class="w-desc">\(forecast.nowText)</div>
                    <div class="w-hl">最高 \(forecast.todayMax)° 最低 \(forecast.todayMin)°</div>
                </div>
            </div>
            <div class="w-divider"></div>
            <div class="w-hourly">
                \(hourlyItems)
            </div>
            <div class="w-divider"></div>
            <div class="w-daily">
                \(dailyRows)
            </div>
        </div>
        """
    }

    /// 显示输入城市弹窗
    func showLocationWeatherInput() {
        HTMLAlertWindow.showInput(title: "输入城市查天气", placeholder: "如：北京、上海、广州", okLabel: "查询天气 🔍") { [weak self] input in
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            self?.fetchWeatherAndShow(for: trimmed)
        }
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

    /// 双击/右键调用：获取天气并展示（支持指定城市）
    private func fetchWeatherAndShow(for cityInput: String? = nil) {
        let loadingText = cityInput == nil ? "🌤️ 查询天气中..." : "🌤️ 查询 \"\(cityInput!)\" 天气..."
        showLoadingToast(loadingText)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let forecast: WeatherForecast?
            if let input = cityInput {
                forecast = WeatherService.fetchWeatherForecast(forCity: input)
            } else {
                forecast = WeatherService.fetchWeatherForecastWithLocation()
            }
            DispatchQueue.main.async {
                self.hideLoadingToast()
                if let f = forecast {
                    self.showWeatherAlert(f)
                } else {
                    self.showWeatherAlertSimple(cityInput == nil ? "定位失败，无法获取当前位置<br>请使用「输入地点查天气」手动选择城市" : "未找到城市 \"\(cityInput!)\"，请尝试其他名称")
                }
            }
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let fullAccess = AccessControl.isFullAccess

        // 菜单项定义：标题、action、权限等级（fullOnly = 需校验码解锁的高级功能）
        typealias MenuEntry = (title: String, action: Selector, fullOnly: Bool)
        let entries: [MenuEntry] = [
            ("抚摸 🐾", #selector(petAction(_:)), false),
            ("背单词 📚", #selector(wordLearningAction(_:)), true),
            ("今日热点新闻 📰", #selector(hotNewsAction(_:)), true),
            ("查询天气 ☀️", #selector(weatherAction(_:)), true),
            ("输入地点查天气 🌍", #selector(locationWeatherAction(_:)), true),
            ("Todo 清单 📝", #selector(todoAction(_:)), false),
            ("输入股票代码查询 📈", #selector(stockAction(_:)), true),
        ]

        // 按可用状态排序：可用的在前，置灰的在后（解锁后全部可用，保持原顺序）
        let usable = entries.filter { !$0.fullOnly }
        let locked = entries.filter { $0.fullOnly }
        let ordered = fullAccess ? entries : usable + locked

        for (i, entry) in ordered.enumerated() {
            let item = NSMenuItem(title: entry.title, action: entry.action, keyEquivalent: "")
            item.target = self
            item.isEnabled = fullAccess || !entry.fullOnly
            menu.addItem(item)
            // 基础权限下：可用项与置灰项之间插入分隔线
            if !fullAccess && i == usable.count - 1 {
                menu.addItem(NSMenuItem.separator())
            }
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
    @objc private func wordLearningAction(_ sender: NSMenuItem) { viewModel?.startWordLearning() }
    @objc private func hotNewsAction(_ sender: NSMenuItem) { viewModel?.showHotNews() }
    @objc private func weatherAction(_ sender: NSMenuItem) { fetchWeatherAndShow() }
    @objc private func locationWeatherAction(_ sender: NSMenuItem) { showLocationWeatherInput() }
    @objc private func todoAction(_ sender: NSMenuItem) { showTodoList() }
    @objc private func stockAction(_ sender: NSMenuItem) { showStockInput() }
    
    // MARK: - 背单词功能
        
    /// 当前答题序号
    private var quizIndex: Int = 0
    /// 总答题数
    private var quizTotal: Int = 5
    /// 得分
    private var quizScore: Int = 0
    /// 当前背单词弹窗引用
    private var wordLearningWindow: HTMLAlertWindow?
        
    /// 开始背单词：逐题答题模式
    func startWordLearning() {
        let category = WordService.shared.currentCategory
        let words = WordService.shared.getWords(for: category)
            
        guard !words.isEmpty else {
            FileLogger.log("[DesktopPet] 词库为空: \(category.rawValue)")
            let htmlBody = """
            <div style="text-align:center;padding:40px 20px;">
                <div style="font-size:48px;margin-bottom:16px;">📭</div>
                <div style="font-size:18px;font-weight:600;color:#f0f0f5;margin-bottom:12px;">词库为空</div>
                <div style="font-size:14px;color:#888;">请在设置中切换其他分类，或添加单词到词库</div>
            </div>
            """
            wordLearningWindow = HTMLAlertWindow.showWordLearning(title: "背单词 📚", htmlBody: htmlBody, width: 360)
            return
        }
            
        quizIndex = 0
        quizScore = 0
        quizTotal = min(5, words.count)
        fetchAndShowQuiz()
    }
        
    /// 关闭当前背单词弹窗
    private func closeWordLearningWindow() {
        wordLearningWindow?.orderOut(nil)
        wordLearningWindow?.close()
        wordLearningWindow = nil
    }
        
    /// 异步获取单词详情并显示答题界面
    private func fetchAndShowQuiz() {
        guard quizIndex < quizTotal else {
            showQuizResult()
            return
        }
            
        let category = WordService.shared.currentCategory
            
        // 显示加载状态
        let loadingHTML = """
        <div style="text-align:center;padding:60px 20px;">
            <div style="font-size:36px;margin-bottom:16px;animation:spin 1.5s linear infinite;">🔄</div>
            <div style="font-size:15px;color:#888;">正在加载单词...</div>
        </div>
        <style>@keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }</style>
        """
        let loadingWindow = HTMLAlertWindow.showWordLearning(
            title: "背单词 📚",
            htmlBody: loadingHTML,
            width: 380
        )
        wordLearningWindow = loadingWindow
            
        // 使用 Task 异步获取单词 + 生成选择题（避免 semaphore 死锁）
        Task {
            do {
                FileLogger.log("[DesktopPet] 开始获取单词...")
                let words = WordService.shared.getWords(for: category)
                FileLogger.log("[DesktopPet] 词库单词数: \(words.count)")
                
                guard let word = words.shuffled().first else {
                    FileLogger.log("[DesktopPet] 词库为空，无法获取单词")
                    await MainActor.run {
                        self.closeWordLearningWindow()
                        self.showEmptyWordBankError()
                    }
                    return
                }
                
                FileLogger.log("[DesktopPet] 选中单词: \(word.word)，开始生成选择题...")
                let quiz = await DictionaryService.shared.generateQuiz(word: word, category: category)
                FileLogger.log("[DesktopPet] 选择题生成\(quiz != nil ? "成功" : "失败")")
                
                await MainActor.run {
                    self.closeWordLearningWindow()
                    if let q = quiz {
                        self.showQuizCard(quiz: q)
                    } else {
                        // API 失败，跳过此题
                        FileLogger.log("[DesktopPet] 生成选择题失败，跳过: \(word.word)")
                        self.quizIndex += 1
                        self.fetchAndShowQuiz()
                    }
                }
            } catch {
                FileLogger.log("[DesktopPet] 获取单词时发生错误: \(error)")
                await MainActor.run {
                    self.closeWordLearningWindow()
                    self.showEmptyWordBankError()
                }
            }
        }
    }
    
    /// 显示词库为空错误
    private func showEmptyWordBankError() {
        let htmlBody = """
        <div style="text-align:center;padding:40px 20px;">
            <div style="font-size:48px;margin-bottom:16px;">📭</div>
            <div style="font-size:18px;font-weight:600;color:#f0f0f5;margin-bottom:12px;">词库加载失败</div>
            <div style="font-size:14px;color:#888;">请检查资源文件或切换其他分类</div>
        </div>
        """
        wordLearningWindow = HTMLAlertWindow.showWordLearning(title: "背单词 📚", htmlBody: htmlBody, width: 360)
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
            
        // 音频按钮
        let audioHTML: String
        if let audio = quiz.audioURL {
            audioHTML = "<button class=\"audio-btn\" onclick=\"playAudio('\(audio)')\">🔊</button>"
        } else {
            audioHTML = ""
        }
            
        let htmlBody = """
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
            function playAudio(url) {
                var audio = new Audio(url);
                audio.play().catch(function(){});
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
            }
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
            }
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
