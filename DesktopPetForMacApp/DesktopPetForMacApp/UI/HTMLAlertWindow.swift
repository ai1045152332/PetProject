import AppKit
import AVFoundation
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
    private var audioPlayer: AVAudioPlayer?
    private var isWordLearningMode = false

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
    static func showResizable(title: String, htmlBody: String, width: CGFloat = 480, maxHeight: CGFloat = 640, onClose: (() -> Void)? = nil) {
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
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isTodoMode: false, okLabel: "关闭 ❌")
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

    private func setupWebView(title: String, htmlBody: String, isInputMode: Bool, isTodoMode: Bool = false, okLabel: String? = nil, isWordLearningMode: Bool = false) {
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
                    self?.onConfirm?(value)
                    self?.closeWindow()
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
            
            let playAudioHandler = WordPlayAudioHandler { [weak self] word in
                guard let self = self else { return }
                Task {
                    if let audioURL = await DictionaryService.shared.fetchAudioURL(word: word) {
                        await MainActor.run {
                            if let url = URL(string: audioURL) {
                                self.audioPlayer = try? AVAudioPlayer(contentsOf: url)
                                self.audioPlayer?.play()
                            }
                        }
                    }
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

        webView = WKWebView(frame: self.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        // 统一经 CardFrame 边框基类渲染：所有弹窗共享同一套「渐变标题栏 + 深色卡片」骨架
        var frameConfig = CardFrame.Config(title: title, body: htmlBody)
        if isTodoMode {
            // Todo：标准系统标题栏窗口，内部隐藏渐变标题栏，全出血铺满
            frameConfig.showHeader = false
            frameConfig.showFooter = true
            frameConfig.footerLabel = okLabel ?? "关闭 ❌"
            frameConfig.fullBleed = true
            frameConfig.maxContentHeight = nil
            frameConfig.extraCSS = HTMLAlertWindow.sharedBusinessCSS
        } else if isWordLearningMode {
            // 背单词：无边框窗口 + 渐变标题栏卡片 + 无底部按钮 + 标题栏可拖动
            frameConfig.showHeader = true
            frameConfig.showFooter = false
            frameConfig.maxContentHeight = 600
            frameConfig.headerDraggable = true
            frameConfig.extraCSS = HTMLAlertWindow.sharedBusinessCSS
        } else {
            // 普通弹窗 / 输入弹窗 / 可缩放卡片窗口：渐变标题栏卡片 + 底部按钮
            frameConfig.showHeader = true
            frameConfig.showFooter = true
            if isInputMode {
                frameConfig.footerLabel = okLabel ?? "查询天气 🔍"
                frameConfig.footerAction = "window.webkit.messageHandlers.confirm.postMessage(document.getElementById('locationInput').value)"
            } else {
                frameConfig.footerLabel = okLabel ?? "好哒 👌"
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
        if style.contains(.resizable) {
            // 可缩放窗口（Todo）：不透明深色背景，与 HTML 容器同色，消除窗口与内容的色差
            self.backgroundColor = NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.157, alpha: 1.0)  // RGB(30,30,40)
            self.isOpaque = true
            self.hasShadow = false
        } else {
            self.backgroundColor = .clear
            self.isOpaque = false
            self.hasShadow = true
        }
        self.level = .modalPanel
        self.isReleasedWhenClosed = false
    }
}

extension HTMLAlertWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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

            // 所有无边框窗口（非可缩放）：sizing 完成后添加原生拖动条（此时 frame 已正确）
            // 可缩放标准窗口（热点新闻）的渐变标题栏已启用 -webkit-app-region: drag，无需原生拖动条
            if self.todoEstimatedHeight == nil && !self.styleMask.contains(.resizable) {
                let dragView = DraggableTitleView(frame: NSRect(x: 0, y: self.frame.height - 48, width: self.frame.width - 40, height: 48))
                dragView.autoresizingMask = [.width, .minYMargin]
                self.contentView?.addSubview(dragView)
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                self.animator().alphaValue = 1.0
            })
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let scheme = url.scheme, scheme.hasPrefix("http") {
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
    private let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let word = message.body as? String {
            action(word)
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
