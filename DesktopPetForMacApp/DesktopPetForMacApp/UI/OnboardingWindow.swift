import AppKit
import WebKit

/// 首次启动新手指引弹窗
/// 引导用户填写宠物名称，完成后写入 UserDefaults 并关闭
final class OnboardingWindow: NSWindow {

    private var webView: WKWebView!
    private let onComplete: () -> Void

    /// 显示新手指引（若已设置过名称则不弹出）
    static func showIfNeeded(onComplete: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: "settings.hasLaunchedBefore") else {
            onComplete()
            return
        }
        UserDefaults.standard.set(true, forKey: "settings.hasLaunchedBefore")
        let window = OnboardingWindow(onComplete: onComplete)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1.0
        }
    }

    private init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.level = .modalPanel
        self.isReleasedWhenClosed = false
        setupWebView()
        center()
    }

    /// 关键：必须覆盖才能让 WebView 输入框获得焦点
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupWebView() {
        let config = WKWebViewConfiguration()

        let closeHandler = CloseMessageHandler { [weak self] in
            DispatchQueue.main.async { self?.finish() }
        }
        config.userContentController.add(closeHandler, name: "close")

        let confirmHandler = ConfirmMessageHandler { [weak self] name in
            DispatchQueue.main.async {
                PetName.setName(name)
                self?.finish()
            }
        }
        config.userContentController.add(confirmHandler, name: "confirm")

        // 拦截外链在浏览器打开
        let linkScript = """
        document.addEventListener('click', function(e) {
            var a = e.target.closest('a');
            if (a && a.href && a.href.match(/^https?:/)) {
                e.preventDefault();
                window.webkit.messageHandlers.close.postMessage('');
            }
        }, true);
        """
        let userScript = WKUserScript(source: linkScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)

        webView = WKWebView(frame: contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        contentView?.addSubview(webView)

        let html = Self.buildHTML()
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func finish() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }) { [weak self] in
            self?.orderOut(nil)
            self?.onComplete()
        }
    }

    // MARK: - HTML

    private static func buildHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="zh">
        <head>
        <meta charset="UTF-8">
        <style>
        * { margin:0; padding:0; box-sizing:border-box; }
        html, body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", sans-serif;
            background: transparent;
            color: #f0f0f5;
            height: 100%;
            overflow: hidden;
        }
        .card {
            background: rgba(28, 28, 38, 0.95);
            backdrop-filter: blur(30px);
            -webkit-backdrop-filter: blur(30px);
            border-radius: 20px;
            height: 100%;
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }

        /* ── 渐变顶部 ── */
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 32px 28px 24px;
            text-align: center;
            flex-shrink: 0;
        }
        .cat-emoji { font-size: 64px; line-height: 1; margin-bottom: 8px; }
        .header h1 {
            font-size: 22px;
            font-weight: 700;
            color: #fff;
            letter-spacing: 0.5px;
        }
        .header p {
            font-size: 13px;
            color: rgba(255,255,255,0.75);
            margin-top: 4px;
        }

        /* ── 内容区 ── */
        .content {
            padding: 28px 28px 20px;
            flex: 1;
            display: flex;
            flex-direction: column;
            gap: 20px;
        }

        /* 特性列表 */
        .features { display: flex; flex-direction: column; gap: 12px; }
        .feat-item {
            display: flex;
            align-items: center;
            gap: 12px;
            background: rgba(255,255,255,0.04);
            border-radius: 12px;
            padding: 12px 14px;
        }
        .feat-icon {
            font-size: 24px;
            width: 36px;
            text-align: center;
            flex-shrink: 0;
        }
        .feat-text { font-size: 12px; color: #b0b0c0; line-height: 1.5; }
        .feat-text strong { color: #e0e0f0; font-weight: 600; }

        /* ── 名称输入区 ── */
        .name-section {
            margin-top: auto;
        }
        .name-label {
            font-size: 12px;
            font-weight: 600;
            color: #a0a0b0;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 8px;
        }
        .name-input-wrap {
            position: relative;
        }
        #petNameInput {
            width: 100%;
            background: rgba(255,255,255,0.06);
            border: 1.5px solid rgba(255,255,255,0.1);
            border-radius: 14px;
            padding: 14px 16px;
            color: #f0f0f5;
            font-size: 18px;
            font-weight: 600;
            text-align: center;
            outline: none;
            transition: all 0.25s;
            -webkit-appearance: none;
        }
        #petNameInput:focus {
            border-color: rgba(102,126,234,0.7);
            background: rgba(102,126,234,0.08);
            box-shadow: 0 0 0 4px rgba(102,126,234,0.12);
        }
        #petNameInput::placeholder { color: #555568; font-weight: 400; }

        /* ── 开始使用按钮 ── */
        .start-btn {
            width: 100%;
            margin-top: 14px;
            padding: 14px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            border: none;
            border-radius: 14px;
            color: #fff;
            font-size: 16px;
            font-weight: 700;
            cursor: pointer;
            transition: all 0.2s;
            -webkit-appearance: none;
        }
        .start-btn:hover {
            transform: translateY(-1px);
            box-shadow: 0 6px 24px rgba(102,126,234,0.4);
        }
        .start-btn:active { transform: translateY(0); }

        /* ── 跳过链接 ── */
        .skip {
            text-align: center;
            padding: 8px 0 4px;
        }
        .skip a {
            font-size: 12px;
            color: #666680;
            text-decoration: none;
            cursor: pointer;
            transition: color 0.2s;
        }
        .skip a:hover { color: #9090a8; }
        </style>
        </head>
        <body>
        <div class="card">
            <div class="header">
                <div class="cat-emoji">🐱</div>
                <h1>欢迎光临小猫世界</h1>
                <p>你的桌面小助手，让工作不再枯燥</p>
            </div>
            <div class="content">
                <div class="features">
                    <div class="feat-item">
                        <span class="feat-icon">⏰</span>
                        <span class="feat-text"><strong>喝水提醒</strong> · 定时提醒你补充水分</span>
                    </div>
                    <div class="feat-item">
                        <span class="feat-icon">📰</span>
                        <span class="feat-text"><strong>热点资讯</strong> · 随时掌握热门动态</span>
                    </div>
                    <div class="feat-item">
                        <span class="feat-icon">☀️</span>
                        <span class="feat-text"><strong>天气查询 / 背单词 / 股票</strong> · 实用工具集于一身</span>
                    </div>
                </div>
                <div class="name-section">
                    <div class="name-label">给你的小猫取个名字吧</div>
                    <div class="name-input-wrap">
                        <input type="text" id="petNameInput" placeholder="例如：毛豆、团团、小咪" maxlength="12" autofocus />
                    </div>
                    <button class="start-btn" onclick="startApp()">开始使用 ✨</button>
                </div>
                <div class="skip">
                    <a onclick="skipSetup()">跳过，使用默认名称</a>
                </div>
            </div>
        </div>
        <script>
            function startApp() {
                var input = document.getElementById('petNameInput');
                var name = input.value.trim() || '毛豆';
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.confirm) {
                    window.webkit.messageHandlers.confirm.postMessage(name);
                }
            }
            function skipSetup() {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.close) {
                    window.webkit.messageHandlers.close.postMessage('');
                }
            }
            // 回车触发开始
            document.getElementById('petNameInput').addEventListener('keypress', function(e) {
                if (e.key === 'Enter') startApp();
            });
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - WKNavigationDelegate

extension OnboardingWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let scheme = url.scheme,
           scheme.hasPrefix("http"), navigationAction.targetFrame == nil {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
