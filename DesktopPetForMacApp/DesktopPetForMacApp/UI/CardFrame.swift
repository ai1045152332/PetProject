import AppKit

/// 弹窗「边框 + 标题栏」基类
///
/// 统一所有 WKWebView 弹窗的外框形态：深色毛玻璃卡片 + 渐变标题栏 + 底部按钮。
/// 背单词、热点新闻、Todo、普通提示、输入弹窗均复用本基类渲染，保证形式一致。
/// 不同弹窗仅通过参数控制差异（是否渐变标题栏 / 是否底部按钮 / 圆角 / 全出血等）。
enum CardFrame {
    /// 边框基类配置（按语义区分，供各弹窗入口组装）
    struct Config {
        var title: String
        var body: String

        /// 是否显示渐变标题栏（标准系统标题栏窗口传 false，隐藏内部渐变标题栏）
        var showHeader: Bool = true
        /// 是否显示底部按钮
        var showFooter: Bool = true
        /// 底部按钮文字
        var footerLabel: String = "好哒 👌"
        /// 底部按钮 JS 动作（nil = 关闭弹窗）
        var footerAction: String? = nil
        /// 卡片圆角（全出血模式强制 0）
        var cornerRadius: CGFloat = 18
        /// 全出血：内容铺满窗口，去圆角/阴影/边框（用于标准标题栏窗口）
        var fullBleed: Bool = false
        /// 内容区最大高度（nil = 不限制）
        var maxContentHeight: CGFloat? = nil
        /// 渐变标题栏是否可拖动窗口（无边框窗口用）
        var headerDraggable: Bool = false
        /// 附加 CSS（业务专属样式，如 Todo 列表等）
        var extraCSS: String = ""
        /// 卡片宽度基准（用于 max-width 计算）
        var cardWidth: CGFloat = 420
        /// 渐变标题栏左侧预留宽度（px，可缩放标准窗口为红绿灯让位；无边框窗口传 0）
        var headerLeftInset: CGFloat = 0
    }

    /// 渲染完整弹窗 HTML
    static func render(_ config: Config) -> String {
        let css = buildCSS(config)
        let header: String
        if config.showHeader {
            header = """
                <div class="card-header">
                    <div class="card-header-title">
                        <span class="icon">🐱</span>
                        <h1>\(config.title)</h1>
                    </div>
                    <button class="close-btn" onclick="window.webkit.messageHandlers.close.postMessage('')">✕</button>
                </div>
            """
        } else {
            header = ""
        }
        let footer: String
        if config.showFooter {
            let action = config.footerAction ?? "window.webkit.messageHandlers.close.postMessage('')"
            footer = """
                <div class="card-footer">
                    <button class="ok-btn" onclick="\(action)">\(config.footerLabel)</button>
                </div>
            """
        } else {
            footer = ""
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
        \(css)
        </style>
        </head>
        <body>
        <div class="card">
            \(header)
            <div class="card-content">\(config.body)</div>
            \(footer)
        </div>
        </body>
        </html>
        """
    }

    // MARK: - 基类 CSS

    /// 统一边框基类 CSS：卡片 / 渐变标题栏 / 内容区 / 底部按钮 / 滚动条 + 业务附加样式
    private static func buildCSS(_ c: Config) -> String {
        let radius = c.fullBleed ? 0 : Int(c.cornerRadius)
        let bodyPad = c.fullBleed ? 0 : 8
        let shadow = c.fullBleed ? "none" : "0 24px 70px rgba(0,0,0,0.55)"
        let border = c.fullBleed ? "none" : "1px solid rgba(255,255,255,0.08)"
        let maxW = c.fullBleed ? "100%" : "\(Int(c.cardWidth - 16))px"
        let maxH = c.maxContentHeight.map { "\(Int($0))px" } ?? "none"
        let headerDisplay = c.showHeader ? "flex" : "none"
        let headerInset = c.headerLeftInset > 0 ? "padding-left: \(Int(c.headerLeftInset))px;" : ""
        let dragCSS = c.headerDraggable ? "-webkit-app-region: drag;" : ""
        let noDragCSS = c.headerDraggable ? "-webkit-app-region: no-drag;" : ""

        let base = """
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", sans-serif;
                background: transparent;
                color: #f0f0f5;
                height: 100%;
            }
            body {
                padding: \(bodyPad)px;
                display: flex;
                justify-content: center;
                align-items: flex-start;
            }
            .card {
                background: rgba(30, 30, 40, 0.94);
                backdrop-filter: blur(24px);
                -webkit-backdrop-filter: blur(24px);
                border-radius: \(radius)px;
                overflow: hidden;
                box-shadow: \(shadow);
                border: \(border);
                width: 100%;
                max-width: \(maxW);
                height: \(c.fullBleed ? "100%" : "auto");
                display: flex;
                flex-direction: column;
            }
            .card-header {
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                padding: 14px 18px;
                display: \(headerDisplay);
                align-items: center;
                justify-content: space-between;
                flex-shrink: 0;
                \(headerInset)
                \(dragCSS)
            }
            .card-header-title {
                display: flex;
                align-items: center;
                gap: 10px;
            }
            .card-header h1 {
                font-size: 15px;
                font-weight: 600;
                color: white;
                letter-spacing: 0.5px;
            }
            .card-header .icon {
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
                \(noDragCSS)
            }
            .close-btn:hover { background: rgba(255,255,255,0.35); }
            .card-content {
                padding: 14px 16px;
                line-height: 1.7;
                font-size: 14px;
                flex: 1 1 auto;
                overflow-y: auto;
                max-height: \(maxH);
                min-height: \(c.fullBleed ? 260 : 80)px;
            }
            .card-footer {
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
            ::-webkit-scrollbar { width: 4px; }
            ::-webkit-scrollbar-track { background: transparent; }
            ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.15); border-radius: 2px; }
        """
        guard !c.extraCSS.isEmpty else { return base }
        return base + "\n" + c.extraCSS
    }
}
