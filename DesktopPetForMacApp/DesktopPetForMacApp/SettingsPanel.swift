// SettingsPanel.swift
// DesktopPetForMacApp — 菜单栏设置面板（左侧一级导航 + 右侧内容区）

import AppKit

/// 宠物名称管理（默认「毛豆」）
enum PetName {
    static let prefsKey = "settings.petName"
    static let defaultName = "毛豆"

    /// 当前宠物名称（未设置或为空时回退默认）
    static func currentName() -> String {
        let saved = UserDefaults.standard.string(forKey: prefsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultName : saved
    }

    /// 保存宠物名称（空输入回退默认）
    static func setName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? defaultName : trimmed, forKey: prefsKey)
    }
}

final class SettingsPanel: NSPanel, NSTextFieldDelegate {
    private weak var viewModel: PetViewModel?
    private var stateButtons: [CatAnimationState: NSButton] = [:]
    private var navButtons: [NSButton] = []
    private var contentViews: [NSView] = []
    private var currentSection = 0
    private weak var petNameField: NSTextField?
    private weak var petNameEditBtn: NSButton?
    private weak var petNameSaveBtn: NSButton?

    private let panelSize = NSSize(width: 720, height: 500)
    private let navWidth: CGFloat = 160
    private let inset: CGFloat = 16

    init(viewModel: PetViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.isReleasedWhenClosed = false
        self.title = "设置"
        setupUI()
    }

    /// 覆写为可成为 key window，让「宠物名称」输入框能获得焦点并正常编辑。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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

        // ── 主体区（系统标题栏下方） ─────────────────────
        let bodyTop = H - 14
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
        // 注：菜单栏指标的勾选已迁移到菜单栏「系统信息 ▸」二级菜单，设置面板不再提供
        let navTitles = ["🐱 宠物状态", "⚙️ 通用设置"]
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
        fillGeneralSection(section1)

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

    // MARK: - 分区 1：宠物状态

