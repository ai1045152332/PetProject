// SettingsPanel.swift
// DesktopPetForMacApp — 菜单栏设置面板（左侧一级导航 + 右侧内容区）

import AppKit

final class SettingsPanel: NSPanel {
    private weak var viewModel: PetViewModel?
    private var stateButtons: [CatAnimationState: NSButton] = [:]
    private var navButtons: [NSButton] = []
    private var contentViews: [NSView] = []
    private var currentSection = 0

    private let panelSize = NSSize(width: 720, height: 500)
    private let navWidth: CGFloat = 160
    private let inset: CGFloat = 16

    init(viewModel: PetViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height),
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
        let W = panelSize.width
        let H = panelSize.height

        // ── 最上层毛玻璃底板 ────────────────────────────
        let bgView = NSVisualEffectView(frame: contentView.bounds)
        bgView.material = .popover
        bgView.blendingMode = .behindWindow
        bgView.state = .active
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 18
        bgView.autoresizingMask = [.width, .height]
        contentView.addSubview(bgView)

        // ── 顶部标题栏 ──────────────────────────────────
        let titleLabel = NSTextField(labelWithString: "设置")
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 0, y: H - 44, width: W, height: 28)
        contentView.addSubview(titleLabel)

        // 关闭按钮（右上角）
        let closeBtn = NSButton(frame: NSRect(x: W - 44, y: H - 42, width: 26, height: 26))
        closeBtn.title = "✕"
        closeBtn.bezelStyle = .circular
        closeBtn.target = self
        closeBtn.action = #selector(closePanel)
        closeBtn.font = .boldSystemFont(ofSize: 13)
        closeBtn.contentTintColor = .secondaryLabelColor
        closeBtn.wantsLayer = true
        closeBtn.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.20).cgColor
        contentView.addSubview(closeBtn)

        // ── 主体区（标题栏下方） ─────────────────────────
        let bodyTop = H - 44 - 14
        let bodyH = bodyTop - 14

        // 左侧导航容器
        let navFrame = NSRect(x: inset, y: 14, width: navWidth, height: bodyH)
        let navBg = NSView(frame: navFrame)
        navBg.wantsLayer = true
        navBg.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
        navBg.layer?.cornerRadius = 12
        // 左侧导航固定宽，高度随窗口拉伸
        navBg.autoresizingMask = [.maxYMargin, .minYMargin, .height]
        contentView.addSubview(navBg)

        // 左侧导航项：固定从上往下顺序排列（不随高度自适应）
        let navTitles = ["🐱 小猫状态", "📊 菜单栏指标"]
        let itemH: CGFloat = 44
        let itemGap: CGFloat = 10
        let navTopPad: CGFloat = 12
        for (i, title) in navTitles.enumerated() {
            // 从容器顶部向下依次排布（第 0 项贴顶部留白，其余依次 + 固定间隙）
            let y = navFrame.maxY - navTopPad - CGFloat(i) * (itemH + itemGap) - itemH
            let btn = NSButton(title: title, target: self, action: #selector(selectSection(_:)))
            btn.frame = NSRect(x: navFrame.minX + 6, y: y, width: navWidth - 12, height: itemH)
            btn.isBordered = false
            btn.alignment = .left
            btn.font = .systemFont(ofSize: 13, weight: .medium)
            btn.tag = i
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 8
            contentView.addSubview(btn)
            navButtons.append(btn)
        }

        // 右侧内容区（两个窗口叠在同一 frame，按导航切换；随窗口加宽加高自适应）
        let contentX = inset + navWidth + 14
        let contentW = W - contentX - inset
        let contentFrame = NSRect(x: contentX, y: 14, width: contentW, height: bodyH)

        let section0 = makeContentContainer(frame: contentFrame, in: contentView)
        let section1 = makeContentContainer(frame: contentFrame, in: contentView)
        section1.isHidden = true
        contentViews = [section0, section1]

        fillStateSection(section0)
        fillMetricsSection(section1)

        applyNavStyle()
    }

    // MARK: - 内容容器

    private func makeContentContainer(frame: NSRect, in parent: NSView) -> NSView {
        let v = NSView(frame: frame)
        // 右侧内容区随窗口加宽加高自适应（左侧固定、下随动、宽高拉伸）
        v.autoresizingMask = [.width, .height, .minYMargin, .minXMargin]
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        v.layer?.cornerRadius = 12
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        parent.addSubview(v)
        return v
    }

    // MARK: - 分区 1：小猫状态

    private func fillStateSection(_ container: NSView) {
        let cw = container.bounds.width
        let ch = container.bounds.height

        let titleLbl = NSTextField(labelWithString: "小猫状态")
        titleLbl.font = .systemFont(ofSize: 16, weight: .bold)
        titleLbl.textColor = .labelColor
        titleLbl.frame = NSRect(x: 16, y: ch - 42, width: cw - 32, height: 22)
        container.addSubview(titleLbl)

        let descLbl = NSTextField(labelWithString: "选择小猫当前的动画状态")
        descLbl.font = .systemFont(ofSize: 11)
        descLbl.textColor = .tertiaryLabelColor
        descLbl.frame = NSRect(x: 16, y: ch - 58, width: cw - 32, height: 15)
        container.addSubview(descLbl)

        let divider = NSBox(frame: NSRect(x: 16, y: ch - 66, width: cw - 32, height: 1))
        divider.boxType = .separator
        container.addSubview(divider)

        let states: [(CatAnimationState, String)] = [
            (.focus, "💼"),
            (.idel,  "☕"),
            (.sleep, "😴"),
            (.pet,   "🍽️")
        ]
        let cardW: CGFloat = 96
        let cardH: CGFloat = 104
        let totalCardsW = CGFloat(states.count) * cardW
        let gap = (cw - 32 - totalCardsW) / CGFloat(states.count + 1)
        let cardY = ch - 66 - 18 - cardH
        var cardX = 16 + gap
        for (state, emoji) in states {
            let card = makeCardButton(frame: NSRect(x: cardX, y: cardY, width: cardW, height: cardH), state: state, emoji: emoji)
            container.addSubview(card)
            stateButtons[state] = card
            cardX += cardW + gap
        }
    }

    // MARK: - 分区 2：菜单栏显示指标

    private func fillMetricsSection(_ container: NSView) {
        let cw = container.bounds.width
        let ch = container.bounds.height

        let titleLbl = NSTextField(labelWithString: "菜单栏显示指标")
        titleLbl.font = .systemFont(ofSize: 16, weight: .bold)
        titleLbl.textColor = .labelColor
        titleLbl.frame = NSRect(x: 16, y: ch - 42, width: cw - 32, height: 22)
        container.addSubview(titleLbl)

        let descLbl = NSTextField(labelWithString: "选择要显示在顶部菜单栏的监控指标")
        descLbl.font = .systemFont(ofSize: 11)
        descLbl.textColor = .tertiaryLabelColor
        descLbl.frame = NSRect(x: 16, y: ch - 58, width: cw - 32, height: 15)
        container.addSubview(descLbl)

        let divider = NSBox(frame: NSRect(x: 16, y: ch - 66, width: cw - 32, height: 1))
        divider.boxType = .separator
        container.addSubview(divider)

        let checkboxes: [(String, String, Int)] = [
            ("CPU 占用率", SystemMonitor.MenuPrefs.showCPU, 0),
            ("内存占用率", SystemMonitor.MenuPrefs.showMemory, 1),
            ("CPU 温度", SystemMonitor.MenuPrefs.showTemp, 2)
        ]
        let cbW: CGFloat = 140
        let cbSpace: CGFloat = 16
        let cbTotal = CGFloat(checkboxes.count) * cbW + CGFloat(checkboxes.count - 1) * cbSpace
        let cbStartX = (cw - cbTotal) / 2
        let cbY = ch - 66 - 30
        for (index, (title, key, tag)) in checkboxes.enumerated() {
            let btn = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleMenuMetric(_:)))
            btn.frame = NSRect(x: cbStartX + CGFloat(index) * (cbW + cbSpace), y: cbY, width: cbW, height: 22)
            btn.tag = tag
            btn.state = SystemMonitor.MenuPrefs.isOn(key, default: true) ? .on : .off
            container.addSubview(btn)
        }
    }

    // MARK: - 左侧导航

    @objc private func selectSection(_ sender: NSButton) {
        currentSection = sender.tag
        for (i, v) in contentViews.enumerated() {
            v.isHidden = (i != currentSection)
        }
        applyNavStyle()
    }

    private func applyNavStyle() {
        for (i, btn) in navButtons.enumerated() {
            let selected = (i == currentSection)
            btn.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : .clear
            let color: NSColor = selected ? .controlAccentColor : .secondaryLabelColor
            let attr = NSAttributedString(
                string: btn.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
                    .foregroundColor: color
                ]
            )
            btn.attributedTitle = attr
        }
    }

    // MARK: - 状态卡片按钮

    private func makeCardButton(frame: NSRect, state: CatAnimationState, emoji: String) -> NSButton {
        let btn = NSButton(frame: frame)
        btn.title = emoji
        btn.target = self
        btn.action = #selector(stateButtonClicked(_:))
        btn.tag = state.hashValue
        btn.font = .systemFont(ofSize: 34)
        btn.setButtonType(.toggle)
        btn.state = (viewModel?.animationState == state) ? .on : .off
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 12
        btn.layer?.masksToBounds = true

        applyCardStyle(btn, selected: viewModel?.animationState == state)

        let label = NSTextField(labelWithString: state.displayName)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 8, width: frame.width, height: 16)
        label.tag = 991
        btn.addSubview(label)

        return btn
    }

    private func applyCardStyle(_ btn: NSButton, selected: Bool) {
        btn.layer?.borderWidth = selected ? 2 : 1
        btn.layer?.borderColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        btn.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            : NSColor(white: 0, alpha: 0.04).cgColor
        if let label = btn.subviews.first(where: { $0.tag == 991 }) as? NSTextField {
            label.textColor = selected ? .controlAccentColor : .secondaryLabelColor
        }
    }

    @objc private func stateButtonClicked(_ sender: NSButton) {
        guard let state = stateButtons.first(where: { $0.value == sender })?.key else { return }
        for (s, btn) in stateButtons {
            applyCardStyle(btn, selected: s == state)
        }
        viewModel?.transitionTo(state)
    }

    @objc private func toggleMenuMetric(_ sender: NSButton) {
        let key: String
        switch sender.tag {
        case 1:  key = SystemMonitor.MenuPrefs.showMemory
        case 2:  key = SystemMonitor.MenuPrefs.showTemp
        default: key = SystemMonitor.MenuPrefs.showCPU
        }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
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