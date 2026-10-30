// FriendChatWindow.swift
// DesktopPetForMacApp — 好友聊天窗
// 由「好友消息卡」升级而来：既能看与这位好友的最近聊天记录（服务端留痕，/api/social/history），
// 也能在窗口里直接回复（/api/social/send），发出去的消息按对方已读状态标「已读/未读」。
// 与会自动淡出的气泡不同：卡片常驻，用户点标题栏 ✕ 才关闭；关闭时把本次下发的消息 ID
// 上报服务端确认已读（未确认前服务端会重投，所以被顶掉/没看完的消息不会静默丢失）。
// 同一时刻只保留一个会话窗；换人会话时旧窗静默关闭且不回填已读。
// 服务端还没上 history 接口时降级为只显示本次收到的消息，仍可正常回复。

import AppKit
import WebKit

@MainActor
final class FriendChatWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private var webView: WKWebView!
    private var closeHandler: CloseMessageHandler?
    private var chatSendHandler: ChatSendHandler?
    private var targetWidth: CGFloat = 380
    private var hasSized = false
    /// 点 ✕ / 换人关窗时的回调（上报已读、清理静态引用）
    var onClose: (() -> Void)?
    /// 页面是否已加载完成（加载完成前到达的记录先暂存，didFinish 时补渲染）
    private var isPageLoaded = false
    private var pendingRowsLiteral: String?

    /// 当前会话对应的好友宠物号
    private var friendPetNo = 0
    private var friendDisplay = ""
    /// 本次下发、等用户看完关卡时确认已读的消息 ID
    private var unreadIDs: [String] = []
    /// 窗口内已展示的会话行（换人重开、同好友追加新消息时都在它上面继续）
    private var rows: [PetChatMessage] = []
    /// 已乐观上屏、但还没被服务端历史覆盖的本机消息
    private var optimistic: [PetChatMessage] = []

    /// 当前会话窗引用（同一时刻只保留一个，避免堆叠）
    private static weak var current: FriendChatWindow?

    // MARK: - 入口

    /// 会话窗标题用的友方文案：无名时回退「宠物 #号」（与好友列表同一口径）
    static func displayName(petNo: Int, name: String) -> String {
        name.isEmpty ? "宠物 #\(petNo)" : "\(name) #\(petNo)"
    }

    /// 心跳下发的一批消息入口：可能混着好几位好友的留言，只打开最近一位的会话
    /// （其余未确认已读的不会被丢掉，服务端到点会重投，届时再弹窗）
    static func present(messages: [PetChatMessage]) {
        // 服务端按发送时间旧 → 新返回，末条即最近一位发言人
        guard let latest = messages.last(where: { $0.fromPetNo > 0 }) else { return }
        let group = messages.filter { $0.fromPetNo == latest.fromPetNo }
        let ids = group.map { $0.id }.filter { !$0.isEmpty }
        present(
            friendPetNo: latest.fromPetNo,
            friendDisplay: FriendChatWindow.displayName(petNo: latest.fromPetNo, name: latest.fromName),
            incoming: group,
            unreadIDs: ids
        )
    }

    /// 弹出与某位好友的会话窗。
    /// - Parameters:
    ///   - incoming: 本次心跳下发的待展示消息（先即时上屏，随后由历史记录整体替换）
    ///   - unreadIDs: incoming 对应的消息 ID，关卡时上报已读
    static func present(friendPetNo: Int, friendDisplay: String, incoming: [PetChatMessage] = [], unreadIDs: [String] = []) {
        // 同一位好友的会话窗已经开着：只并入新消息并置顶，不重开、不丢用户正在输入的内容
        if let existing = current, existing.isVisible, existing.friendPetNo == friendPetNo {
            existing.absorb(incoming: incoming, unreadIDs: unreadIDs)
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }
        // 换人会话：旧窗静默关掉（清掉 onClose 避免把没看的消息误标已读，服务端稍后会重投）
        if let old = current {
            old.onClose = nil
            old.closeWindow()
        }

        let window = FriendChatWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 380, height: 620),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.friendPetNo = friendPetNo
        window.friendDisplay = friendDisplay
        window.unreadIDs = unreadIDs
        window.rows = incoming
        window.hasShadow = false
        window.setupWebView()
        // 先把本次收到的消息排上屏（页面未加载完会暂存到 didFinish），
        // 历史记录随后到达时整体替换，拉不到也不至于出现「有未读却空窗」
        window.renderRows()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        current = window

        // 关卡时确认已读：只回本次下发的 ID，历史里更早的消息早已处理过
        window.onClose = { [weak window] in
            guard let window else { return }
            if FriendChatWindow.current === window { FriendChatWindow.current = nil }
            let ids = window.unreadIDs
            guard !ids.isEmpty else { return }
            Task { await FriendService.confirmRead(ids: ids) }
        }
        window.loadHistory()
    }

    /// 同好友会话窗已开着又来了新消息：并入待展示行与待确认 ID
    private func absorb(incoming: [PetChatMessage], unreadIDs newIDs: [String]) {
        let knownMessages = Set(rows.map { $0.id }.filter { !$0.isEmpty })
        for msg in incoming where msg.id.isEmpty || !knownMessages.contains(msg.id) {
            rows.append(msg)
        }
        let knownIDs = Set(unreadIDs)
        unreadIDs.append(contentsOf: newIDs.filter { !knownIDs.contains($0) })
        renderRows()
    }

    // MARK: - 数据

    /// 拉服务端聊天记录；失败时保留本次下发的消息（旧服务端没有 history 接口也能用）
    private func loadHistory() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let petNo = self.friendPetNo
            do {
                let history = try await FriendService.conversationHistory(with: petNo)
                guard self.friendPetNo == petNo, self.isVisible else { return }
                // 留痕被上限截掉时历史可能为空：此时保留本次下发的消息，不把用户正要看的那条抹掉
                guard !history.isEmpty else {
                    self.setStatus("暂时只显示本次收到的消息（服务端还没有可回看的历史）")
                    return
                }
                // 请求期间刚发出去的消息还没进历史，接在末尾避免「我说的话不见了」
                let sentIds = Set(history.map { $0.id })
                let carried = self.optimistic.filter { $0.id.isEmpty || !sentIds.contains($0.id) }
                self.rows = history + carried
                self.renderRows()
            } catch {
                guard self.friendPetNo == petNo, self.isVisible else { return }
                self.setStatus("聊天记录拉取失败：\(error.localizedDescription)")
            }
        }
    }

    /// 发一条消息给当前好友：成功后本地上屏并标「未读」，等下次打开会话由历史校正
    private func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard friendPetNo > 0 else {
            setStatus("还没确定要发给谁，请先从好友列表打开会话")
            return
        }
        setStatus("发送中…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await FriendService.sendMessage(toPetNo: self.friendPetNo, text: trimmed)
                let mine = PetChatMessage(
                    id: "", fromPetNo: FriendService.myPetNo,
                    fromName: PetName.currentName(), text: trimmed,
                    sentAt: Date(), isRead: false
                )
                self.rows.append(mine)
                self.optimistic.append(mine)
                self.renderRows()
                self.setStatus("已发送，对方下次联网就能看到（通常 1 分钟内）")
            } catch {
                self.setStatus("发送失败：\(error.localizedDescription)")
            }
        }
    }

    /// 会话行转 JS 数组字面量（时间给毫秒，由页面按本地时区格式化）
    private func rowsScriptLiteral() -> String {
        let payload: [[String: Any]] = rows.map { row in
            var dict: [String: Any] = [
                "mine": row.fromPetNo != friendPetNo,
                "text": row.text,
                "read": row.isRead,
            ]
            if let sentAt = row.sentAt {
                dict["ms"] = sentAt.timeIntervalSince1970 * 1000
            }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        // 转义 < 防 </script> 提前闭合
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    /// 把会话行交给页面渲染（页面还没加载完则暂存，didFinish 时补一次）
    private func renderRows() {
        let literal = rowsScriptLiteral()
        guard isPageLoaded, let webView = webView else {
            pendingRowsLiteral = literal
            return
        }
        webView.evaluateJavaScript("chatRows = \(literal); renderChat();", completionHandler: nil)
    }

    /// 更新底部状态行（发送结果、拉取失败提示都走这里）
    private func setStatus(_ text: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let literal = String(jsonStr.dropFirst().dropLast())
        guard isPageLoaded, let webView = webView else {
            // 状态是即时反馈，页面没起来时不值得暂存（用户还看不到）
            _ = literal
            return
        }
        webView.evaluateJavaScript("setStatus(\(literal));", completionHandler: nil)
    }

    // MARK: - 窗口与页面

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.setValue(false, forKey: "drawsBackground")

        let close = CloseMessageHandler { [weak self] in
            DispatchQueue.main.async { self?.closeWindow() }
        }
        self.closeHandler = close
        config.userContentController.add(close, name: "close")

        let send = ChatSendHandler { [weak self] text in
            DispatchQueue.main.async { self?.send(text: text) }
        }
        self.chatSendHandler = send
        config.userContentController.add(send, name: "chatSend")

        webView = FirstMouseWebView(frame: contentView?.bounds ?? .zero, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        var frameConfig = CardFrame.Config(title: "💬 \(FriendChatWindow.htmlEscape(friendDisplay))", body: Self.bodyHTML(placeholder: "回复 \(friendDisplay)…"))
        frameConfig.showHeader = true
        frameConfig.showFooter = false
        frameConfig.cardWidth = targetWidth
        frameConfig.extraCSS = Self.chatCSS
        let html = CardFrame.render(frameConfig)
        webView.loadHTMLString(html, baseURL: nil)

        contentView?.addSubview(webView)
    }

    /// 页面骨架：会话区（固定高度、内部滚动）+ 输入行 + 状态行
    private static func bodyHTML(placeholder: String) -> String {
        """
        <div class="chat-thread" id="chatThread"><div class="chat-empty">正在加载聊天记录…</div></div>
        <div class="chat-compose">
            <input type="text" id="chatInput" placeholder="\(FriendChatWindow.htmlEscape(placeholder))" />
            <button type="button" class="chat-send" onclick="sendChat()">发送 ✉️</button>
        </div>
        <div class="chat-status" id="chatStatus">看完点 ✕ 关闭（关闭后对方能看到已读）</div>
        <script>
        var chatRows = [];
        function chatEsc(s) {
            return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        }
        function chatTime(ms) {
            if (!ms) { return ''; }
            var d = new Date(ms), pad = function(n) { return (n < 10 ? '0' : '') + n; };
            var hm = pad(d.getHours()) + ':' + pad(d.getMinutes());
            var now = new Date();
            if (d.toDateString() === now.toDateString()) { return hm; }
            return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hm;
        }
        function renderChat() {
            var el = document.getElementById('chatThread');
            if (!el) { return; }
            if (!chatRows.length) {
                el.innerHTML = '<div class="chat-empty">还没有聊天记录，发第一条打个招呼吧～</div>';
                return;
            }
            var html = '';
            chatRows.forEach(function(r) {
                var meta = chatTime(r.ms);
                if (r.mine) { meta += (meta ? ' · ' : '') + (r.read ? '已读' : '未读'); }
                html += '<div class="chat-row' + (r.mine ? ' mine' : '') + '">'
                     +  '<div class="chat-bubble">' + chatEsc(r.text) + '</div>'
                     +  (meta ? '<div class="chat-meta">' + chatEsc(meta) + '</div>' : '')
                     +  '</div>';
            });
            el.innerHTML = html;
            el.scrollTop = el.scrollHeight;
        }
        function setStatus(t) {
            var el = document.getElementById('chatStatus');
            if (el) { el.textContent = t; }
        }
        function sendChat() {
            var i = document.getElementById('chatInput');
            var v = i ? (i.value || '').trim() : '';
            if (!v) { return; }
            if (i) { i.value = ''; }
            window.webkit.messageHandlers.chatSend.postMessage(v);
        }
        document.addEventListener('keydown', function(e) {
            var i = document.getElementById('chatInput');
            if (e.key === 'Enter' && i && document.activeElement === i) {
                e.preventDefault();
                sendChat();
            }
        });
        </script>
        """
    }

    /// 会话区样式：气泡左（对方）右（我方）分侧，深色卡片配色与其余弹窗一致
    private static let chatCSS = """
    .chat-thread {
        height: 260px;
        overflow-y: auto;
        padding: 4px 2px 8px;
        display: flex;
        flex-direction: column;
        gap: 10px;
    }
    .chat-empty { text-align: center; padding: 90px 10px; color: #8a90b8; font-size: 14px; }
    .chat-row { max-width: 78%; align-self: flex-start; }
    .chat-row.mine { align-self: flex-end; text-align: right; }
    .chat-bubble {
        display: inline-block;
        padding: 9px 13px;
        border-radius: 16px;
        font-size: 14px;
        line-height: 1.6;
        text-align: left;
        white-space: pre-wrap;
        word-break: break-word;
        background: rgba(255,255,255,0.08);
        border: 1px solid rgba(255,255,255,0.06);
        color: #f0f0f5;
    }
    .chat-row.mine .chat-bubble {
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        border-color: transparent;
        color: #fff;
    }
    .chat-meta { margin-top: 4px; font-size: 11px; color: #8a90b8; }
    .chat-compose { display: flex; gap: 8px; margin-top: 10px; }
    .chat-compose input {
        flex: 1;
        min-width: 0;
        padding: 10px 12px;
        border-radius: 18px;
        border: 1px solid rgba(255,255,255,0.12);
        background: rgba(255,255,255,0.06);
        color: #f0f0f5;
        font-size: 14px;
        outline: none;
        -webkit-appearance: none;
    }
    .chat-compose input:focus { border-color: rgba(102,126,234,0.6); }
    .chat-send {
        flex-shrink: 0;
        padding: 0 16px;
        border-radius: 18px;
        border: none;
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        color: #fff;
        font-size: 13px;
        cursor: pointer;
        -webkit-appearance: none;
    }
    .chat-send:active { opacity: 0.85; }
    .chat-status { margin-top: 8px; font-size: 11px; color: #8a90b8; line-height: 1.6; }
    """

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 网页内 ✕ 关闭路径（与 HTMLAlertWindow 一致：orderOut 隐藏 + 回调）
    private func closeWindow() {
        removeScriptMessageHandlers()
        orderOut(nil)
        onClose?()
    }

    private func removeScriptMessageHandlers() {
        guard let ucc = webView?.configuration.userContentController else { return }
        ucc.removeScriptMessageHandler(forName: "close")
        if chatSendHandler != nil { ucc.removeScriptMessageHandler(forName: "chatSend") }
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        backgroundColor = .clear
        isOpaque = false
        // 提醒卡必须「被看到」：.floating 高于普通窗口、又低于宠物窗的 .popUpMenu，并可跨 Space 跟随
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.midY - self.frame.height / 2))
    }
}