    private func fillStateSection(_ container: NSView) {
        let cw = container.bounds.width
        let ch = container.bounds.height

        let titleLbl = NSTextField(labelWithString: "宠物状态")
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
            (.pet,   "🐾")
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

    // MARK: - 分区 2：通用设置

    private func fillGeneralSection(_ container: NSView) {
        let cw = container.bounds.width
        let ch = container.bounds.height

        let titleLbl = NSTextField(labelWithString: "通用设置")
        titleLbl.font = .systemFont(ofSize: 16, weight: .bold)
        titleLbl.textColor = .labelColor
        titleLbl.frame = NSRect(x: 16, y: ch - 42, width: cw - 32, height: 22)
        container.addSubview(titleLbl)

        let descLbl = NSTextField(labelWithString: "应用启动行为与其他通用选项")
        descLbl.font = .systemFont(ofSize: 11)
        descLbl.textColor = .tertiaryLabelColor
        descLbl.frame = NSRect(x: 16, y: ch - 58, width: cw - 32, height: 15)
        container.addSubview(descLbl)

        let divider = NSBox(frame: NSRect(x: 16, y: ch - 66, width: cw - 32, height: 1))
        divider.boxType = .separator
        container.addSubview(divider)

        // 条目 1：宠物名称
        let nameRowY = ch - 66 - 14 - 48
        let nameRow = makeSettingRow(frame: NSRect(x: 16, y: nameRowY, width: cw - 32, height: 48), in: container)

        let nameTitle = NSTextField(labelWithString: "宠物名称")
        nameTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        nameTitle.textColor = .labelColor
        nameTitle.frame = NSRect(x: 14, y: 24, width: 200, height: 18)
        nameRow.addSubview(nameTitle)

        // 名称输入框（右侧），编辑按钮在最右，两者不重叠
        let btnW: CGFloat = 58
        let fieldW: CGFloat = 140
        let right = nameRow.bounds.width - 16
        let nameField = NSTextField(frame: NSRect(x: right - btnW - 8 - fieldW, y: 10, width: fieldW, height: 28))
        nameField.stringValue = PetName.currentName()
        nameField.font = .systemFont(ofSize: 13)
        nameField.alignment = .center
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self
        // 默认只读：必须先点「编辑」才能改
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.textColor = .labelColor
        nameRow.addSubview(nameField)
        petNameField = nameField

        // 编辑 / 保存 按钮（同一位置，互斥显示）
        let editBtn = NSButton(title: "编辑", target: self, action: #selector(editPetName(_:)))
        editBtn.frame = NSRect(x: right - btnW, y: 10, width: btnW, height: 28)
        editBtn.bezelStyle = .rounded
        editBtn.controlSize = .regular
        nameRow.addSubview(editBtn)
        petNameEditBtn = editBtn

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(savePetName(_:)))
        saveBtn.frame = NSRect(x: right - btnW, y: 10, width: btnW, height: 28)
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .regular
        saveBtn.keyEquivalent = "\r"  // 回车触发保存
        nameRow.addSubview(saveBtn)
        petNameSaveBtn = saveBtn
        updatePetNameButtons()

        // 条目 2：开机自启
        let rowY = nameRowY - 48 - 10
        let row = makeSettingRow(frame: NSRect(x: 16, y: rowY, width: cw - 32, height: 48), in: container)

        let itemTitle = NSTextField(labelWithString: "开机自启")
        itemTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        itemTitle.textColor = .labelColor
        itemTitle.frame = NSRect(x: 14, y: 24, width: 200, height: 18)
        row.addSubview(itemTitle)

        let itemDesc = NSTextField(labelWithString: "登录 macOS 后自动启动小猫")
        itemDesc.font = .systemFont(ofSize: 11)
        itemDesc.textColor = .tertiaryLabelColor
        itemDesc.frame = NSRect(x: 14, y: 6, width: 220, height: 15)
        row.addSubview(itemDesc)

        let sw = ToggleSwitch(frame: NSRect(x: row.bounds.width - 16 - 52, y: 11, width: 52, height: 26))
        sw.isOn = AutoLaunchManager.isEnabled()
        sw.onToggle = { on in
            AutoLaunchManager.setEnabled(on)
        }
        row.addSubview(sw)
    }

    /// 通用设置的行容器（统一样式）
    private func makeSettingRow(frame: NSRect, in container: NSView) -> NSView {
        let row = NSView(frame: frame)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor(white: 0, alpha: 0.04).cgColor
        row.layer?.cornerRadius = 10
        container.addSubview(row)
        return row
    }

    // MARK: - 宠物名称编辑/保存

    /// 点「编辑」：输入框变为可编辑并聚焦
    @objc private func editPetName(_ sender: NSButton) {
        guard let field = petNameField else { return }
        field.stringValue = PetName.currentName()
        field.isEditable = true
        field.isSelectable = true
        field.textColor = .labelColor
        field.becomeFirstResponder()
        updatePetNameButtons()
    }

    /// 点「保存」：写入名称并恢复只读
    @objc private func savePetName(_ sender: Any?) {
        guard let field = petNameField else { return }
        // 先置只读再失焦：避免失焦触发 controlTextDidEndEditing 递归保存
        field.isEditable = false
        field.isSelectable = false
        field.textColor = .secondaryLabelColor
        field.resignFirstResponder()
        PetName.setName(field.stringValue)
        field.stringValue = PetName.currentName()
        updatePetNameButtons()
    }

    /// 同步编辑/保存按钮状态：编辑时显示「保存」，未编辑时显示「编辑」
    private func updatePetNameButtons() {
        let editing = petNameField?.isEditable ?? false
        petNameEditBtn?.isHidden = editing
        petNameSaveBtn?.isHidden = !editing
    }

    // MARK: - NSTextFieldDelegate（失焦时若仍处于编辑态则自动保存）

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === petNameField else { return }
        // 仅当仍处于编辑态时保存（保存按钮内部已先置只读，不会重复触发）
        if field.isEditable {
            savePetName(nil)
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
        viewModel?.transitionTo(state)
        refreshStateCards()
    }
    
    /// 根据 viewModel 当前真实动画状态刷新所有状态卡片的选中样式
    /// （在面板显示时和动画状态变化时调用，保证面板与真实状态同步）
    func refreshStateCards() {
        guard let current = viewModel?.animationState else { return }
        for (s, btn) in stateButtons {
            btn.state = (current == s) ? .on : .off
            applyCardStyle(btn, selected: current == s)
        }
    }

    /// 屏幕居中弹出
    func showCentered() {
        guard let screen = NSScreen.main else { return }
        // 打开时同步一次状态卡片（面板是懒创建，动画可能已在后台变化）
        refreshStateCards()
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
        // 需要成为 key window，否则「宠物名称」输入框无法获得焦点编辑
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 自绘开关（开=绿色，关=灰色，不受窗口激活状态影响）

final class ToggleSwitch: NSView {
    var isOn: Bool = false {
        didSet { refresh(animated: true) }
    }
    var onToggle: ((Bool) -> Void)?

    private let trackLayer = CALayer()
    private let thumbLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(thumbLayer)
        refresh(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("ToggleSwitch does not support NSCoder")
    }

    override func layout() {
        super.layout()
        refresh(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?(isOn)
    }

    private func refresh(animated: Bool) {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)

        // 轨道：圆角胶囊（绿 / 灰）
        trackLayer.frame = bounds
        trackLayer.cornerRadius = h / 2
        trackLayer.backgroundColor = (isOn ? NSColor.systemGreen : NSColor.systemGray).cgColor

        // 滑块：白色圆钮，随开关左右移动
        let thumbSize = h - 6
        let x = isOn ? w - thumbSize - 3 : 3
        thumbLayer.frame = NSRect(x: x, y: 3, width: thumbSize, height: thumbSize)
        thumbLayer.cornerRadius = thumbSize / 2
        thumbLayer.backgroundColor = NSColor.white.cgColor
        thumbLayer.shadowOpacity = 0.3
        thumbLayer.shadowRadius = 1
        thumbLayer.shadowOffset = CGSize(width: 0, height: 0.5)

        CATransaction.commit()
    }
}