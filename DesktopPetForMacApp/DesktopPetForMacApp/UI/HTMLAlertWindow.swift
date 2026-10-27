import AppKit
import WebKit

/// 接受 first mouse 的 WKWebView：
/// App 不在前台时，对窗口的首次点击默认只用于激活 App、不传给网页内容
/// （表现为小游戏窗口不在最前时 ✕ 要点两次）。重写后首次点击直接生效。
class FirstMouseWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 基于 WKWebView 的自定义弹窗窗口（支持自适应高度 + 输入模式）
class HTMLAlertWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private var webView: WKWebView!
    private var onClose: (() -> Void)?
    private var onConfirm: ((String) -> Void)?
    private var closeHandler: CloseMessageHandler?
    private var confirmHandler: ConfirmMessageHandler?
    private var targetWidth: CGFloat = 420
    private var targetMaxHeight: CGFloat = 640
    private var hasSized = false
    private var dragOffset: NSPoint = .zero
    /// 附加业务 CSS（Todo 列表 / 热点新闻表格 / 喝水文案等），经 CardFrame 基类渲染
    private var extraCSS: String = ""
    /// Todo 模式窗口初始高度（按待办数量估算，放大后由 CSS height:100% 撑满）
    private var todoEstimatedHeight: CGFloat?
    
    // MARK: - Todo
    private var onTodoAdd: ((String, Date?) -> Void)?
    private var onTodoDelete: ((String) -> Void)?
    private var todoAddHandler: TodoAddMessageHandler?
    private var todoDeleteHandler: TodoDeleteMessageHandler?
    
    // MARK: - Word Learning
    private var onNextQuiz: ((Bool) -> Void)?
    private var onRetryLearning: (() -> Void)?
    private var nextQuizHandler: WordNextQuizHandler?
    private var retryLearningHandler: WordRetryLearningHandler?
    /// 窗口内切换学习分类（传回 WordCategory.rawValue）
    private var onSwitchCategory: ((String) -> Void)?
    private var switchCategoryHandler: WordSwitchCategoryHandler?
    // 苦练基本功：「换一题」回调
    private var onProblemNext: (() -> Void)?
    private var problemNextHandler: WordRetryLearningHandler?
    /// 好友申请卡的「同意 / 拒绝」回调（卡片常驻，用户做出选择才消失）
    private var onFriendAccept: (() -> Void)?
    private var onFriendReject: (() -> Void)?
    private var friendAcceptHandler: FriendDecisionHandler?
    private var friendRejectHandler: FriendDecisionHandler?
    private var playAudioHandler: WordPlayAudioHandler?
    private var isWordLearningMode = false
    /// 天气查询回调（城市输入后传回）
    var onCityQuery: ((String) -> Void)?

    /// 单击宠物时是否把本窗口一并提到最前。
    /// Todo 这类可长期常驻的工具窗关掉它，避免每次点宠物都把清单拽回脸上。
    var raisesOnPetClick = true

    // MARK: - 天气窗口追踪
    /// 当前天气查询窗口引用（用于在同一窗口内更新内容）
    private static weak var currentWeatherWindow: HTMLAlertWindow?
    /// 当前 Todo 窗口引用（单例守卫：已打开且可见时只置顶复用，杜绝连续打开多个）
    private static weak var currentTodoWindow: HTMLAlertWindow?
    /// 当前到期 Todo 提醒卡引用（同一时刻只保留一张，避免重复弹堆叠）
    private static weak var currentTodoReminderWindow: HTMLAlertWindow?
    /// 当前好友消息卡引用（只显示最新一条，不堆叠）
    private static weak var currentFriendMessageWindow: HTMLAlertWindow?
    /// 当前好友申请卡引用（同一时刻只保留一张，避免堆叠）
    private static weak var currentFriendRequestWindow: HTMLAlertWindow?
    /// 页面是否已加载完成（didFinish 后置 true，之前到达的内容暂存）
    private var isPageLoaded = false
    /// 页面加载完成前到达的天气内容（JS 字符串字面量，待刷新）
    private var pendingWeatherLiteral: String?

    /// 在输入框下方展示加载提示
    static func showWeatherLoading(_ text: String) {
        updateWeatherContent("<div style=\"text-align:center;padding:26px 10px;color:#8a90b8;font-size:14px;line-height:1.8;\">\(text)</div>")
    }

    /// 展示错误/提示信息
    static func showWeatherMessage(_ html: String) {
        updateWeatherContent("<div style=\"text-align:center;padding:26px 10px;color:#c0c0d0;font-size:14px;line-height:1.8;\">\(html)</div>")
    }

    /// 渲染天气卡片
    static func renderWeatherCard(_ forecast: WeatherForecast) {
        updateWeatherContent(buildWeatherCardHTML(forecast: forecast))
    }

    /// 独立弹出一张天气卡片（每日天气提醒用，不需要输入框）
    static func showWeatherCard(_ forecast: WeatherForecast, title: String = "今日天气") {
        show(title: title, htmlBody: buildWeatherCardHTML(forecast: forecast), width: 380, maxHeight: 640)
    }

    /// 更新当前天气窗口的天气内容（保留上方输入框）
    static func updateWeatherContent(_ html: String) {
        currentWeatherWindow?.updateWeatherHTML(html)
    }

    /// 通过 JS 更新 #weatherContent 区域，并让窗口高度自适应新内容
    func updateWeatherHTML(_ html: String) {
        // 用 JSONSerialization 安全转义为带引号的 JS 字符串字面量
        guard let data = try? JSONSerialization.data(withJSONObject: [html], options: []),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        // jsonStr == ["<escaped>"]，剥掉外层 [ ] 得到 "<escaped>"（合法 JS 字符串字面量）
        let literal = String(jsonStr.dropFirst().dropLast())
        guard isPageLoaded else {
            pendingWeatherLiteral = literal
            return
        }
        applyWeatherLiteral(literal)
    }

    /// 注入内容后重新测量并调整窗口高度（保持顶边位置不变）
    private func applyWeatherLiteral(_ literal: String) {
        guard let webView = webView else { return }
        let js = """
        (function() {
            var el = document.getElementById('weatherContent');
            if (el) { el.innerHTML = \(literal); }
            var c = document.querySelector('.card');
            if (c) { c.style.height = 'auto'; }
            var h = document.documentElement.scrollHeight;
            if (c) { c.style.height = ''; }
            return h;
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            let contentHeight: CGFloat
            if let h = result as? CGFloat { contentHeight = h }
            else if let h = result as? NSNumber { contentHeight = CGFloat(h.doubleValue) }
            else { return }
            let maxH = min(self.targetMaxHeight, (NSScreen.main?.visibleFrame.height ?? 800) * 0.75)
            let targetH = max(200, min(contentHeight + 24, maxH))
            var frame = self.frame
            let top = frame.maxY
            frame.size.height = targetH
            frame.origin.y = top - targetH
            self.setFrame(frame, display: true)
        }
    }


    /// 显示 HTML 弹窗（高度自适应内容）
    static func show(title: String, htmlBody: String, width: CGFloat = 420, maxHeight: CGFloat = 640, onClose: (() -> Void)? = nil) {
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.targetWidth = width
        window.targetMaxHeight = maxHeight
        window.onClose = onClose
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - 常驻通知卡（到期 Todo / 好友消息）
    // 与会自动淡出的气泡不同：这里用标准 borderless 弹窗（自带原生拖动条 + ✕），
    // 弹出后常驻，必须用户点 ✕ 才消失；同类通知复用同一窗口，避免堆叠。

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 到期 Todo 提醒：弹一张常驻卡片，用户点 ✕ 前不消失
    static func showTodoReminder(body: String, subtitle: String) {
        if let existing = currentTodoReminderWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }
        let subLine = subtitle.isEmpty ? "" : "\n        <div class=\"water-tips\">\(htmlEscape(subtitle))</div>"
        let htmlBody = """
        <div class="water-icon">⏰</div>
        <div class="water-text" style="font-size:17px;color:#f0f0f5;white-space:pre-wrap;">\(htmlEscape(body))</div>
        <div class="water-tips">到点啦，别忘了～\(subLine)</div>
        """
        let window = presentNotice(title: "Todo 提醒 ⏰", width: 340, htmlBody: htmlBody)
        window.onClose = { if HTMLAlertWindow.currentTodoReminderWindow === window { HTMLAlertWindow.currentTodoReminderWindow = nil } }
        currentTodoReminderWindow = window
    }

    /// 好友消息：弹一张常驻卡片，用户点 ✕ 前不消失；关闭时把消息 ID 上报服务端确认已读
    static func showFriendMessage(body: String, ids: [String] = []) {
        // 已有未关闭的消息卡：先静默关掉（不标记已读），保证只显示最新一条、不堆叠
        // 被顶掉的那条用户其实没看过，故清掉 onClose 避免误确认；服务端稍后会重投
        if let old = currentFriendMessageWindow {
            old.onClose = nil
            old.closeWindow()
        }
        let htmlBody = """
        <div class="water-icon">💬</div>
        <div class="water-text" style="font-size:15px;color:#f0f0f5;white-space:pre-wrap;line-height:1.7;">\(htmlEscape(body))</div>
        <div class="water-tips">好友的留言，看完点 ✕ 关闭（关闭后对方能看到已读）</div>
        """
        let window = presentNotice(title: "好友消息 💬", width: 360, htmlBody: htmlBody)
        window.onClose = {
            if HTMLAlertWindow.currentFriendMessageWindow === window { HTMLAlertWindow.currentFriendMessageWindow = nil }
            guard !ids.isEmpty else { return }
            Task { await FriendService.confirmRead(ids: ids) }
        }
        currentFriendMessageWindow = window
    }

    /// 好友申请：弹一张常驻卡片，由用户点「同意 ✅ / 拒绝 ✕」后才消失（同意后双方互为好友）
    static func showFriendRequest(display: String, onAccept: @escaping () -> Void, onReject: @escaping () -> Void) {
        if let existing = currentFriendRequestWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }
        let htmlBody = """
        <div class="water-icon">🐾</div>
        <div class="water-text" style="font-size:15px;color:#f0f0f5;white-space:pre-wrap;line-height:1.7;">\(htmlEscape(display)) 想加你为好友</div>
        <div style="display:flex;gap:10px;margin-top:14px;">
            <button type="button" style="flex:1;padding:9px 0;border-radius:18px;border:1px solid rgba(47,179,110,.5);background:rgba(47,179,110,.18);color:#7de2b0;font-size:14px;cursor:pointer;" onclick="window.webkit.messageHandlers.acceptFriend.postMessage('')">同意 ✅</button>
            <button type="button" style="flex:1;padding:9px 0;border-radius:18px;border:1px solid rgba(255,255,255,.14);background:rgba(255,255,255,.06);color:#c0c0d0;font-size:14px;cursor:pointer;" onclick="window.webkit.messageHandlers.rejectFriend.postMessage('')">拒绝 ✕</button>
        </div>
        <div class="water-tips" style="margin-top:10px;">同意后你们互为好友，TA 才能给你发消息</div>
        """
        let window = presentNotice(title: "好友申请 🐾", width: 340, htmlBody: htmlBody, isFriendRequestMode: true)
        window.onClose = { if HTMLAlertWindow.currentFriendRequestWindow === window { HTMLAlertWindow.currentFriendRequestWindow = nil } }
        window.onFriendAccept = onAccept
        window.onFriendReject = onReject
        currentFriendRequestWindow = window
    }

    /// 创建并弹出一张常驻通知窗（borderless + 非可缩放 → didFinish 会自动挂原生拖动条，可拖）
    private static func presentNotice(title: String, width: CGFloat, htmlBody: String, isFriendRequestMode: Bool = false) -> HTMLAlertWindow {
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.hasShadow = false
        window.targetWidth = width
        window.targetMaxHeight = 420
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isFriendRequestMode: isFriendRequestMode)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return window
    }

    /// 显示带输入框的弹窗
    static func showInput(title: String, placeholder: String = "请输入...", okLabel: String = "查询天气 🔍", extraHTML: String = "", width: CGFloat = 360, onConfirm: @escaping (String) -> Void, onClose: (() -> Void)? = nil) {
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.targetWidth = width
        window.targetMaxHeight = 400
        window.onConfirm = onConfirm
        window.onClose = onClose
        let htmlBody = """
        <div class="input-group">
            <input type="text" id="locationInput" placeholder="\(placeholder)" autofocus />
        </div>
        \(extraHTML)
        """
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: true, okLabel: okLabel)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// 显示天气查询弹窗：窗口内输入城市 → 展示天气（同一窗口切换内容）
    static func showWeatherInput(title: String, width: CGFloat = 380, maxHeight: CGFloat = 640, onQuery: @escaping (String) -> Void, onClose: (() -> Void)? = nil) {
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.targetWidth = width
        window.targetMaxHeight = maxHeight
        window.onClose = onClose

        let htmlBody = """
        <div class="input-group">
            <input type="text" id="locationInput" placeholder="输入城市名查询，如：北京、上海" autofocus />
        </div>
        <div id="weatherContent">
            <div style="text-align:center;padding:26px 10px;color:#8a90b8;font-size:14px;line-height:1.8;">🌤️ 正在加载本地天气...</div>
        </div>
        <script>
        (function() {
            var i = document.getElementById('locationInput');
            if (i) {
                i.addEventListener('keypress', function(e) {
                    if (e.key === 'Enter') { window.webkit.messageHandlers.confirm.postMessage(i.value); }
                });
            }
        })();
        </script>
        """
        window.setupWebView(
            title: title,
            htmlBody: htmlBody,
            isInputMode: true,
            okLabel: "查询天气 🔍",
            onCityQuery: onQuery
        )
        currentWeatherWindow = window
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - 天气卡片（与 FloatingWindow.buildWeatherCardHTML 同版本）

    /// 天气描述 → emoji 映射（临时副本，避免依赖 FloatingWindow）
    private static func weatherEmoji(for text: String) -> String {
        if text.contains("晴") { return "☀️" }
        if text.contains("多云") { return "⛅" }
        if text.contains("阴") { return "☁️" }
        if text.contains("雨") { return "🌧️" }
        if text.contains("雪") { return "❄️" }
        if text.contains("雷") { return "⛈️" }
        if text.contains("雾") || text.contains("霾") { return "🌫️" }
        return "🌤️"
    }

    /// 格式化 ISO 时间为中文小时
    private static func formatHour(_ isoTime: String) -> String {
        let parts = isoTime.split(separator: "T")
        guard parts.count == 2 else { return isoTime }
        let timePart = String(parts[1])
        let hourParts = timePart.split(separator: ":")
        guard let hour = hourParts.first else { return isoTime }
        return "\(hour)时"
    }

    /// 构建天气卡片 HTML（返回含 <style> 的完整片段）
    fileprivate static func buildWeatherCardHTML(forecast: WeatherForecast) -> String {
        let hourlyItems = forecast.hourly.prefix(6).map { h in
            """
            <div class="hw-item">
                <div class="hw-time">\(h.time)</div>
                <div class="hw-icon">\(h.icon)</div>
                <div class="hw-temp">\(h.temp)°</div>
            </div>
            """
        }.joined(separator: "\n")

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

    // MARK: - 共享业务 CSS（附加到边框基类，供各弹窗内容使用）

    /// 业务内容样式：热点新闻表格、喝水文案、输入框、Todo 列表等（与边框基类分离）
    private static let sharedBusinessCSS = """
        .news-table {
            width: 100%;
            border-collapse: collapse;
            border-radius: 12px;
            overflow: hidden;
            background: rgba(255,255,255,0.03);
            border: 1px solid rgba(255,255,255,0.06);
        }
        .news-table thead th {
            background: linear-gradient(135deg, rgba(102,126,234,0.3) 0%, rgba(118,75,162,0.3) 100%);
            color: #a5b4fc;
            font-size: 12px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            padding: 10px 12px;
            text-align: left;
        }
        .news-table tbody td {
            padding: 10px 12px;
            font-size: 13px;
            color: #e0e0e8;
            border-top: 1px solid rgba(255,255,255,0.04);
            vertical-align: top;
        }
        .news-table tbody tr:first-child td { border-top: none; }
        .news-rank {
            display: inline-block;
            width: 24px;
            height: 24px;
            line-height: 24px;
            text-align: center;
            border-radius: 8px;
            background: rgba(102, 126, 234, 0.25);
            color: #a5b4fc;
            font-size: 12px;
            font-weight: 600;
        }
        .news-link {
            color: #c0c0d0;
            text-decoration: none;
            transition: color 0.2s;
            line-height: 1.5;
            cursor: pointer;
        }
        .news-link:hover { color: #a5b4fc; text-decoration: underline; }
        .water-icon { text-align: center; font-size: 48px; margin: 8px 0; }
        .water-text { text-align: center; font-size: 15px; color: #c0c0d0; margin-bottom: 8px; font-weight: 500; }
        .water-tips { text-align: center; font-size: 13px; color: #8888a0; line-height: 1.7; }
        .input-group { padding: 8px 0; }
        .input-group label {
            display: block;
            font-size: 12px;
            color: #8888a0;
            margin-bottom: 8px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        .input-group input {
            width: 100%;
            background: rgba(255,255,255,0.06);
            border: 1px solid rgba(255,255,255,0.1);
            border-radius: 10px;
            padding: 12px 14px;
            color: #f0f0f5;
            font-size: 15px;
            outline: none;
            transition: all 0.2s;
            font-family: inherit;
        }
        .input-group input:focus {
            border-color: rgba(102, 126, 234, 0.6);
            background: rgba(255,255,255,0.08);
        }
        .input-group input::placeholder { color: #666680; }
        .todo-input-group { display: flex; gap: 8px; margin-bottom: 14px; }
        .todo-input-group input {
            flex: 1;
            background: rgba(255,255,255,0.07);
            border: 1px solid rgba(255,255,255,0.12);
            border-radius: 10px;
            padding: 10px 12px;
            color: #f0f0f5;
            font-size: 14px;
            outline: none;
            font-family: inherit;
            transition: all 0.2s;
        }
        .todo-input-group input:focus {
            border-color: rgba(102, 126, 234, 0.6);
            background: rgba(255,255,255,0.08);
        }
        .todo-input-group button {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            border: none;
            color: white;
            width: 36px;
            height: 36px;
            border-radius: 10px;
            font-size: 18px;
            cursor: pointer;
            flex-shrink: 0;
            transition: all 0.2s;
        }
        .todo-input-group button:hover { opacity: 0.92; transform: translateY(-1px); }
        .todo-due-input {
            flex-shrink: 0;
            width: 150px;
            background: rgba(255,255,255,0.07);
            border: 1px solid rgba(255,255,255,0.12);
            border-radius: 10px;
            padding: 0 10px;
            color: #c8cce8;
            font-size: 12px;
            outline: none;
            font-family: inherit;
            color-scheme: dark;
            transition: all 0.2s;
        }
        .todo-due-input:focus { border-color: rgba(102, 126, 234, 0.6); background: rgba(255,255,255,0.08); }
        .todo-hint { font-size: 11px; color: #666680; margin: -6px 0 12px 2px; }
        .todo-list { display: flex; flex-direction: column; gap: 6px; }
        .todo-empty { text-align: center; color: #666680; font-size: 13px; padding: 20px 0; }
        .todo-item {
            display: flex;
            align-items: center;
            gap: 10px;
            padding: 10px 12px;
            background: rgba(255,255,255,0.06);
            border-radius: 10px;
            cursor: pointer;
            transition: all 0.2s;
            border: 1px solid rgba(255,255,255,0.07);
        }
        .todo-item:hover {
            background: rgba(255,255,255,0.08);
            border-color: rgba(255,100,100,0.3);
        }
        .todo-item:hover .todo-delete { opacity: 1; }
        .todo-item-confirm {
            background: rgba(255,80,80,0.12) !important;
            border-color: rgba(255,80,80,0.5) !important;
            animation: pulse 1s infinite;
        }
        @keyframes pulse {
            0%, 100% { box-shadow: 0 0 0 0 rgba(255,80,80,0.3); }
            50% { box-shadow: 0 0 8px 2px rgba(255,80,80,0.2); }
        }
        .todo-dot { color: #667eea; font-size: 8px; flex-shrink: 0; }
        .todo-text { flex: 1; font-size: 14px; color: #e0e0e8; word-break: break-all; }
        .todo-delete {
            color: #ff6b6b;
            font-size: 12px;
            opacity: 0.4;
            transition: opacity 0.2s;
            flex-shrink: 0;
        }
        .todo-chip {
            font-size: 11px;
            color: #a0a8e0;
            background: rgba(102,126,234,0.16);
            border: 1px solid rgba(102,126,234,0.28);
            padding: 3px 8px;
            border-radius: 10px;
            flex-shrink: 0;
            white-space: nowrap;
        }
        .todo-chip-overdue {
            color: #ff9a9a;
            background: rgba(255,80,80,0.14);
            border-color: rgba(255,80,80,0.4);
        }
        .todo-item-overdue { border-color: rgba(255,80,80,0.32); }
    """

    /// Todo 窗口目标高度：空态就偏大，随待办逐条增高，上限接近整屏（不遮挡）。
    /// 返回的是最终窗口高度（含标题栏与内边距）。
    static func todoFinalHeight(count: Int) -> CGFloat {
        let screenH = NSScreen.main?.visibleFrame.height ?? 900
        let cap = screenH * 0.72
        let ideal = 560 + CGFloat(count) * 52
        return max(420, min(ideal, cap))
    }

    /// 显示 Todo 清单弹窗
    static func showTodo(title: String, todos: [TodoItem], width: CGFloat = 440, maxHeight: CGFloat = 640, onAdd: @escaping (String, Date?) -> Void, onDelete: @escaping (String) -> Void, onClose: (() -> Void)? = nil) {
        // 单例守卫：已有可见的 Todo 窗口时只置顶复用，不再新建（修复“连续打开两个”）
        if let existing = currentTodoWindow, existing.isVisible {
            existing.refreshTodoList()
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }
        // Todo 用无边框圆角卡片（与天气/新闻弹窗一致）：渐变标题栏 + ✕ 关闭 + 边缘拖拽缩放，
        // 去掉之前的系统标题栏外边框与红绿灯，风格与其它弹窗统一
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.hasShadow = false  // 去阴影
        window.title = title
        // 强制深色外观：与卡片深色底同色调
        window.appearance = NSAppearance(named: .darkAqua)
        // 常驻工具窗：不随点击宠物被强制拉到最前
        window.raisesOnPetClick = false
        // Todo 现在是 borderless：无系统标题栏可拖，页面渲染后 styleMask 会加入 .resizable，
        // didFinish 里的原生拖动条分支会被跳过（与天气窗同病），靠 background 拖动从卡片空白处移动；
        // 输入框/按钮仍可正常点击。
        window.isMovableByWindowBackground = true
        window.targetWidth = width
        // Todo 允许随待办增多而长高（上限接近整屏），不再锁死在 maxHeight=640
        window.targetMaxHeight = NSScreen.main?.visibleFrame.height ?? 900
        // 初始高度按待办数量估算（空态即偏大，逐条增高）；didFinish 会 +24 还原为最终高度
        window.todoEstimatedHeight = HTMLAlertWindow.todoFinalHeight(count: todos.count) - 24
        window.onTodoAdd = onAdd
        window.onTodoDelete = onDelete
        window.onClose = onClose
        
        let todosJSON: String
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970  // dueDate 以 epoch 秒输出，JS 直接 new Date(due*1000)
        if let data = try? encoder.encode(todos),
           let json = String(data: data, encoding: .utf8) {
            // 防止待办文本含 "</script>" 提前闭合 script 标签（XSS/页面破坏）
            todosJSON = json.replacingOccurrences(of: "<", with: "\\u003c")
        } else {
            todosJSON = "[]"
        }
        
        let htmlBody = """
        <div class="todo-input-group">
            <input type="text" id="todoInput" placeholder="记下要做的事，回车添加…" />
            <button id="remindBtn" type="button">🕐 无提醒</button>
            <button id="addBtn" type="button">➕</button>
        </div>
        <div class="todo-hint">默认只是随手记；需要到点提醒时点「🕐」设个时间</div>
        <div id="duePicker" class="due-picker">
            <div class="dp-quick">
                <span class="dp-chip" data-q="15m">15分钟后</span>
                <span class="dp-chip" data-q="30m">30分钟后</span>
                <span class="dp-chip" data-q="1h">1小时后</span>
                <span class="dp-chip" data-q="tonight">今晚8点</span>
                <span class="dp-chip" data-q="tom9">明早9点</span>
            </div>
            <div class="dp-custom">
                <select id="dpDate" class="dp-select"></select>
                <select id="dpHour" class="dp-select"></select>
                <select id="dpMin" class="dp-select"></select>
            </div>
            <div class="dp-preview" id="dpPreview"></div>
            <div class="dp-actions">
                <button id="dpClear" type="button">清除提醒</button>
                <button id="dpOk" type="button">确定</button>
            </div>
        </div>
        <div class="todo-list" id="todoList"></div>
        <style>
            #remindBtn {
                width: auto !important; padding: 0 12px !important; font-size: 13px !important;
                background: rgba(255,255,255,0.08) !important; border: 1px solid rgba(255,255,255,0.16) !important;
                color: #c8cce8 !important; white-space: nowrap;
            }
            #remindBtn:hover { opacity: 1 !important; transform: none !important; background: rgba(255,255,255,0.12) !important; }
            #remindBtn.remind-on { background: linear-gradient(135deg,#667eea,#764ba2) !important; color: #fff !important; border-color: transparent !important; }
            .due-picker { display: none; margin: -4px 0 14px; padding: 12px; background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; }
            .dp-quick { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 10px; }
            .dp-custom { display: flex; gap: 8px; }
            .dp-select { flex: 1; min-width: 0; font-family: inherit; font-size: 13px; padding: 7px 8px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.16); background: rgba(255,255,255,0.06); color: #e8eaf6; }
            .dp-preview { font-size: 12px; color: #a9b0d8; margin-top: 9px; }
            .dp-chip { font-size: 12px; color: #c8cce8; background: rgba(255,255,255,0.07); border: 1px solid rgba(255,255,255,0.12); padding: 5px 10px; border-radius: 8px; cursor: pointer; transition: all 0.15s; }
            .dp-chip:hover { background: rgba(255,255,255,0.12); }
            .dp-chip.dp-on { background: linear-gradient(135deg,#667eea,#764ba2); color: #fff; border-color: transparent; }
            .dp-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 12px; }
            .dp-actions button { border: none; border-radius: 9px; padding: 7px 16px; font-size: 13px; cursor: pointer; font-family: inherit; }
            #dpClear { background: transparent; color: #9098b8; }
            #dpClear:hover { color: #ff8a8a; }
            #dpOk { background: linear-gradient(135deg,#667eea,#764ba2); color: #fff; }
        </style>
        <script>
            var todos = \(todosJSON);
            var pendingDeleteId = null;
            var pendingDue = null;                        // 待添加待办的提醒时间（epoch 秒），null=不提醒
            var pickDay = 0, pickHour = 9, pickMin = 0;   // 弹层内临时选择
            var WD = ['周日','周一','周二','周三','周四','周五','周六'];
            function pad(n){ return (n < 10 ? '0' : '') + n; }
            function fmtDue(sec){
                if (!sec) return '';
                var d = new Date(sec * 1000);
                var now = new Date();
                var hm = pad(d.getHours()) + ':' + pad(d.getMinutes());
                if (d.toDateString() === now.toDateString()) return '今天 ' + hm;
                var tomorrow = new Date(now); tomorrow.setDate(now.getDate() + 1);
                if (d.toDateString() === tomorrow.toDateString()) return '明天 ' + hm;
                return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + hm;
            }
            function isOverdue(sec){ return sec && (sec * 1000) < Date.now(); }
            function dayLabel(off){
                if (off === 0) return '今天';
                if (off === 1) return '明天';
                if (off === 2) return '后天';
                var d = new Date(); d.setDate(d.getDate() + off);
                return WD[d.getDay()];
            }
            function renderTodos() {
                var list = document.getElementById('todoList');
                list.innerHTML = '';
                if (todos.length === 0) {
                    list.innerHTML = '<div class="todo-empty">暂无待办事项 🎉</div>';
                    return;
                }
                // 有到期时间的按时间升序排在前（逾期自然置顶），无时间的保持原序在后
                var sorted = todos.slice().sort(function(a, b){
                    var ad = a.dueDate || Infinity, bd = b.dueDate || Infinity;
                    return ad - bd;
                });
                for (var i = 0; i < sorted.length; i++) {
                    var t = sorted[i];
                    var isPending = t.id === pendingDeleteId;
                    var overdue = isOverdue(t.dueDate);
                    var item = document.createElement('div');
                    var cls = 'todo-item';
                    if (isPending) cls += ' todo-item-confirm';
                    else if (overdue) cls += ' todo-item-overdue';
                    item.className = cls;

                    var dot = document.createElement('span');
                    dot.className = 'todo-dot';
                    dot.textContent = isPending ? '⚠️' : (overdue ? '🔴' : '●');
                    dot.style.cursor = 'pointer';
                    dot.onclick = (function(x){ return function(){ copyTodo(x); }; })(t.text);

                    var txt = document.createElement('span');
                    txt.className = 'todo-text';
                    txt.textContent = isPending ? '再次点击确认删除' : t.text;
                    txt.style.cursor = 'pointer';
                    txt.onclick = (function(x){ return function(){ copyTodo(x); }; })(t.text);

                    if (t.dueDate) {
                        var chip = document.createElement('span');
                        chip.className = 'todo-chip' + (overdue ? ' todo-chip-overdue' : '');
                        chip.textContent = (overdue ? '⏰ 已逾期 · ' : '⏰ ') + fmtDue(t.dueDate);
                        item.appendChild(chip);
                    }

                    var del = document.createElement('span');
                    del.className = 'todo-delete';
                    del.textContent = isPending ? '删除' : '✕';
                    del.onclick = (function(id){ return function(){ deleteTodo(id); }; })(t.id);

                    item.appendChild(dot);
                    item.appendChild(txt);
                    item.appendChild(del);
                    list.appendChild(item);
                }
            }
            function updateRemindChip(){
                var btn = document.getElementById('remindBtn');
                if (pendingDue) { btn.textContent = '⏰ ' + fmtDue(pendingDue); btn.classList.add('remind-on'); }
                else { btn.textContent = '🕐 无提醒'; btn.classList.remove('remind-on'); }
            }
            function renderPicker(){
                var dd = document.getElementById('dpDate'); dd.innerHTML = '';
                for (var i = 0; i < 7; i++) {
                    var o = document.createElement('option'); o.value = i; o.textContent = dayLabel(i);
                    if (pickDay === i) o.selected = true; dd.appendChild(o);
                }
                var hh = document.getElementById('dpHour'); hh.innerHTML = '';
                for (var h = 0; h < 24; h++) {
                    var o = document.createElement('option'); o.value = h; o.textContent = pad(h) + '点';
                    if (pickHour === h) o.selected = true; hh.appendChild(o);
                }
                var mm = document.getElementById('dpMin'); mm.innerHTML = '';
                for (var mn = 0; mn < 60; mn++) {
                    var o = document.createElement('option'); o.value = mn; o.textContent = pad(mn) + '分';
                    if (pickMin === mn) o.selected = true; mm.appendChild(o);
                }
                updatePreview();
            }
            function updatePreview(){
                var d = new Date(); d.setDate(d.getDate() + pickDay); d.setHours(pickHour, pickMin, 0, 0);
                var el = document.getElementById('dpPreview');
                if (el) el.textContent = '将于 ' + fmtDue(d.getTime() / 1000) + ' 提醒';
            }
            function togglePicker(open){
                var p = document.getElementById('duePicker');
                var willOpen = (open === undefined) ? (p.style.display !== 'block') : open;
                if (willOpen) { renderPicker(); p.style.display = 'block'; }
                else { p.style.display = 'none'; }
            }
            function confirmPicker(){
                var d = new Date();
                d.setDate(d.getDate() + pickDay);
                d.setHours(pickHour, pickMin, 0, 0);
                pendingDue = d.getTime() / 1000;
                updateRemindChip();
                togglePicker(false);
            }
            function quickSet(kind){
                var d = new Date();
                if (kind === '15m') { d.setMinutes(d.getMinutes() + 15); }
                else if (kind === '30m') { d.setMinutes(d.getMinutes() + 30); }
                else if (kind === '1h') { d.setHours(d.getHours() + 1); }
                else if (kind === 'tonight') { d.setHours(20, 0, 0, 0); }
                else if (kind === 'tom9') { d.setDate(d.getDate() + 1); d.setHours(9, 0, 0, 0); }
                pendingDue = d.getTime() / 1000;
                updateRemindChip();
                togglePicker(false);
            }
            function clearReminder(){ pendingDue = null; updateRemindChip(); togglePicker(false); }
            function addTodo() {
                var input = document.getElementById('todoInput');
                var text = input.value.trim();
                if (!text) { return; }
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.addTodo) {
                    window.webkit.messageHandlers.addTodo.postMessage(JSON.stringify({ text: text, due: pendingDue }));
                    input.value = '';
                    pendingDue = null;
                    updateRemindChip();
                    togglePicker(false);
                }
            }
            function deleteTodo(id) {
                if (pendingDeleteId === id) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.deleteTodo) {
                        window.webkit.messageHandlers.deleteTodo.postMessage(id);
                    }
                    pendingDeleteId = null;
                } else {
                    pendingDeleteId = id;
                    renderTodos();
                }
            }
            function copyTodo(text) {
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(text).then(showCopyTip).catch(function(){});
                } else {
                    var ta = document.createElement('textarea');
                    ta.value = text;
                    ta.style.cssText = 'position:fixed;top:-9999px;left:-9999px;opacity:0;';
                    document.body.appendChild(ta);
                    ta.select();
                    try { document.execCommand('copy'); } catch(e) {}
                    document.body.removeChild(ta);
                    showCopyTip();
                }
            }
            function showCopyTip() {
                var tip = document.getElementById('copyTip');
                if (!tip) {
                    tip = document.createElement('div');
                    tip.id = 'copyTip';
                    tip.style.cssText = 'position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);background:rgba(0,0,0,0.7);color:#fff;padding:8px 16px;border-radius:8px;font-size:13px;z-index:9999;opacity:0;transition:opacity 0.3s;pointer-events:none;';
                    document.body.appendChild(tip);
                }
                tip.textContent = '已复制';
                tip.style.opacity = '1';
                setTimeout(function(){ tip.style.opacity = '0'; }, 1000);
            }
            document.getElementById('addBtn').addEventListener('click', addTodo);
            document.getElementById('remindBtn').addEventListener('click', function(){ togglePicker(); });
            document.getElementById('dpOk').addEventListener('click', confirmPicker);
            document.getElementById('dpClear').addEventListener('click', clearReminder);
            document.querySelector('.dp-quick').addEventListener('click', function(e){
                var t = e.target.closest('.dp-chip'); if (t && t.getAttribute('data-q')) quickSet(t.getAttribute('data-q'));
            });
            document.getElementById('dpDate').addEventListener('change', function(e){ pickDay = parseInt(e.target.value, 10); updatePreview(); });
            document.getElementById('dpHour').addEventListener('change', function(e){ pickHour = parseInt(e.target.value, 10); updatePreview(); });
            document.getElementById('dpMin').addEventListener('change', function(e){ pickMin = parseInt(e.target.value, 10); updatePreview(); });
            document.getElementById('todoInput').addEventListener('keypress', function(e) {
                if (e.key === 'Enter') addTodo();
            });
            document.getElementById('todoInput').addEventListener('focus', function() {
                pendingDeleteId = null;
                renderTodos();
                togglePicker(false);
            });
            renderTodos();
            updateRemindChip();
        </script>
        """
        
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isTodoMode: true)
        currentTodoWindow = window
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// 显示可缩放窗口（热点新闻等）：复用背单词边框基类，无系统标题栏外边框（borderless），
    /// 保留边缘拖拽缩放（resizable），与背单词弹窗形式完全一致
    static func showResizable(title: String, htmlBody: String, width: CGFloat = 480, maxHeight: CGFloat = 640, hideCloseButton: Bool = false, onClose: (() -> Void)? = nil) {
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.hasShadow = false  // 去阴影
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.targetWidth = width
        window.targetMaxHeight = maxHeight
        window.onClose = onClose
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isTodoMode: false, hideCloseButton: hideCloseButton)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// 显示背单词学习弹窗
    @discardableResult
    static func showWordLearning(title: String, htmlBody: String, width: CGFloat = 420, onNextQuiz: ((Bool) -> Void)? = nil, onRetryLearning: (() -> Void)? = nil, onSwitchCategory: ((String) -> Void)? = nil) -> HTMLAlertWindow {
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.hasShadow = false
        window.targetWidth = width
        window.targetMaxHeight = 700
        window.onNextQuiz = onNextQuiz
        window.onRetryLearning = onRetryLearning
        window.onSwitchCategory = onSwitchCategory
        window.isWordLearningMode = true
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isTodoMode: false, isWordLearningMode: true)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return window
    }

    /// 显示「苦练基本功」弹窗（LeetCode 热题 100 随机抽题，风格与背单词一致）
    @discardableResult
    static func showProblem(title: String, htmlBody: String, width: CGFloat = 360, onNext: (() -> Void)? = nil) -> HTMLAlertWindow {
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.hasShadow = false
        window.targetWidth = width
        window.targetMaxHeight = 700
        window.onProblemNext = onNext
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isTodoMode: false, isProblemMode: true)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return window
    }

    /// 在当前窗口 WebView 中执行 JS（用于背单词卡片在 API 数据到达后的热更新）
    func evaluateScript(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible else { return }
            self.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func setupWebView(title: String, htmlBody: String, isInputMode: Bool, isTodoMode: Bool = false, okLabel: String? = nil, isWordLearningMode: Bool = false, isProblemMode: Bool = false, isFriendRequestMode: Bool = false, onCityQuery: ((String) -> Void)? = nil, hideCloseButton: Bool = false) {
        let config = WKWebViewConfiguration()
        config.setValue(false, forKey: "drawsBackground")

        let closeHandler = CloseMessageHandler { [weak self] in
            DispatchQueue.main.async {
                self?.closeWindow()
            }
        }
        self.closeHandler = closeHandler
        config.userContentController.add(closeHandler, name: "close")

        let openURLHandler = OpenURLMessageHandler { url in
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        }
        config.userContentController.add(openURLHandler, name: "openUrl")

        if isInputMode {
            let confirmHandler = ConfirmMessageHandler { [weak self] value in
                DispatchQueue.main.async {
                    if let cityQuery = self?.onCityQuery {
                        cityQuery(value)
                    } else {
                        self?.onConfirm?(value)
                        self?.closeWindow()
                    }
                }
            }
            self.confirmHandler = confirmHandler
            config.userContentController.add(confirmHandler, name: "confirm")
        }
        
        if isTodoMode {
            let addHandler = TodoAddMessageHandler { [weak self] payload in
                DispatchQueue.main.async {
                    // JS 侧以 JSON 字符串回传 {text, due}；兼容旧版纯文本 payload
                    var text = payload
                    var due: Date? = nil
                    if let data = payload.data(using: .utf8),
                       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        text = (obj["text"] as? String) ?? payload
                        if let dueNum = obj["due"] as? Double {
                            due = Date(timeIntervalSince1970: dueNum)
                        }
                    }
                    self?.onTodoAdd?(text, due)
                    self?.refreshTodoList()
                }
            }
            let deleteHandler = TodoDeleteMessageHandler { [weak self] id in
                DispatchQueue.main.async {
                    self?.onTodoDelete?(id)
                    self?.refreshTodoList()
                }
            }
            self.todoAddHandler = addHandler
            self.todoDeleteHandler = deleteHandler
            config.userContentController.add(addHandler, name: "addTodo")
            config.userContentController.add(deleteHandler, name: "deleteTodo")
        }
        
        if isWordLearningMode {
            let nextQuizHandler = WordNextQuizHandler { [weak self] result in
                DispatchQueue.main.async {
                    self?.onNextQuiz?(result == "correct")
                }
            }
            self.nextQuizHandler = nextQuizHandler
            config.userContentController.add(nextQuizHandler, name: "nextQuiz")
            
            let retryHandler = WordRetryLearningHandler { [weak self] in
                DispatchQueue.main.async {
                    self?.onRetryLearning?()
                }
            }
            self.retryLearningHandler = retryHandler
            config.userContentController.add(retryHandler, name: "retryLearning")

            let switchCategoryHandler = WordSwitchCategoryHandler { [weak self] raw in
                DispatchQueue.main.async {
                    self?.onSwitchCategory?(raw)
                }
            }
            self.switchCategoryHandler = switchCategoryHandler
            config.userContentController.add(switchCategoryHandler, name: "switchCategory")
            
            let playAudioHandler = WordPlayAudioHandler { word in
                guard let audioURL = await DictionaryService.shared.fetchAudioURL(word: word),
                      let url = URL(string: audioURL) else { return }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    await MainActor.run {
                        let sound = NSSound(data: data)
                        sound?.play()
                    }
                } catch {
                    FileLogger.log("[Audio] 下载失败: \(word) \(error.localizedDescription)")
                }
            }
            self.playAudioHandler = playAudioHandler
            config.userContentController.add(playAudioHandler, name: "playAudio")
        }

        if isProblemMode {
            let problemNextHandler = WordRetryLearningHandler { [weak self] in
                DispatchQueue.main.async {
                    self?.onProblemNext?()
                }
            }
            self.problemNextHandler = problemNextHandler
            config.userContentController.add(problemNextHandler, name: "problemNext")
        }

        if isFriendRequestMode {
            // 同意/拒绝：先收起卡片（onClose 会清掉静态引用），再回调业务侧发请求
            let acceptHandler = FriendDecisionHandler { [weak self] in
                DispatchQueue.main.async {
                    let action = self?.onFriendAccept
                    self?.closeWindow()
                    action?()
                }
            }
            let rejectHandler = FriendDecisionHandler { [weak self] in
                DispatchQueue.main.async {
                    let action = self?.onFriendReject
                    self?.closeWindow()
                    action?()
                }
            }
            self.friendAcceptHandler = acceptHandler
            self.friendRejectHandler = rejectHandler
            config.userContentController.add(acceptHandler, name: "acceptFriend")
            config.userContentController.add(rejectHandler, name: "rejectFriend")
        }

        // 注入 JS：拦截所有链接点击，阻止默认导航，通过 message handler 打开外部浏览器
        let linkInterceptor = """
        document.addEventListener('click', function(e) {
            var a = e.target.closest('a');
            if (a && a.href && a.href.match(/^https?:/)) {
                e.preventDefault();
                e.stopPropagation();
                window.webkit.messageHandlers.openUrl.postMessage(a.href);
            }
        }, true);
        """
        let userScript = WKUserScript(source: linkInterceptor, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)

        webView = FirstMouseWebView(frame: self.contentView?.bounds ?? .zero, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        // 统一经 CardFrame 边框基类渲染：所有弹窗共享同一套「渐变标题栏 + 深色卡片」骨架
        var frameConfig = CardFrame.Config(title: title, body: htmlBody)
        if isTodoMode {
            // Todo：无边框圆角卡片 + 渐变标题栏（右上角 ✕ 关闭、标题栏可拖动），与天气/新闻等弹窗统一
            frameConfig.showHeader = true
            frameConfig.showFooter = false
            frameConfig.cardWidth = targetWidth
            frameConfig.headerDraggable = true
            frameConfig.maxContentHeight = targetMaxHeight
            // 卡片撑满窗口高度：否则 .card 只 hug 内容（body align-items:flex-start），
            // 空清单/待办少时卡片只有一小块、窗口下方全是透明空白，看着“还是很小”
            frameConfig.extraCSS = HTMLAlertWindow.sharedBusinessCSS + "\nbody{align-items:stretch;} .card{height:100%;} .card-content{flex:1 1 auto;}"
        } else if isWordLearningMode {
            // 背单词：无边框窗口 + 渐变标题栏卡片 + 无底部按钮 + 标题栏可拖动
            frameConfig.showHeader = true
            frameConfig.showFooter = false
            frameConfig.maxContentHeight = 600
            frameConfig.headerDraggable = true
            frameConfig.extraCSS = HTMLAlertWindow.sharedBusinessCSS
        } else {
            // 普通弹窗 / 输入弹窗 / 可缩放卡片窗口：渐变标题栏卡片，统一由标题栏右上角 ✕ 关闭
            frameConfig.showHeader = true
            // 卡片宽度基准须跟随窗口宽度：否则用默认 420 时，宽窗口（如做题 520）里卡片居中变窄，
            // ✕ 按钮左移进入顶部拖动条覆盖区（0 ~ width-60），点击变成拖窗口而无法关闭
            frameConfig.cardWidth = targetWidth
            if isInputMode {
                // 输入弹窗：底部为功能性确认按钮（如「查询天气」），保留
                frameConfig.showFooter = true
                frameConfig.footerLabel = okLabel ?? "查询天气 🔍"
                frameConfig.footerAction = "window.webkit.messageHandlers.confirm.postMessage(document.getElementById('locationInput').value)"
            } else {
                frameConfig.showFooter = false
            }
            frameConfig.maxContentHeight = targetMaxHeight
            frameConfig.extraCSS = HTMLAlertWindow.sharedBusinessCSS
            // 可缩放窗口（热点新闻，borderless+resizable）：内部渐变标题栏作为视觉标题栏，启用拖动
            // 仅标准系统标题栏窗口（titled）需为红绿灯让位；borderless 无红绿灯，不留
            if styleMask.contains(.resizable) {
                frameConfig.headerDraggable = true
                if styleMask.contains(.titled) {
                    frameConfig.headerLeftInset = 78
                }
            }
        }
        frameConfig.hideCloseButton = hideCloseButton
        let html = CardFrame.render(frameConfig)
        webView.loadHTMLString(html, baseURL: nil)

        self.contentView?.addSubview(webView)

        // 无边框窗口统一在 didFinish 中添加拖动条（此时 frame 已正确）
    }


    /// 移除所有 WKScriptMessageHandler，防止内存泄漏（两种关闭路径共用）
    private func removeScriptMessageHandlers() {
        guard let wv = webView else { return }
        let ucc = wv.configuration.userContentController
        // 通用 handler（始终注册）
        ucc.removeScriptMessageHandler(forName: "close")
        ucc.removeScriptMessageHandler(forName: "openUrl")
        // 可选 handler（按注册条件移除）
        if confirmHandler != nil { ucc.removeScriptMessageHandler(forName: "confirm") }
        if todoAddHandler != nil { ucc.removeScriptMessageHandler(forName: "addTodo") }
        if todoDeleteHandler != nil { ucc.removeScriptMessageHandler(forName: "deleteTodo") }
        if nextQuizHandler != nil { ucc.removeScriptMessageHandler(forName: "nextQuiz") }
        if retryLearningHandler != nil { ucc.removeScriptMessageHandler(forName: "retryLearning") }
        if switchCategoryHandler != nil { ucc.removeScriptMessageHandler(forName: "switchCategory") }
        if playAudioHandler != nil { ucc.removeScriptMessageHandler(forName: "playAudio") }
        if problemNextHandler != nil { ucc.removeScriptMessageHandler(forName: "problemNext") }
        if friendAcceptHandler != nil { ucc.removeScriptMessageHandler(forName: "acceptFriend") }
        if friendRejectHandler != nil { ucc.removeScriptMessageHandler(forName: "rejectFriend") }
    }

    /// 网页内 ✕ 按钮关闭路径（orderOut 隐藏，与系统红点行为对齐）
    private func closeWindow() {
        if HTMLAlertWindow.currentTodoWindow === self { HTMLAlertWindow.currentTodoWindow = nil }
        removeScriptMessageHandlers()
        self.orderOut(nil)
        self.onClose?()
    }

    /// 系统标题栏红点关闭路径：与网页 ✕ 一致地清理 handler + 回调，再真正关闭
    override func close() {
        if HTMLAlertWindow.currentTodoWindow === self { HTMLAlertWindow.currentTodoWindow = nil }
        removeScriptMessageHandlers()
        self.onClose?()
        super.close()
    }

    /// 刷新 Todo 列表（通过 JS 更新 DOM，不重建窗口）
    private func refreshTodoList() {
        let todos = TodoManager.shared.load()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(todos),
              let json = String(data: data, encoding: .utf8) else { return }
        // 与 showTodo 保持一致：转义 < 防 </script> 注入
        let safeJSON = json.replacingOccurrences(of: "<", with: "\\u003c")
        let js = "todos = \(safeJSON); renderTodos();"
        webView?.evaluateJavaScript(js, completionHandler: nil)
        // 待办增多/减少时让窗口随之长高/变矮（保持顶边不动，向下扩展）
        let newH = HTMLAlertWindow.todoFinalHeight(count: todos.count)
        var frame = self.frame
        let top = frame.maxY
        frame.size.height = newH
        frame.origin.y = top - newH
        self.setFrame(frame, display: true)
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - self.frame.width / 2
        let y = screenFrame.midY - self.frame.height / 2
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        if style.contains(.titled) && style.contains(.resizable) {
            // Todo 标准标题栏窗口：不透明深色背景，与 HTML 容器同色，消除窗口与内容的色差
            self.backgroundColor = NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.157, alpha: 1.0)  // RGB(30,30,40)
            self.isOpaque = true
            self.hasShadow = false
        } else {
            // borderless（背单词 / 热点新闻可缩放等）：透明背景，由 HTML 卡片绘制视觉边框与圆角
            self.backgroundColor = .clear
            self.isOpaque = false
            self.hasShadow = false
        }
        // 普通层级：切到其他 App 时窗口可正常落到后面（modalPanel 会一直浮在所有 App 之上）
        self.level = .normal
        self.isReleasedWhenClosed = false
    }
}

extension HTMLAlertWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        // 可缩放窗口（resizable）：容器 height:100% 撑满时 scrollHeight 会返回窗口高度，
        // 需临时把容器高度改为 auto 读取真实内容高度，读完恢复撑满（Todo 用估算值，不受影响）
        let measureJS = """
        (function() {
            var c = document.querySelector('.card');
            if (c) {
                c.style.height = 'auto';
                var h = document.documentElement.scrollHeight;
                c.style.height = '';
                return h;
            }
            return document.documentElement.scrollHeight;
        })()
        """
        webView.evaluateJavaScript(measureJS) { [weak self] result, _ in
            guard let self = self, !self.hasSized else { return }
            self.hasSized = true

            let contentHeight: CGFloat
            if let est = self.todoEstimatedHeight {
                // Todo 模式：窗口初始高度用估算值
                contentHeight = est
            } else if let h = result as? CGFloat {
                contentHeight = h
            } else if let h = result as? NSNumber {
                contentHeight = CGFloat(h.doubleValue)
            } else {
                contentHeight = 300
            }

            let minH: CGFloat = 200
            let maxH = min(self.targetMaxHeight, (NSScreen.main?.visibleFrame.height ?? 800) * 0.75)
            let targetH = max(minH, min(contentHeight + 24, maxH))

            var frame = self.frame
            frame.size.width = self.targetWidth
            frame.size.height = targetH
            self.setFrame(frame, display: true)
            self.centerOnScreen()

            // 拖动条：Todo 清单（borderless+resizable 卡片）与非可缩放的 borderless 弹窗（喝水/通知/天气等）都需要。
            // WKWebView 会吞掉标题区域的鼠标事件，isMovableByWindowBackground 拖不动标题，只能靠原生拖动条；
            // -webkit-app-region: drag 在 WKWebView 里不生效。可缩放的非 Todo 窗口（热点新闻）不挂，避免盖住内容。
            if self.todoEstimatedHeight != nil || !self.styleMask.contains(.resizable) {
                // 右侧须给标题栏 ✕ 按钮让位（窗口 padding 8 + 卡片内边距 18 + 按钮 26，共约 52px），
                // 否则拖动条盖住 ✕ 左半部分，点击变成拖窗口（点好几次才能关掉）
                let dragView = DraggableTitleView(frame: NSRect(x: 0, y: self.frame.height - 48, width: self.frame.width - 60, height: 48))
                dragView.autoresizingMask = [.width, .minYMargin]
                self.contentView?.addSubview(dragView)
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                self.animator().alphaValue = 1.0
            })

            // 页面加载完成前到达的天气内容：此时刷新注入
            if let pending = self.pendingWeatherLiteral {
                self.pendingWeatherLiteral = nil
                self.applyWeatherLiteral(pending)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 新窗口（targetFrame == nil）或由 iframe 外链触发的导航 → 外部浏览器打开
        // iframe 自身的主框架导航 → 允许加载
        if let url = navigationAction.request.url, let scheme = url.scheme, scheme.hasPrefix("http"),
           navigationAction.targetFrame == nil || (navigationAction.targetFrame?.isMainFrame == false && navigationAction.navigationType == .linkActivated) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.request.url?.scheme == "app" {
            self.closeWindow()
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

class CloseMessageHandler: NSObject, WKScriptMessageHandler {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        action()
    }
}

class ConfirmMessageHandler: NSObject, WKScriptMessageHandler {
    private let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? String {
            action(value)
        } else {
            action("")
        }
    }
}

class OpenURLMessageHandler: NSObject, WKScriptMessageHandler {
    private let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let url = message.body as? String {
            action(url)
        }
    }
}

class TodoAddMessageHandler: NSObject, WKScriptMessageHandler {
    private let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let text = message.body as? String {
            action(text)
        }
    }
}

class TodoDeleteMessageHandler: NSObject, WKScriptMessageHandler {
    private let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let id = message.body as? String {
            action(id)
        }
    }
}

// MARK: - 背单词消息处理器

class WordNextQuizHandler: NSObject, WKScriptMessageHandler {
    private let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let result = message.body as? String {
            action(result)
        }
    }
}

class WordRetryLearningHandler: NSObject, WKScriptMessageHandler {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        action()
    }
}

class WordPlayAudioHandler: NSObject, WKScriptMessageHandler {
    private let action: (String) async -> Void
    init(action: @escaping (String) async -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let word = message.body as? String {
            Task { await action(word) }
        }
    }
}

class WordSwitchCategoryHandler: NSObject, WKScriptMessageHandler {
    private let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let raw = message.body as? String {
            action(raw)
        }
    }
}

// MARK: - 好友申请处理器（同意 / 拒绝）

class FriendDecisionHandler: NSObject, WKScriptMessageHandler {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        action()
    }
}

// MARK: - 顶部拖动条（覆盖标题栏区域，允许拖动 borderless 窗口）

class DraggableTitleView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
