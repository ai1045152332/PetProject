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
    private var hasSized = false
    private var dragOffset: NSPoint = .zero
    
    // MARK: - Todo
    private var onTodoAdd: ((String) -> Void)?
    private var onTodoDelete: ((String) -> Void)?
    private var todoAddHandler: TodoAddMessageHandler?
    private var todoDeleteHandler: TodoDeleteMessageHandler?

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
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: false, isTodoMode: false)
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
        window.setupWebView(title: title, htmlBody: htmlBody, isInputMode: true, isTodoMode: false, okLabel: okLabel)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// 显示 Todo 清单弹窗
    static func showTodo(title: String, todos: [TodoItem], width: CGFloat = 360, maxHeight: CGFloat = 520, onAdd: @escaping (String) -> Void, onDelete: @escaping (String) -> Void, onClose: (() -> Void)? = nil) {
        let window = HTMLAlertWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.targetWidth = width
        window.targetMaxHeight = maxHeight
        window.onTodoAdd = onAdd
        window.onTodoDelete = onDelete
        window.onClose = onClose
        
        let todosJSON: String
        if let data = try? JSONEncoder().encode(todos),
           let json = String(data: data, encoding: .utf8) {
            todosJSON = json
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

    private func setupWebView(title: String, htmlBody: String, isInputMode: Bool, isTodoMode: Bool = false, okLabel: String? = nil) {
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

        let html = buildHTML(title: title, body: htmlBody, isInputMode: isInputMode, isTodoMode: isTodoMode, okLabel: okLabel)
        webView.loadHTMLString(html, baseURL: nil)

        self.contentView?.addSubview(webView)
        
        // 添加顶部拖动条（覆盖标题栏区域，可拖动窗口，留出右侧按钮区域）
        let dragView = DraggableTitleView(frame: NSRect(x: 0, y: self.frame.height - 44, width: targetWidth - 60, height: 44))
        dragView.autoresizingMask = [.width, .maxYMargin]
        self.contentView?.addSubview(dragView)
    }

    private func buildHTML(title: String, body: String, isInputMode: Bool, isTodoMode: Bool = false, okLabel: String? = nil) -> String {
        let okAction = isInputMode
            ? "window.webkit.messageHandlers.confirm.postMessage(document.getElementById('locationInput').value)"
            : "window.webkit.messageHandlers.close.postMessage('')"
        let defaultLabel: String
        if isInputMode {
            defaultLabel = "查询天气 🔍"
        } else if isTodoMode {
            defaultLabel = "关闭 ❌"
        } else {
            defaultLabel = "好哒 👌"
        }
        let finalLabel = okLabel ?? defaultLabel

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", sans-serif;
                background: transparent;
                color: #f0f0f5;
            }
            body {
                padding: 8px;
                display: flex;
                justify-content: center;
                align-items: flex-start;
            }
            .container {
                background: rgba(30, 30, 40, 0.94);
                backdrop-filter: blur(24px);
                -webkit-backdrop-filter: blur(24px);
                border-radius: 18px;
                overflow: hidden;
                box-shadow: 0 24px 70px rgba(0,0,0,0.55);
                border: 1px solid rgba(255,255,255,0.08);
                width: 100%;
                max-width: \(targetWidth - 16)px;
                display: flex;
                flex-direction: column;
            }
            .header {
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                padding: 14px 18px;
                display: flex;
                align-items: center;
                justify-content: space-between;
                flex-shrink: 0;
            }
            .header-title {
                display: flex;
                align-items: center;
                gap: 10px;
            }
            .header h1 {
                font-size: 15px;
                font-weight: 600;
                color: white;
                letter-spacing: 0.5px;
            }
            .header .icon {
                font-size: 20px;
            }
            .close-btn {
                background: rgba(255,255,255,0.2);
                border: none;
                color: white;
                width: 26px;
                height: 26px;
                border-radius: 50%;
                cursor: pointer;
                font-size: 13px;
                line-height: 26px;
                text-align: center;
                transition: all 0.2s;
                -webkit-appearance: none;
            }
            .close-btn:hover {
                background: rgba(255,255,255,0.35);
            }
            .content {
                padding: 14px 16px;
                line-height: 1.7;
                font-size: 14px;
                flex: 1 1 auto;
                overflow-y: auto;
                max-height: 420px;
                min-height: \(isTodoMode ? 260 : 0)px;
            }
            .footer {
                padding: 10px 16px 14px;
                text-align: center;
                flex-shrink: 0;
            }
            .ok-btn {
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                border: none;
                color: white;
                padding: 9px 32px;
                border-radius: 22px;
                font-size: 14px;
                font-weight: 500;
                cursor: pointer;
                transition: all 0.2s;
                box-shadow: 0 4px 15px rgba(102, 126, 234, 0.4);
                -webkit-appearance: none;
            }
            .ok-btn:hover {
                opacity: 0.92;
                transform: translateY(-1px);
            }
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
            .news-table tbody tr:first-child td {
                border-top: none;
            }
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
            .news-link:hover {
                color: #a5b4fc;
                text-decoration: underline;
            }
            .water-icon {
                text-align: center;
                font-size: 48px;
                margin: 8px 0;
            }
            .water-text {
                text-align: center;
                font-size: 15px;
                color: #c0c0d0;
                margin-bottom: 8px;
                font-weight: 500;
            }
            .water-tips {
                text-align: center;
                font-size: 13px;
                color: #8888a0;
                line-height: 1.7;
            }
            .input-group {
                padding: 8px 0;
            }
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
            .input-group input::placeholder {
                color: #666680;
            }
            ::-webkit-scrollbar {
                width: 4px;
            }
            ::-webkit-scrollbar-track {
                background: transparent;
            }
            ::-webkit-scrollbar-thumb {
                background: rgba(255,255,255,0.15);
                border-radius: 2px;
            }
            .todo-input-group {
                display: flex;
                gap: 8px;
                margin-bottom: 14px;
            }
            .todo-input-group input {
                flex: 1;
                background: rgba(255,255,255,0.06);
                border: 1px solid rgba(255,255,255,0.1);
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
            .todo-input-group button:hover {
                opacity: 0.92;
                transform: translateY(-1px);
            }
            .todo-list {
                display: flex;
                flex-direction: column;
                gap: 6px;
            }
            .todo-empty {
                text-align: center;
                color: #666680;
                font-size: 13px;
                padding: 20px 0;
            }
            .todo-item {
                display: flex;
                align-items: center;
                gap: 10px;
                padding: 10px 12px;
                background: rgba(255,255,255,0.04);
                border-radius: 10px;
                cursor: pointer;
                transition: all 0.2s;
                border: 1px solid rgba(255,255,255,0.04);
            }
            .todo-item:hover {
                background: rgba(255,255,255,0.08);
                border-color: rgba(255,100,100,0.3);
            }
            .todo-item:hover .todo-delete {
                opacity: 1;
            }
            .todo-item-confirm {
                background: rgba(255,80,80,0.12) !important;
                border-color: rgba(255,80,80,0.5) !important;
                animation: pulse 1s infinite;
            }
            @keyframes pulse {
                0%, 100% { box-shadow: 0 0 0 0 rgba(255,80,80,0.3); }
                50% { box-shadow: 0 0 8px 2px rgba(255,80,80,0.2); }
            }
            .todo-dot {
                color: #667eea;
                font-size: 8px;
                flex-shrink: 0;
            }
            .todo-text {
                flex: 1;
                font-size: 14px;
                color: #e0e0e8;
                word-break: break-all;
            }
            .todo-delete {
                color: #ff6b6b;
                font-size: 12px;
                opacity: 0.4;
                transition: opacity 0.2s;
                flex-shrink: 0;
            }
        </style>
        </head>
        <body>
        <div class="container">
            <div class="header">
                <div class="header-title">
                    <span class="icon">🐱</span>
                    <h1>\(title)</h1>
                </div>
                <button class="close-btn" onclick="window.webkit.messageHandlers.close.postMessage('')">✕</button>
            </div>
            <div class="content">
                \(body)
            </div>
            <div class="footer">
                <button class="ok-btn" onclick="\(okAction)">\(finalLabel)</button>
            </div>
        </div>
        </body>
        </html>
        """
    }

    private func closeWindow() {
        // 移除所有 WKScriptMessageHandler，防止内存泄漏
        if let wv = webView {
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "close")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "openUrl")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "confirm")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "addTodo")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "deleteTodo")
        }
        self.orderOut(nil)
        self.onClose?()
    }

    /// 刷新 Todo 列表（通过 JS 更新 DOM，不重建窗口）
    private func refreshTodoList() {
        let todos = TodoManager.shared.load()
        guard let data = try? JSONEncoder().encode(todos),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "todos = \(json); renderTodos();"
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
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.level = .modalPanel
        self.isReleasedWhenClosed = false
    }
}

extension HTMLAlertWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] result, _ in
            guard let self = self, !self.hasSized else { return }
            self.hasSized = true

            let contentHeight: CGFloat
            if let h = result as? CGFloat {
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
