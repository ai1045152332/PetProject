import AppKit
import WebKit

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
    private var webWindowSize: NSSize?
    private var hasSized = false
    private var dragOffset: NSPoint = .zero
    /// 附加业务 CSS（Todo 列表 / 热点新闻表格 / 喝水文案等），经 CardFrame 基类渲染
    private var extraCSS: String = ""
    /// Todo 模式窗口初始高度（按待办数量估算，放大后由 CSS height:100% 撑满）
    private var todoEstimatedHeight: CGFloat?
    
    // MARK: - Todo
    private var onTodoAdd: ((String) -> Void)?
    private var onTodoDelete: ((String) -> Void)?
    private var todoAddHandler: TodoAddMessageHandler?
    private var todoDeleteHandler: TodoDeleteMessageHandler?
    
    // MARK: - Word Learning
    private var onNextQuiz: ((Bool) -> Void)?
    private var onRetryLearning: (() -> Void)?
    private var nextQuizHandler: WordNextQuizHandler?
    private var retryLearningHandler: WordRetryLearningHandler?
    private var playAudioHandler: WordPlayAudioHandler?
    private var isWordLearningMode = false
    /// 天气查询回调（城市输入后传回）
    var onCityQuery: ((String) -> Void)?

    // MARK: - 天气窗口追踪
    /// 当前天气查询窗口引用（用于在同一窗口内更新内容）
    private static weak var currentWeatherWindow: HTMLAlertWindow?
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
    """

    /// 显示 Todo 清单弹窗
    static func showTodo(title: String, todos: [TodoItem], width: CGFloat = 440, maxHeight: CGFloat = 640, onAdd: @escaping (String) -> Void, onDelete: @escaping (String) -> Void, onClose: (() -> Void)? = nil) {
        // Todo 用标准带边框窗口（可缩放、去阴影、有系统边框），区别于其他无边框弹窗
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.hasShadow = false  // 去阴影
        window.title = title
        // 强制深色外观：标题栏与深色内容同色调，消除浅色系统标题栏造成的巨大色差
        window.appearance = NSAppearance(named: .darkAqua)
        // 标准系统标题栏：清晰边框 + 红绿灯（绿点缩放），让用户一眼看出窗口边界与缩放位置
        FileLogger.log("[TodoWindow] styleMask=\(window.styleMask.rawValue) resizable=\(window.styleMask.contains(.resizable))")
        window.targetWidth = width
        window.targetMaxHeight = maxHeight
        // 初始高度按待办数量估算（空列表 320，每条约 52），避免依赖 scrollHeight
        window.todoEstimatedHeight = min(maxHeight, max(320, 320 + CGFloat(todos.count) * 52))
        window.onTodoAdd = onAdd
        window.onTodoDelete = onDelete
        window.onClose = onClose
        
        let todosJSON: String
        if let data = try? JSONEncoder().encode(todos),
           let json = String(data: data, encoding: .utf8) {
            // 防止待办文本含 "</script>" 提前闭合 script 标签（XSS/页面破坏）
            todosJSON = json.replacingOccurrences(of: "<", with: "\\u003c")
        } else {
            todosJSON = "[]"
        }
        
        let htmlBody = """
        <div class="todo-input-group">
            <input type="text" id="todoInput" placeholder="输入待办事项，按回车添加..." />
            <button id="addBtn">➕</button>
        </div>
        <div class="todo-list" id="todoList"></div>
        <script>
            var todos = \(todosJSON);
            var pendingDeleteId = null;
            function renderTodos() {
                var list = document.getElementById('todoList');
                list.innerHTML = '';
                if (todos.length === 0) {
                    list.innerHTML = '<div class="todo-empty">暂无待办事项 🎉</div>';
                    return;
                }
                for (var i = 0; i < todos.length; i++) {
                    var isPending = todos[i].id === pendingDeleteId;
                    var item = document.createElement('div');
                    item.className = isPending ? 'todo-item todo-item-confirm' : 'todo-item';

                    var dot = document.createElement('span');
                    dot.className = 'todo-dot';
                    dot.textContent = isPending ? '⚠️' : '●';
                    dot.style.cursor = 'pointer';
                    dot.onclick = (function(t){ return function(){ copyTodo(t); }; })(todos[i].text);

                    var txt = document.createElement('span');
                    txt.className = 'todo-text';
                    txt.textContent = isPending ? '再次点击确认删除' : todos[i].text;
                    txt.style.cursor = 'pointer';
                    txt.onclick = (function(t){ return function(){ copyTodo(t); }; })(todos[i].text);

                    var del = document.createElement('span');
                    del.className = 'todo-delete';
                    del.textContent = isPending ? '删除' : '✕';
                    del.onclick = (function(id){ return function(){ deleteTodo(id); }; })(todos[i].id);

                    item.appendChild(dot);
                    item.appendChild(txt);
                    item.appendChild(del);
                    list.appendChild(item);
                }
            }
            function addTodo() {
                var input = document.getElementById('todoInput');
                var text = input.value.trim();
                if (text && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.addTodo) {
                    window.webkit.messageHandlers.addTodo.postMessage(text);
                    input.value = '';
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
            document.getElementById('todoInput').addEventListener('keypress', function(e) {
                if (e.key === 'Enter') addTodo();
            });
            document.getElementById('todoInput').addEventListener('focus', function() {
                pendingDeleteId = null;
                renderTodos();
            });
            renderTodos();
        </script>
        """
        
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isTodoMode: true)
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

    /// 显示内嵌网页弹窗（通过 iframe 嵌入外部 H5 页面，如小游戏）
    /// 默认按手机竖屏比例取屏幕可用高度的 75%，宽度不足时等比缩窄
    static func showWeb(title: String, urlString: String, maxHeightRatio: CGFloat = 0.75, onClose: (() -> Void)? = nil) {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        var height = visible.height * maxHeightRatio
        var width = height * 0.46
        if width > visible.width * 0.92 {
            width = visible.width * 0.92
            height = width / 0.46
        }
        let windowSize = NSSize(width: width, height: height)
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: windowSize.width, height: windowSize.height),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.hasShadow = false
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.targetWidth = windowSize.width
        window.targetMaxHeight = windowSize.height
        window.webWindowSize = windowSize
        window.onClose = onClose

        let escapedURL = urlString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let htmlBody = """
        <button class="game-close-btn" onclick="window.webkit.messageHandlers.close.postMessage('')">✕</button>
        <iframe src="\(escapedURL)" style="width:100%;height:100%;border:none;border-radius:12px;background:#1a1a2e;" sandbox="allow-scripts allow-same-origin allow-popups allow-forms allow-pointer-lock"></iframe>
        """
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isTodoMode: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// 显示背单词学习弹窗
    @discardableResult
    static func showWordLearning(title: String, htmlBody: String, width: CGFloat = 420, onNextQuiz: ((Bool) -> Void)? = nil, onRetryLearning: (() -> Void)? = nil) -> HTMLAlertWindow {
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
        window.isWordLearningMode = true
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isTodoMode: false, isWordLearningMode: true)
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

    private func setupWebView(title: String, htmlBody: String, isInputMode: Bool, isTodoMode: Bool = false, okLabel: String? = nil, isWordLearningMode: Bool = false, onCityQuery: ((String) -> Void)? = nil, hideCloseButton: Bool = false) {
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
            let addHandler = TodoAddMessageHandler { [weak self] text in
                DispatchQueue.main.async {
                    self?.onTodoAdd?(text)
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

        webView = WKWebView(frame: self.contentView?.bounds ?? .zero, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        // 统一经 CardFrame 边框基类渲染：所有弹窗共享同一套「渐变标题栏 + 深色卡片」骨架
        var frameConfig = CardFrame.Config(title: title, body: htmlBody)
        if isTodoMode {
            // Todo：标准系统标题栏窗口（红绿灯关闭），内部隐藏渐变标题栏与底部按钮，全出血铺满
            frameConfig.showHeader = false
            frameConfig.showFooter = false
            frameConfig.fullBleed = true
            frameConfig.maxContentHeight = nil
            frameConfig.extraCSS = HTMLAlertWindow.sharedBusinessCSS
        } else if webWindowSize != nil {
            // 小游戏：无标题栏、无底部按钮，游戏铺满窗口 + 右上角悬浮关闭
            frameConfig.showHeader = false
            frameConfig.showFooter = false
            frameConfig.maxContentHeight = nil
            frameConfig.cardWidth = targetWidth
            frameConfig.extraCSS = """
                .card { height: 100%; max-width: none; }
                .card-content { padding: 0; min-height: 0; overflow: hidden; position: relative; }
                .card-content iframe { display: block; }
                .game-close-btn {
                    position: absolute;
                    top: 10px;
                    right: 10px;
                    width: 30px;
                    height: 30px;
                    border: none;
                    border-radius: 50%;
                    background: rgba(0, 0, 0, 0.45);
                    color: rgba(255, 255, 255, 0.9);
                    font-size: 15px;
                    line-height: 30px;
                    text-align: center;
                    cursor: pointer;
                    z-index: 10;
                    -webkit-appearance: none;
                    transition: background 0.2s;
                }
                .game-close-btn:hover { background: rgba(0, 0, 0, 0.7); }
            """
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
        if playAudioHandler != nil { ucc.removeScriptMessageHandler(forName: "playAudio") }
    }

    /// 网页内 ✕ 按钮关闭路径（orderOut 隐藏，与系统红点行为对齐）
    private func closeWindow() {
        removeScriptMessageHandlers()
        self.orderOut(nil)
        self.onClose?()
    }

    /// 系统标题栏红点关闭路径：与网页 ✕ 一致地清理 handler + 回调，再真正关闭
    override func close() {
        removeScriptMessageHandlers()
        self.onClose?()
        super.close()
    }

    /// 刷新 Todo 列表（通过 JS 更新 DOM，不重建窗口）
    private func refreshTodoList() {
        let todos = TodoManager.shared.load()
        guard let data = try? JSONEncoder().encode(todos),
              let json = String(data: data, encoding: .utf8) else { return }
        // 与 showTodo 保持一致：转义 < 防 </script> 注入
        let safeJSON = json.replacingOccurrences(of: "<", with: "\\u003c")
        let js = "todos = \(safeJSON); renderTodos();"
        webView?.evaluateJavaScript(js, completionHandler: nil)
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
        self.level = .modalPanel
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
            let targetH = self.webWindowSize?.height ?? max(minH, min(contentHeight + 24, maxH))

            var frame = self.frame
            frame.size.width = self.targetWidth
            frame.size.height = targetH
            self.setFrame(frame, display: true)
            self.centerOnScreen()

            // 所有无边框窗口（非可缩放）：sizing 完成后添加原生拖动条（此时 frame 已正确）
            // 可缩放标准窗口（热点新闻）的渐变标题栏已启用 -webkit-app-region: drag，无需原生拖动条
            if self.todoEstimatedHeight == nil && self.webWindowSize == nil && !self.styleMask.contains(.resizable) {
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
