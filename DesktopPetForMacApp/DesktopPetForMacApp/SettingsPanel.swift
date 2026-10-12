// SettingsPanel.swift
// DesktopPetForMacApp — 菜单栏设置面板（状态切换）

import AppKit

final class SettingsPanel: NSPanel {
    private weak var viewModel: PetViewModel?
    private var stateButtons: [CatAnimationState: NSButton] = [:]

    init(viewModel: PetViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.isReleasedWhenClosed = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        setupUI()
    }

    private func setupUI() {
        let contentView = self.contentView!

        // 半透明背景
        let bgView = NSVisualEffectView(frame: contentView.bounds)
        bgView.material = .popover
        bgView.blendingMode = .behindWindow
        bgView.state = .active
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 18
        bgView.autoresizingMask = [.width, .height]
        contentView.addSubview(bgView)

        // 关闭按钮
        let closeBtn = NSButton(frame: NSRect(x: 20, y: 280, width: 24, height: 24))
        closeBtn.title = "✕"
        closeBtn.bezelStyle = .circular
        closeBtn.target = self
        closeBtn.action = #selector(closePanel)
        closeBtn.font = .boldSystemFont(ofSize: 13)
        closeBtn.contentTintColor = .secondaryLabelColor
        contentView.addSubview(closeBtn)

        // 标题
        let titleLabel = NSTextField(labelWithString: "🐱 小猫状态设置")
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 0, y: 258, width: 540, height: 28)
        contentView.addSubview(titleLabel)

        // 卡片式状态按钮
        let states: [(CatAnimationState, String)] = [
            (.focus, "💼"),
            (.idel,  "☕"),
            (.sleep, "😴"),
            (.pet,   "🍽️")
        ]
        let cardW: CGFloat = 100
        let cardH: CGFloat = 120
        let spacing: CGFloat = 20
        let totalW = CGFloat(states.count) * cardW + CGFloat(states.count - 1) * spacing
        let startX = (540 - totalW) / 2
        let startY: CGFloat = 96

        for (index, (state, emoji)) in states.enumerated() {
            let x = startX + CGFloat(index) * (cardW + spacing)
            let card = makeCardButton(
                frame: NSRect(x: x, y: startY, width: cardW, height: cardH),
                state: state,
                emoji: emoji
            )
            contentView.addSubview(card)
            stateButtons[state] = card
        }
    }

    private func makeCardButton(frame: NSRect, state: CatAnimationState, emoji: String) -> NSButton {
        let btn = NSButton(frame: frame)
        btn.title = emoji
        btn.target = self
        btn.action = #selector(stateButtonClicked(_:))
        btn.tag = state.hashValue
        btn.font = .systemFont(ofSize: 38)
        btn.setButtonType(.toggle)
        btn.state = (viewModel?.animationState == state) ? .on : .off
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 14
        btn.layer?.masksToBounds = true

        let isSelected = viewModel?.animationState == state
        btn.layer?.borderWidth = isSelected ? 3 : 1.5
        btn.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        btn.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor

        // 文字标签
        let label = NSTextField(labelWithString: state.displayName)
        label.font = .boldSystemFont(ofSize: 13)
        label.textColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 14, width: frame.width, height: 18)
        btn.addSubview(label)

        return btn
    }

    @objc private func stateButtonClicked(_ sender: NSButton) {
        guard let state = stateButtons.first(where: { $0.value == sender })?.key else { return }

        for (s, btn) in stateButtons {
            let isSelected = (s == state)
            btn.state = isSelected ? .on : .off
            btn.layer?.borderWidth = isSelected ? 3 : 1.5
            btn.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            btn.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
                : NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor

            // 更新标签颜色
            if let label = btn.subviews.first(where: { $0 is NSTextField }) as? NSTextField {
                label.textColor = isSelected ? .controlAccentColor : .secondaryLabelColor
            }
        }

        viewModel?.transitionTo(state)
    }

    @objc private func closePanel() {
        orderOut(nil)
    }

    /// 屏幕居中弹出
    func showCentered() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFront(nil)
    }
}
