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

    // 权限控制（通用设置 > 权限）
    var onAccessLevelChanged: (() -> Void)?
    /// 权限栏容器（用于「解锁更多功能」引导时高亮闪烁）
    private weak var accessRowView: NSView?
    private weak var catScaleSlider: NSSlider?
    private weak var accessStatusLabel: NSTextField?
    private weak var accessCodeField: NSSecureTextField?
    private weak var unlockBtn: NSButton?
    private weak var clearAccessBtn: NSButton?

    private let panelSize = NSSize(width: 720, height: 500)
    private let navWidth: CGFloat = 160
    private let inset: CGFloat = 16

    init(viewModel: PetViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
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
        let navTitles = ["🐱 宠物信息", "⚙️ 通用设置", "🔔 提醒设置"]
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

        // ── 头部：标题 + 当前状态徽章 ──
        let titleLbl = NSTextField(labelWithString: "🐱 宠物信息")
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
        divider.autoresizingMask = .width
        container.addSubview(divider)

        // ── 宠物名称条目 ──
        let nameRowY = ch - 76 - 14 - 48
        let nameRow = makeSettingRow(frame: NSRect(x: 16, y: nameRowY, width: cw - 32, height: 48), in: container)

        let nameTitle = NSTextField(labelWithString: "宠物名称")
        nameTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        nameTitle.textColor = .labelColor
        nameTitle.frame = NSRect(x: 14, y: 24, width: 200, height: 18)
        nameRow.addSubview(nameTitle)

        let btnW: CGFloat = 58
        let fieldW: CGFloat = 140
        let right = nameRow.bounds.width - 16
        let nameField = NSTextField(frame: NSRect(x: right - btnW - 8 - fieldW, y: 10, width: fieldW, height: 28))
        nameField.stringValue = PetName.currentName()
        nameField.font = .systemFont(ofSize: 13)
        nameField.alignment = .center
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.textColor = .labelColor
        nameField.autoresizingMask = .minXMargin
        nameRow.addSubview(nameField)
        petNameField = nameField

        let editBtn = NSButton(title: "编辑", target: self, action: #selector(editPetName(_:)))
        editBtn.frame = NSRect(x: right - btnW, y: 10, width: btnW, height: 28)
        editBtn.bezelStyle = .rounded
        editBtn.controlSize = .regular
        editBtn.autoresizingMask = .minXMargin
        nameRow.addSubview(editBtn)
        petNameEditBtn = editBtn

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(savePetName(_:)))
        saveBtn.frame = NSRect(x: right - btnW, y: 10, width: btnW, height: 28)
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .regular
        saveBtn.keyEquivalent = "\r"
        saveBtn.autoresizingMask = .minXMargin
        nameRow.addSubview(saveBtn)
        petNameSaveBtn = saveBtn
        updatePetNameButtons()

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
        let cardY = nameRowY - 20 - cardH
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
        divider.autoresizingMask = .width
        container.addSubview(divider)

        // ── 垂直堆栈：各行间距自动管理，新增行无需手算坐标 ──
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            // AppKit topAnchor 常量向下为正：标题+分割线共占 66pt，再加 14pt 行距
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 66 + 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        ])

        /// 堆栈内行容器：固定高度、自动铺满堆栈宽度（窗口拉伸时同步变宽）
        func makeStackRow(height: CGFloat) -> NSView {
            let row = NSView(frame: NSRect(x: 0, y: 0, width: cw - 32, height: height))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor(white: 0, alpha: 0.04).cgColor
            row.layer?.cornerRadius = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: height)
            ])
            return row
        }

        // 条目 1：开机自启
        let row = makeStackRow(height: 48)

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
        sw.autoresizingMask = .minXMargin
        sw.isOn = AutoLaunchManager.isEnabled()
        sw.onToggle = { on in
            AutoLaunchManager.setEnabled(on)
        }
        row.addSubview(sw)

        // 条目 3：小猫大小（基础权限即可调整）
        let sizeRow = makeStackRow(height: 56)

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
        // 基础权限即可调整
        slider.isEnabled = true
        sizeRow.addSubview(slider)
        catScaleSlider = slider

        let scaleLabel = NSTextField(labelWithString: String(format: "%.1fx", currentScale))
        scaleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        scaleLabel.textColor = .secondaryLabelColor
        scaleLabel.alignment = .right
        scaleLabel.frame = NSRect(x: sizeRow.bounds.width - 58, y: 8, width: 44, height: 18)
        scaleLabel.autoresizingMask = .minXMargin
        sizeRow.addSubview(scaleLabel)

