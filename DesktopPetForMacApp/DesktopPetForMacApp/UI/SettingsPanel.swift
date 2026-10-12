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
    private var intervalButtons: [(Int, NSButton)] = []
    private weak var customIntervalField: NSTextField?
    /// 宠物状态分区：当前状态指示标签
    private weak var currentStateBadge: NSTextField?
    private weak var currentIntervalLabel: NSTextField?

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
        self.isFloatingPanel = false
        self.level = .normal
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
        // 与窗口方形标题栏对齐，避免顶部圆弧缺口
        bgView.layer?.cornerRadius = 0
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
        let navTitles = ["🐱 宠物状态", "⚙️ 通用设置", "🔔 提醒设置"]
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
        let section2 = makeContentContainer(frame: contentFrame, in: contentView)
        section1.isHidden = true
        section2.isHidden = true
        contentViews = [section0, section1, section2]

        fillStateSection(section0)
        fillGeneralSection(section1)
        fillReminderSection(section2)

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

        // ── 头部：标题 + 宠物名称 + 当前状态徽章 ──
        let petName = PetName.currentName()
        let titleLbl = NSTextField(labelWithString: "🐱 \(petName)")
        titleLbl.font = .systemFont(ofSize: 18, weight: .bold)
        titleLbl.textColor = .labelColor
        titleLbl.frame = NSRect(x: 16, y: ch - 44, width: cw - 32, height: 24)
        container.addSubview(titleLbl)

        // 当前状态徽章
        let currentState = viewModel?.animationState ?? .idel
        let badge = NSTextField(labelWithString: "当前状态：\(currentState.displayName)")
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .controlAccentColor
        badge.frame = NSRect(x: 16, y: ch - 64, width: cw - 32, height: 16)
        container.addSubview(badge)
        currentStateBadge = badge

        let divider = NSBox(frame: NSRect(x: 16, y: ch - 76, width: cw - 32, height: 1))
        divider.boxType = .separator
        container.addSubview(divider)

        // ── 状态卡片（带副标题） ──
        let states: [(CatAnimationState, String, String)] = [
            (.focus, "💼", "工作中，请勿打扰"),
            (.idel,  "☕", "休闲放松中"),
            (.sleep, "😴", "晚安，做个好梦"),
            (.pet,   "🐾", "摸摸我，很开心")
        ]
        let cardW: CGFloat = 108
        let cardH: CGFloat = 120
        let totalCardsW = CGFloat(states.count) * cardW
        let gap = (cw - 32 - totalCardsW) / CGFloat(states.count + 1)
        let cardY = ch - 76 - 20 - cardH
        var cardX = 16 + gap
        for (state, emoji, subtitle) in states {
            let card = makeCardButton(
                frame: NSRect(x: cardX, y: cardY, width: cardW, height: cardH),
                state: state, emoji: emoji, subtitle: subtitle
            )
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

        // 条目 3：小猫大小
        let sizeRowY = rowY - 48 - 10
        let sizeRow = makeSettingRow(frame: NSRect(x: 16, y: sizeRowY, width: cw - 32, height: 56), in: container)

        let sizeTitle = NSTextField(labelWithString: "小猫大小")
        sizeTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        sizeTitle.textColor = .labelColor
        sizeTitle.frame = NSRect(x: 14, y: 32, width: 200, height: 18)
        sizeRow.addSubview(sizeTitle)

        let currentScale = viewModel?.catScale ?? PetViewModel.defaultCatScale
        let slider = NSSlider(frame: NSRect(x: 14, y: 6, width: sizeRow.bounds.width - 80, height: 20))
        slider.minValue = 0.5
        slider.maxValue = 2.0
        slider.doubleValue = currentScale
        slider.numberOfTickMarks = 4
        slider.allowsTickMarkValuesOnly = false
        slider.target = self
        slider.action = #selector(catSizeSliderChanged(_:))
        sizeRow.addSubview(slider)

        let scaleLabel = NSTextField(labelWithString: String(format: "%.1fx", currentScale))
        scaleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        scaleLabel.textColor = .secondaryLabelColor
        scaleLabel.alignment = .right
        scaleLabel.frame = NSRect(x: sizeRow.bounds.width - 58, y: 8, width: 44, height: 18)
        sizeRow.addSubview(scaleLabel)
    }

    // MARK: - 分区 3：提醒设置

    private func fillReminderSection(_ container: NSView) {
        let cw = container.bounds.width
        let ch = container.bounds.height

        let titleLbl = NSTextField(labelWithString: "提醒设置")
        titleLbl.font = .systemFont(ofSize: 16, weight: .bold)
        titleLbl.textColor = .labelColor
        titleLbl.frame = NSRect(x: 16, y: ch - 42, width: cw - 32, height: 22)
        container.addSubview(titleLbl)

        let descLbl = NSTextField(labelWithString: "设置喝水提醒的时间间隔")
        descLbl.font = .systemFont(ofSize: 11)
        descLbl.textColor = .tertiaryLabelColor
        descLbl.frame = NSRect(x: 16, y: ch - 58, width: cw - 32, height: 15)
        container.addSubview(descLbl)

        let divider = NSBox(frame: NSRect(x: 16, y: ch - 66, width: cw - 32, height: 1))
        divider.boxType = .separator
        container.addSubview(divider)

        // 预设时间间隔按钮
        let presets = [15, 30, 45, 60]
        let currentInterval = viewModel?.reminderInterval ?? PetViewModel.defaultReminderInterval

        let presetLabel = NSTextField(labelWithString: "提醒间隔")
        presetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        presetLabel.textColor = .labelColor
        presetLabel.frame = NSRect(x: 16, y: ch - 96, width: 100, height: 18)
        container.addSubview(presetLabel)

        // 当前生效的提醒间隔（预设高亮不直观，自定义间隔时更需显示）
        let currentLabel = NSTextField(labelWithString: "当前：\(currentInterval) 分钟")
        currentLabel.font = .systemFont(ofSize: 12, weight: .medium)
        currentLabel.textColor = .controlAccentColor
        currentLabel.alignment = .right
        currentLabel.frame = NSRect(x: cw - 16 - 140, y: ch - 96, width: 140, height: 18)
        container.addSubview(currentLabel)
        currentIntervalLabel = currentLabel

        let btnW: CGFloat = 68
        let btnH: CGFloat = 32
        let btnGap: CGFloat = 10
        let btnY = ch - 96 - 6
        let totalBtnsW = CGFloat(presets.count) * btnW + CGFloat(presets.count - 1) * btnGap
        var btnX = (cw - totalBtnsW) / 2

        for minutes in presets {
            let btn = NSButton(frame: NSRect(x: btnX, y: btnY, width: btnW, height: btnH))
            btn.title = "\(minutes) 分钟"
            btn.bezelStyle = .rounded
            btn.target = self
            btn.action = #selector(intervalButtonClicked(_:))
            btn.tag = minutes
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 8
            container.addSubview(btn)
            intervalButtons.append((minutes, btn))
            btnX += btnW + btnGap
        }

        refreshIntervalButtons(currentInterval: currentInterval)

        // 自定义时间输入行
        let customY = btnY - 58
        let customRow = makeSettingRow(frame: NSRect(x: 16, y: customY, width: cw - 32, height: 48), in: container)

        let customLabel = NSTextField(labelWithString: "自定义间隔")
        customLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        customLabel.textColor = .labelColor
        customLabel.frame = NSRect(x: 14, y: 24, width: 120, height: 18)
        customRow.addSubview(customLabel)

        let customDesc = NSTextField(labelWithString: "输入 1 ~ 120 之间的分钟数")
        customDesc.font = .systemFont(ofSize: 11)
        customDesc.textColor = .tertiaryLabelColor
        customDesc.frame = NSRect(x: 14, y: 6, width: 180, height: 15)
        customRow.addSubview(customDesc)

        let fieldW: CGFloat = 70
        let applyBtnW: CGFloat = 58
        let right = customRow.bounds.width - 16
        let field = NSTextField(frame: NSRect(x: right - applyBtnW - 8 - fieldW, y: 10, width: fieldW, height: 28))
        field.font = .systemFont(ofSize: 13)
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.placeholderString = "分钟"
        field.delegate = self
        customRow.addSubview(field)
        customIntervalField = field

        let applyBtn = NSButton(title: "应用", target: self, action: #selector(applyCustomInterval(_:)))
        applyBtn.frame = NSRect(x: right - applyBtnW, y: 10, width: applyBtnW, height: 28)
        applyBtn.bezelStyle = .rounded
        applyBtn.controlSize = .regular
        applyBtn.keyEquivalent = "\r"
        customRow.addSubview(applyBtn)
    }

    // MARK: - 提醒间隔操作

    @objc private func intervalButtonClicked(_ sender: NSButton) {
        let minutes = sender.tag
        viewModel?.reminderInterval = minutes
        viewModel?.restartDrinkWaterReminder()
        refreshIntervalButtons(currentInterval: minutes)
        customIntervalField?.stringValue = ""
    }

    @objc private func applyCustomInterval(_ sender: Any?) {
        guard let field = customIntervalField,
              let value = Int(field.stringValue), value >= 1, value <= 120 else { return }
        viewModel?.reminderInterval = value
        viewModel?.restartDrinkWaterReminder()
        refreshIntervalButtons(currentInterval: value)
        field.stringValue = ""
        field.resignFirstResponder()
    }

    private func refreshIntervalButtons(currentInterval: Int) {
        // 同步「当前提醒间隔」文案
        currentIntervalLabel?.stringValue = "当前：\(currentInterval) 分钟"
        for (minutes, btn) in intervalButtons {
            let selected = (minutes == currentInterval)
            btn.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor(white: 0, alpha: 0.04).cgColor
            btn.layer?.borderWidth = selected ? 1.5 : 0
            btn.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.clear.cgColor
            btn.font = selected
                ? .systemFont(ofSize: 13, weight: .semibold)
                : .systemFont(ofSize: 13)
        }
    }

    // MARK: - 小猫大小滑块

    @objc private func catSizeSliderChanged(_ sender: NSSlider) {
        // 吸附到 0.1 步长
        let raw = sender.doubleValue
        let snapped = (raw * 10).rounded() / 10.0
        sender.doubleValue = snapped

        // 更新右侧数值标签
        if let sizeRow = sender.superview,
           let label = sizeRow.subviews.compactMap({ $0 as? NSTextField })
              .first(where: { $0.alignment == .right && $0.font?.pointSize == 12 }) {
            label.stringValue = String(format: "%.1fx", snapped)
        }

        viewModel?.catScale = snapped
        viewModel?.onResizeWindow?(snapped)
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

    private func makeCardButton(frame: NSRect, state: CatAnimationState, emoji: String, subtitle: String) -> NSButton {
        let btn = NSButton(frame: frame)
        btn.title = ""
        btn.target = self
        btn.action = #selector(stateButtonClicked(_:))
        btn.tag = state.hashValue
        btn.setButtonType(.toggle)
        btn.state = (viewModel?.animationState == state) ? .on : .off
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 14
        btn.layer?.masksToBounds = true

        applyCardStyle(btn, selected: viewModel?.animationState == state)

        // Emoji（居中偏上）
        let emojiLabel = NSTextField(labelWithString: emoji)
        emojiLabel.font = .systemFont(ofSize: 36)
        emojiLabel.alignment = .center
        emojiLabel.frame = NSRect(x: 0, y: frame.height - 72, width: frame.width, height: 44)
        emojiLabel.tag = 990
        btn.addSubview(emojiLabel)

        // 状态名（居中）
        let label = NSTextField(labelWithString: state.displayName)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 28, width: frame.width, height: 16)
        label.tag = 991
        btn.addSubview(label)

        // 副标题（居中偏下）
        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.alignment = .center
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.frame = NSRect(x: 4, y: 10, width: frame.width - 8, height: 14)
        subLabel.tag = 992
        btn.addSubview(subLabel)

        return btn
    }

    private func applyCardStyle(_ btn: NSButton, selected: Bool) {
        // 背景
        btn.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor(white: 0, alpha: 0.03).cgColor
        // 边框
        btn.layer?.borderWidth = selected ? 2 : 1
        btn.layer?.borderColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        // 阴影（选中时更明显）
        btn.layer?.shadowOpacity = selected ? 0.15 : 0
        btn.layer?.shadowRadius = selected ? 6 : 0
        btn.layer?.shadowOffset = NSSize(width: 0, height: -2)
        btn.layer?.shadowColor = NSColor.controlAccentColor.cgColor

        // 状态名颜色
        if let label = btn.subviews.first(where: { $0.tag == 991 }) as? NSTextField {
            label.textColor = selected ? .controlAccentColor : .labelColor
            label.font = selected ? .systemFont(ofSize: 13, weight: .bold) : .systemFont(ofSize: 13, weight: .semibold)
        }
        // 副标题颜色
        if let sub = btn.subviews.first(where: { $0.tag == 992 }) as? NSTextField {
            sub.textColor = selected ? .controlAccentColor.withAlphaComponent(0.7) : .tertiaryLabelColor
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
        // 更新当前状态徽章
        currentStateBadge?.stringValue = "当前状态：\(current.displayName)"
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