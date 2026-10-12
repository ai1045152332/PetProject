// AuthManager.swift
// DesktopPetForMacApp — 启动密码验证
// 当前为写死密码，后续改为接口授权

import AppKit

/// 可成为 key/main 的密码面板（NSWindow 的 canBecomeKey 是只读属性，需子类覆写）
private final class AuthPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AuthManager: NSObject, NSTextFieldDelegate {

    // MARK: - 配置

    /// 当前硬编码密码（后续替换为接口授权）
    private let hardcodedPassword = "456"

    /// 最大尝试次数
    private let maxAttempts = 3

    // MARK: - 状态

    private var attempts = 0
    private var onSuccess: (() -> Void)?

    // MARK: - UI

    private var window: NSWindow?
    private weak var passwordField: NSSecureTextField?
    private weak var errorLabel: NSTextField?
    private weak var attemptLabel: NSTextField?

    // MARK: - 公开方法

    /// 显示密码验证弹窗
    /// - Parameter completion: 验证通过后回调（在主线程执行）
    func showAuthWindow(onSuccess: @escaping () -> Void) {
        self.onSuccess = onSuccess

        let win = AuthPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .modalPanel
        win.isReleasedWhenClosed = false
        // 隐藏标题栏按钮
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true

        buildUI(in: win)
        centerWindow(win)
        self.window = win
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()

        // 聚焦到密码输入框
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.passwordField?.becomeFirstResponder()
        }
    }

    // MARK: - UI 构建

    private func buildUI(in window: NSWindow) {
        let W: CGFloat = 380
        let H: CGFloat = 300

        // 毛玻璃底板
        let contentView = window.contentView!
        let bgView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        bgView.material = .popover
        bgView.blendingMode = .behindWindow
        bgView.state = .active
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 18
        bgView.autoresizingMask = [.width, .height]
        contentView.addSubview(bgView)

        // 顶部图标区
        let iconLabel = NSTextField(labelWithString: "🔐")
        iconLabel.font = .systemFont(ofSize: 48)
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 0, y: H - 90, width: W, height: 60)
        contentView.addSubview(iconLabel)

        // 标题
        let titleLabel = NSTextField(labelWithString: "DesktopPetForMacApp")
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 0, y: H - 118, width: W, height: 22)
        contentView.addSubview(titleLabel)

        // 提示文字
        let hintLabel = NSTextField(labelWithString: "请输入密码以启动应用")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: 0, y: H - 140, width: W, height: 16)
        contentView.addSubview(hintLabel)

        // 密码输入框
        let field = NSSecureTextField(frame: NSRect(x: 50, y: H - 185, width: W - 100, height: 34))
        field.font = .systemFont(ofSize: 15)
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.placeholderString = "请输入密码"
        field.delegate = self
        contentView.addSubview(field)
        passwordField = field

        // 确认按钮
        let btn = NSButton(frame: NSRect(x: 50, y: H - 230, width: W - 100, height: 36))
        btn.title = "确认"
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 14, weight: .medium)
        btn.keyEquivalent = "\r"
        btn.target = self
        btn.action = #selector(verifyPassword)
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 10
        contentView.addSubview(btn)

        // 错误提示（初始隐藏）
        let errLabel = NSTextField(labelWithString: "")
        errLabel.font = .systemFont(ofSize: 12)
        errLabel.textColor = .systemRed
        errLabel.alignment = .center
        errLabel.frame = NSRect(x: 0, y: H - 260, width: W, height: 16)
        errLabel.isHidden = true
        contentView.addSubview(errLabel)
        errorLabel = errLabel

        // 剩余次数提示（初始隐藏）
        let attLabel = NSTextField(labelWithString: "")
        attLabel.font = .systemFont(ofSize: 11)
        attLabel.textColor = .tertiaryLabelColor
        attLabel.alignment = .center
        attLabel.frame = NSRect(x: 0, y: H - 278, width: W, height: 14)
        attLabel.isHidden = true
        contentView.addSubview(attLabel)
        attemptLabel = attLabel
    }

    // MARK: - 验证逻辑

    @objc private func verifyPassword() {
        guard let field = passwordField else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空密码：不消耗尝试次数，仅提示
        guard !input.isEmpty else {
            showError("请输入密码")
            field.becomeFirstResponder()
            return
        }

        // TODO: 后续替换为接口授权
        // let authorized = await requestAPIAuth(password: input)
        let authorized = (input == hardcodedPassword)

        if authorized {
            // 验证通过
            window?.orderOut(nil)
            onSuccess?()
        } else {
            // 验证失败
            attempts += 1
            let remaining = maxAttempts - attempts

            if remaining <= 0 {
                // 次数用尽，退出
                showError("密码错误次数过多，程序即将退出")
                attemptLabel?.isHidden = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    NSApp.terminate(nil)
                }
            } else {
                showError("密码错误，请重试")
                attemptLabel?.isHidden = false
                attemptLabel?.stringValue = "还可尝试 \(remaining) 次"
                field.stringValue = ""
                field.becomeFirstResponder()
            }
        }
    }

    private func showError(_ message: String) {
        errorLabel?.isHidden = false
        errorLabel?.stringValue = message
    }

    // MARK: - NSTextFieldDelegate（回车触发验证）

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === passwordField else { return }
        // 未输入任何内容时（如失焦、切窗）不触发验证，避免"还没输入就报密码错误"
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        verifyPassword()
    }

    // MARK: - 辅助

    private func centerWindow(_ win: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - win.frame.width / 2
        let y = frame.midY - win.frame.height / 2
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