// 条目 4：权限控制（校验码解锁全部功能）
let accessRow = makeStackRow(height: 72)
accessRowView = accessRow
let arw = accessRow.bounds.width

        let accessTitle = NSTextField(labelWithString: "权限")
        accessTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        accessTitle.textColor = .labelColor
        accessTitle.frame = NSRect(x: 14, y: 48, width: 200, height: 18)
        accessRow.addSubview(accessTitle)

        let statusLabel = NSTextField(labelWithString: AccessControl.isFullAccess ? "已解锁全部功能" : "基础权限")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = AccessControl.isFullAccess ? .controlAccentColor : .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.frame = NSRect(x: arw - 16 - 150, y: 48, width: 150, height: 18)
        accessRow.addSubview(statusLabel)
        accessStatusLabel = statusLabel

        let accessDesc = NSTextField(labelWithString: "输入校验码解锁全部功能（当前仅开放基础功能）")
        accessDesc.font = .systemFont(ofSize: 11)
        accessDesc.textColor = .tertiaryLabelColor
        accessDesc.frame = NSRect(x: 14, y: 32, width: arw - 28, height: 15)
        accessRow.addSubview(accessDesc)

        // 校验码输入框 + 解锁按钮（基础权限才显示）
        let codeField = NSSecureTextField(frame: NSRect(x: 14, y: 6, width: arw - 16 - 58 - 10 - 14, height: 26))
        codeField.placeholderString = "输入校验码"
        codeField.font = .systemFont(ofSize: 13)
        codeField.alignment = .center
        codeField.bezelStyle = .roundedBezel
        codeField.target = self
        codeField.action = #selector(unlockAccess(_:))
        accessRow.addSubview(codeField)
        accessCodeField = codeField

        let uBtn = NSButton(title: "解锁", target: self, action: #selector(unlockAccess(_:)))
        uBtn.frame = NSRect(x: arw - 16 - 58, y: 6, width: 58, height: 26)
        uBtn.bezelStyle = .rounded
        uBtn.autoresizingMask = .minXMargin
        accessRow.addSubview(uBtn)
        unlockBtn = uBtn

        // 已解锁时显示：清除权限（回到基础权限）
        let clearBtn = NSButton(title: "清除权限", target: self, action: #selector(clearAccess(_:)))
        clearBtn.frame = NSRect(x: arw - 16 - 92, y: 6, width: 92, height: 26)
        clearBtn.bezelStyle = .rounded
        clearBtn.autoresizingMask = .minXMargin
        clearBtn.isHidden = !AccessControl.isFullAccess
        accessRow.addSubview(clearBtn)
        clearAccessBtn = clearBtn

        if AccessControl.isFullAccess {
            codeField.isHidden = true
            uBtn.isHidden = true
        }

        // 条目 5：版本号（本地维护，随发布手动更新）
        let versionRow = makeStackRow(height: 48)
        let vrw = versionRow.bounds.width

        let versionTitle = NSTextField(labelWithString: "版本")
        versionTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        versionTitle.textColor = .labelColor
        versionTitle.frame = NSRect(x: 14, y: 24, width: 200, height: 18)
        versionRow.addSubview(versionTitle)

        let versionDesc = NSTextField(labelWithString: "当前应用版本号")
        versionDesc.font = .systemFont(ofSize: 11)
        versionDesc.textColor = .tertiaryLabelColor
        versionDesc.frame = NSRect(x: 14, y: 6, width: 220, height: 15)
        versionRow.addSubview(versionDesc)

        let versionLabel = NSTextField(labelWithString: AppVersion.current)
        versionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .right
        versionLabel.frame = NSRect(x: vrw - 16 - 150, y: 15, width: 150, height: 18)
        versionLabel.autoresizingMask = .minXMargin
        versionRow.addSubview(versionLabel)
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
        divider.autoresizingMask = .width
        container.addSubview(divider)
        
        // ── 垂直堆栈：各行间距自动管理，避免手算坐标导致重叠 ──
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 66 + 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        ])

        /// 堆栈内行容器：固定高度、自动铺满堆栈宽度
        func makeStackRow(height: CGFloat) -> NSView {
            let row = NSView(frame: NSRect(x: 0, y: 0, width: cw - 32, height: height))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor(white: 0, alpha: 0.04).cgColor
            row.layer?.cornerRadius = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: height)
            ])
            return row
        }

        let presets = [15, 30, 45, 60]
        let currentInterval = viewModel?.reminderInterval ?? PetViewModel.defaultReminderInterval

        // 条目 1：提醒间隔标题行（左标题 + 右当前值）
        let intervalRow = makeStackRow(height: 48)

        let presetLabel = NSTextField(labelWithString: "提醒间隔")
        presetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        presetLabel.textColor = .labelColor
        presetLabel.frame = NSRect(x: 14, y: 24, width: 120, height: 18)
        intervalRow.addSubview(presetLabel)

        let presetDesc = NSTextField(labelWithString: "选择或输入喝水提醒频率")
        presetDesc.font = .systemFont(ofSize: 11)
        presetDesc.textColor = .tertiaryLabelColor
        presetDesc.frame = NSRect(x: 14, y: 6, width: 200, height: 15)
        intervalRow.addSubview(presetDesc)

        // 当前生效的提醒间隔（预设高亮不直观，自定义间隔时更需显示）
        let irw = intervalRow.bounds.width
        let currentLabel = NSTextField(labelWithString: "当前：\(currentInterval) 分钟")
        currentLabel.font = .systemFont(ofSize: 12, weight: .medium)
        currentLabel.textColor = .controlAccentColor
        currentLabel.alignment = .right
        currentLabel.frame = NSRect(x: irw - 16 - 140, y: 15, width: 140, height: 18)
        currentLabel.autoresizingMask = .minXMargin
        intervalRow.addSubview(currentLabel)
        currentIntervalLabel = currentLabel

        // 条目 2：预设按钮行（按钮在 layout 时自动居中）
        let btnW: CGFloat = 56
        let btnH: CGFloat = 32
        let btnGap: CGFloat = 10
        let totalBtnsW = CGFloat(presets.count) * btnW + CGFloat(presets.count - 1) * btnGap

        let btnRow = CenteredButtonContainer(frame: NSRect(x: 0, y: 0, width: cw - 32, height: 44))
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(btnRow)
        NSLayoutConstraint.activate([
            btnRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            btnRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            btnRow.heightAnchor.constraint(equalToConstant: 44)
        ])

        var intervalBtns: [NSButton] = []
        for minutes in presets {
            let btn = NSButton(frame: NSRect(x: 0, y: 6, width: btnW, height: btnH))
            btn.title = "\(minutes)"
            btn.bezelStyle = .rounded
            btn.target = self
            btn.action = #selector(intervalButtonClicked(_:))
            btn.tag = minutes
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 8
            btnRow.addSubview(btn)
            intervalButtons.append((minutes, btn))
            intervalBtns.append(btn)
        }
        btnRow.configureButtons(intervalBtns, gap: btnGap, totalWidth: totalBtnsW, drawBackground: true)

        refreshIntervalButtons(currentInterval: currentInterval)

        // 条目 3：自定义时间输入行
        let customRow = makeStackRow(height: 48)

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
        field.autoresizingMask = .minXMargin
        customRow.addSubview(field)
        customIntervalField = field

        let applyBtn = NSButton(title: "应用", target: self, action: #selector(applyCustomInterval(_:)))
        applyBtn.frame = NSRect(x: right - applyBtnW, y: 10, width: applyBtnW, height: 28)
        applyBtn.bezelStyle = .rounded
        applyBtn.controlSize = .regular
        applyBtn.keyEquivalent = "\r"
        applyBtn.autoresizingMask = .minXMargin
        customRow.addSubview(applyBtn)
    }

    // MARK: - 提醒间隔操作

    @objc private func intervalButtonClicked(_ sender: NSButton) {
        let minutes = sender.tag
        // 点击预设立即生效，无需再点「应用」
        viewModel?.reminderInterval = minutes
        viewModel?.restartDrinkWaterReminder()
        refreshIntervalButtons(currentInterval: minutes)
        // 清空自定义输入并取消其焦点，避免残留高亮闪烁的输入光标
        if let field = customIntervalField {
            field.stringValue = ""
            if field.window?.firstResponder is NSTextView {
                _ = field.resignFirstResponder()
            }
            field.window?.makeFirstResponder(nil)
        }
    }

    @objc private func applyCustomInterval(_ sender: Any?) {
        guard let field = customIntervalField,
              let value = Int(field.stringValue), value >= 1, value <= 120 else { return }
        viewModel?.reminderInterval = value
        viewModel?.restartDrinkWaterReminder()
        refreshIntervalButtons(currentInterval: value)
        field.stringValue = ""
        field.resignFirstResponder()
        field.window?.makeFirstResponder(nil)
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

    // MARK: - 权限控制（校验码解锁）

    @objc private func unlockAccess(_ sender: Any?) {
        guard let field = accessCodeField else { return }
        let code = field.stringValue
        // 远程校验需等待网络，期间禁用解锁按钮防重复提交
        unlockBtn?.isEnabled = false
        AccessControl.unlock(with: code) { [weak self] result in
            guard let self else { return }
            self.unlockBtn?.isEnabled = true
            self.handleUnlockResult(result, field: field)
        }
    }

    private func handleUnlockResult(_ result: AccessControl.UnlockResult, field: NSSecureTextField) {
        if result == .success {
            field.stringValue = ""
            refreshAccessUI()
            onAccessLevelChanged?()
            let alert = NSAlert()
            alert.messageText = "解锁成功"
            alert.informativeText = "已解锁全部功能"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } else {
            let alert = NSAlert()
            switch result {
            case .deviceLimit:
                alert.messageText = "激活码已达设备上限"
                alert.informativeText = "该激活码绑定的设备数量已达上限，无法在新设备上使用"
            case .networkError:
                alert.messageText = "网络异常"
                alert.informativeText = "无法连接校验服务，请检查网络后重试"
            default:
                alert.messageText = "校验码错误"
                alert.informativeText = "请输入正确的校验码"
            }
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func clearAccess(_ sender: Any?) {
        AccessControl.clearAccess()
        refreshAccessUI()
        onAccessLevelChanged?()
        let alert = NSAlert()
        alert.messageText = "已清除权限"
        alert.informativeText = "已回到基础权限，高级功能已锁定"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func refreshAccessUI() {
        let unlocked = AccessControl.isFullAccess
        accessStatusLabel?.stringValue = unlocked ? "已解锁全部功能" : "基础权限"
        accessStatusLabel?.textColor = unlocked ? .controlAccentColor : .secondaryLabelColor
        accessCodeField?.isHidden = unlocked
        unlockBtn?.isHidden = unlocked
        clearAccessBtn?.isHidden = !unlocked
        // 小猫大小为基础功能，不随权限禁用
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
row.autoresizingMask = [.width, .minYMargin]
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
        // 切换分区时取消文本编辑焦点，避免输入框残留高亮闪烁光标
        if firstResponder is NSTextView {
            makeFirstResponder(nil)
        }
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

    /// 聚焦到宠物名称输入框（用于首次启动引导）
    func focusPetNameField() {
        // 确保在「宠物信息」分区
        currentSection = 0
        for (i, v) in contentViews.enumerated() {
            v.isHidden = (i != 0)
        }
        applyNavStyle()
        // 自动点编辑：让输入框可编辑并聚焦
        editPetName(petNameEditBtn ?? NSButton())
        makeFirstResponder(petNameField)
    }

    /// 「解锁更多功能」引导：打开设置面板、锚定到通用设置页，高亮闪烁「权限」栏
    func showGeneralAndFlashAccess() {
        showCentered()
        // 切换到通用设置（navTitles index 1）
        currentSection = 1
        for (i, v) in contentViews.enumerated() {
            v.isHidden = (i != currentSection)
        }
        applyNavStyle()
        // 高亮闪烁权限栏：3 次 × 0.45s 明暗交替
        guard let row = accessRowView else { return }
        let flash = NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor
        let normal = NSColor(white: 0, alpha: 0.04).cgColor
        for i in 0..<6 {
            let on = i % 2 == 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.45) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    row.layer?.backgroundColor = on ? flash : normal
                })
            }
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

// MARK: - 通用居中按钮容器（按钮在 layout 时自动居中）

final class CenteredButtonContainer: NSView {
    private var buttons: [NSButton] = []
    private var buttonGap: CGFloat = 8
    private var buttonsTotalWidth: CGFloat = 0
    private var drawBackground = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError() }

        /// drawBackground=true 时绘制圆角背景（作为行容器），false 时透明（仅做按钮居中）
    func configureButtons(_ btns: [NSButton], gap: CGFloat, totalWidth: CGFloat, drawBackground: Bool = false) {
        buttons = btns
        buttonGap = gap
        buttonsTotalWidth = totalWidth
        self.drawBackground = drawBackground
        wantsLayer = true
        if drawBackground {
            layer?.backgroundColor = NSColor(white: 0, alpha: 0.04).cgColor
            layer?.cornerRadius = 10
        }
        layoutButtons()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layoutButtons()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutButtons()
    }

    private func layoutButtons() {
        guard bounds.width > 0 else { return }
        let startX = (bounds.width - buttonsTotalWidth) / 2
        for (i, btn) in buttons.enumerated() {
            var f = btn.frame
            f.origin.x = startX + CGFloat(i) * (f.width + buttonGap)
            btn.frame = f
        }
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