extension FriendChatWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        let measureJS = """
        (function() {
            var c = document.querySelector('.card');
            if (!c) { return document.documentElement.scrollHeight; }
            c.style.height = 'auto';
            // 直接测卡片自身高度：body 为 height:100% 的 flex，
            // documentElement.scrollHeight 会等于视口高（初始 620），测不到卡片真实高度
            return c.getBoundingClientRect().height;
        })()
        """
        webView.evaluateJavaScript(measureJS) { [weak self] result, _ in
            guard let self = self, !self.hasSized else { return }
            self.hasSized = true

            let contentHeight: CGFloat
            if let h = result as? CGFloat { contentHeight = h }
            else if let h = result as? NSNumber { contentHeight = CGFloat(h.doubleValue) }
            else { contentHeight = 420 }

            let maxH = min((NSScreen.main?.visibleFrame.height ?? 800) * 0.8, 620)
            let targetH = max(320, min(contentHeight + 24, maxH))
            var frame = self.frame
            frame.size.width = self.targetWidth
            frame.size.height = targetH
            self.setFrame(frame, display: true)
            self.centerOnScreen()

            // 标题栏拖动条：borderless 窗口里 WKWebView 会吞掉标题区鼠标事件，
            // isMovableByWindowBackground 拖不动，只能挂原生拖动条；右侧给 ✕ 让位
            let dragView = DraggableTitleView(frame: NSRect(x: 0, y: self.frame.height - 48, width: self.frame.width - 60, height: 48))
            dragView.autoresizingMask = [.width, .minYMargin]
            self.contentView?.addSubview(dragView)

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                self.animator().alphaValue = 1.0
            })

            // 加载完成前已到达的会话行：此时补渲染
            if let pending = self.pendingRowsLiteral {
                self.pendingRowsLiteral = nil
                webView.evaluateJavaScript("chatRows = \(pending); renderChat();", completionHandler: nil)
            }
        }
    }
}

/// 聊天窗「发送」消息处理器（与 HTMLAlertWindow 的 handler 风格一致）
class ChatSendHandler: NSObject, WKScriptMessageHandler {
    private let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        action(message.body as? String ?? "")
    }
}
