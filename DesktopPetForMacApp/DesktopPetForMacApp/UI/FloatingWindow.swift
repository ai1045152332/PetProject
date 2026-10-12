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
        guard let image = currentImage else { return }
        image.draw(in: bounds)
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
            HTMLAlertWindow.show(title: "今日热点新闻", htmlBody: "<div style=\"text-align:center;padding:20px 0;color:#c0c0d0;\">加载失败，请检查网络连接</div>", width: 340)
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
        HTMLAlertWindow.show(title: "今日热点新闻 Top10", htmlBody: htmlBody, width: 480)
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
        
        let petItem = NSMenuItem(title: "抚摸 🐾", action: #selector(petAction(_:)), keyEquivalent: "")
        petItem.target = self
        petItem.isEnabled = true
        menu.addItem(petItem)
        
        let newsItem = NSMenuItem(title: "今日热点新闻 📰", action: #selector(hotNewsAction(_:)), keyEquivalent: "")
        newsItem.target = self
        newsItem.isEnabled = true
        menu.addItem(newsItem)
        
        let weatherItem = NSMenuItem(title: "查询天气 ☀️", action: #selector(weatherAction(_:)), keyEquivalent: "")
        weatherItem.target = self
        weatherItem.isEnabled = true
        menu.addItem(weatherItem)
        
        let locWeatherItem = NSMenuItem(title: "输入地点查天气 🌍", action: #selector(locationWeatherAction(_:)), keyEquivalent: "")
        locWeatherItem.target = self
        locWeatherItem.isEnabled = true
        menu.addItem(locWeatherItem)
        
        let todoItem = NSMenuItem(title: "Todo 清单 📝", action: #selector(todoAction(_:)), keyEquivalent: "")
        todoItem.target = self
        todoItem.isEnabled = true
        menu.addItem(todoItem)
        
        let stockItem = NSMenuItem(title: "输入股票代码查询 📈", action: #selector(stockAction(_:)), keyEquivalent: "")
        stockItem.target = self
        stockItem.isEnabled = true
        menu.addItem(stockItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "关闭 ❌", action: #selector(quitAction(_:)), keyEquivalent: "")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)
        
        // 使用事件中的窗口坐标直接转换到视图坐标，最可靠
        let location = self.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: location, in: self)
    }
    
    @objc private func petAction(_ sender: NSMenuItem) { viewModel?.pet() }
    @objc private func hotNewsAction(_ sender: NSMenuItem) { viewModel?.showHotNews() }
    @objc private func weatherAction(_ sender: NSMenuItem) { fetchWeatherAndShow() }
    @objc private func locationWeatherAction(_ sender: NSMenuItem) { showLocationWeatherInput() }
    @objc private func todoAction(_ sender: NSMenuItem) { showTodoList() }
    @objc private func stockAction(_ sender: NSMenuItem) { showStockInput() }
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
