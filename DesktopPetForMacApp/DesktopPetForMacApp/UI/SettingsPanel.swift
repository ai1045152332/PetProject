// SettingsPanel.swift
// DesktopPetForMacApp — 菜单栏设置面板（左侧一级导航 + 右侧内容区）

import AppKit
import UniformTypeIdentifiers

/// 宠物名称管理（首次启动随机分配，用户可自行修改）
enum PetName {
    static let prefsKey = "settings.petName"
    static let defaultName = "毛豆"

    /// 首次启动随机取名池（避免所有设备都叫「毛豆」）
    private static let namePool = [
        "毛豆", "汤圆", "布丁", "年糕", "豆花", "芝麻", "团子", "糯米",
        "花生", "桃酥", "奶糖", "橘子", "曲奇", "面条", "鱼丸", "芋圆"
    ]

    /// 首次启动分配名字（已设置过名字的设备不受影响）
    @discardableResult
    static func ensureAssigned() -> String {
        let saved = UserDefaults.standard.string(forKey: prefsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty { return saved }

        let picked = namePool.randomElement() ?? defaultName
        UserDefaults.standard.set(picked, forKey: prefsKey)
        FileLogger.log("[DesktopPet] 首次启动分配宠物名称: \(picked)")
        return picked
    }

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
    /// 权限变化（含定时复核收回）时刷新权限区 UI
    private var accessObserver: NSObjectProtocol?

    private weak var viewModel: PetViewModel?
    private var spritePreviewButtons: [CatAnimationState: NSButton] = [:]
    private var customSpriteButtons: [CatAnimationState: NSButton] = [:]
    private var customSpriteResetButtons: [CatAnimationState: NSButton] = [:]
    private var aiStatusLabel: NSTextField?
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
    /// 自定义状态图片说明标签（随权限切换解锁提示）
    private weak var spriteDescLabel: NSTextField?
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
    /// 通用设置 > 版本的「检查更新」按钮
    private weak var checkUpdateBtn: NSButton?
    /// 提醒设置 > 天气提醒控件
    private weak var weatherToggle: ToggleSwitch?
    private weak var weatherTimePicker: NSDatePicker?
    private weak var weatherCityField: NSTextField?
    private weak var weatherPreviewBtn: NSButton?
    private weak var weatherDescLabel: NSTextField?
    /// 提醒设置 > 主动搭话控件
    private weak var chatToggle: ToggleSwitch?
    private weak var chatDescLabel: NSTextField?
    private var chatIntervalButtons: [(Int, NSButton)] = []

    // 好友消息（设置面板「好友消息」区）
    /// 宠物号变化通知观察者（心跳/注册接口刷新后同步展示）
    private var petNoObserver: NSObjectProtocol?
    private weak var myPetNoLabel: NSTextField?
    private weak var addFriendField: NSTextField?
    private weak var friendsDocView: NSView?
    private weak var socialStatusLabel: NSTextField?
    private weak var refreshSocialBtn: NSButton?
    private var socialFriends: [PetFriend] = []
    private var friendsListWidth: CGFloat = 0
    private var friendsViewportHeight: CGFloat = 0
    private var socialLoading = false

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

        // 权限可能被定时复核收回（如激活码过期），同步刷新权限区
        accessObserver = NotificationCenter.default.addObserver(
            forName: AccessControl.accessLevelChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessUI()
                self?.refreshWeatherControls()
                self?.refreshSpriteAccessUI()
            }
        }

        // 宠物号由心跳/注册接口刷新后，同步更新「好友消息」区展示
        petNoObserver = NotificationCenter.default.addObserver(
            forName: FriendService.petNoChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMyPetNoUI()
            }
        }
    }

    deinit {
        if let accessObserver {
            NotificationCenter.default.removeObserver(accessObserver)
        }
        if let petNoObserver {
            NotificationCenter.default.removeObserver(petNoObserver)
        }
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
        let navTitles = ["🐱 宠物信息", "⚙️ 通用设置", "🔔 提醒设置", "🖱️ 菜单设置", "👫 好友消息"]
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

        // 仅「宠物信息」区内容较高，包一层滚动容器；其余各区保持原有直接布局
        let section0 = makeContentContainer(frame: contentFrame, scrollable: true, contentHeight: 372, in: contentView)
        let section1 = makeContentContainer(frame: contentFrame, in: contentView)
        let section2 = makeContentContainer(frame: contentFrame, in: contentView)
        let section3 = makeContentContainer(frame: contentFrame, in: contentView)
        let section4 = makeContentContainer(frame: contentFrame, in: contentView)
        section1.isHidden = true
        section2.isHidden = true
        section3.isHidden = true
        section4.isHidden = true
        contentViews = [section0, section1, section2, section3, section4]

        fillStateSection(section0)
        fillGeneralSection(section1)
        fillReminderSection(section2)
        fillMenuSettingsSection(section3)
        fillSocialSection(section4)

        applyNavStyle()
    }

    // MARK: - 内容容器

    /// scrollable=false：普通内容区（随窗口拉伸）；true：包一层竖向滚动，文档高度按内容预留
    private func makeContentContainer(frame: NSRect, scrollable: Bool = false, contentHeight: CGFloat = 0, in parent: NSView) -> NSView {
        let docHeight = max(contentHeight, frame.height)
        // 滚动分支：文档视图原点在滚动容器内，从 (0,0) 起；非滚动分支：直接用内容区 frame（含 x 偏移），否则会盖住左侧导航
        let v = NSView(frame: scrollable
            ? NSRect(x: 0, y: 0, width: frame.width, height: docHeight)
            : frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        v.layer?.cornerRadius = 12
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        if scrollable {
            let scroll = NSScrollView(frame: frame)
            scroll.autoresizingMask = [.width, .height, .minYMargin, .minXMargin]
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = false
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.automaticallyAdjustsContentInsets = false
            // 非翻转坐标：内容顶部贴文档 maxY，滚动向下露出超出部分；宽度随窗口自适应
            v.autoresizingMask = [.width]
            scroll.documentView = v
            parent.addSubview(scroll)
        } else {
            v.autoresizingMask = [.width, .height, .minYMargin, .minXMargin]
            parent.addSubview(v)
        }
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

        // ── 合并区：形象切换 + 状态图片管理（每状态一竖格） ──
        // 顶部：标题 + 历史图片工具按钮；其下一行说明；中部：5 个状态格；底部：AI 生成 + 剩余次数
        // 紧跟「宠物名称」行下方成组排布（而非贴底），避免删卡后中间裂出空洞
        let spriteRowH: CGFloat = 196
        let spriteRowY = nameRowY - 16 - spriteRowH
        let spriteRow = makeSettingRow(
            frame: NSRect(x: 16, y: spriteRowY, width: cw - 32, height: spriteRowH),
            in: container
        )
        let rw = spriteRow.bounds.width

        let spriteTitle = NSTextField(labelWithString: "自定义状态图片")
        spriteTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        spriteTitle.textColor = .labelColor
        spriteTitle.frame = NSRect(x: 14, y: 168, width: 180, height: 18)
        spriteRow.addSubview(spriteTitle)

        let history = NSButton(title: "🗂 查看历史图片", target: self, action: #selector(showPetImageHistory(_:)))
        history.frame = NSRect(x: rw - 128, y: 164, width: 114, height: 26)
        history.font = .systemFont(ofSize: 11)
        history.bezelStyle = .rounded
        history.autoresizingMask = .minXMargin
        spriteRow.addSubview(history)
        petHistoryButton = history

        let spriteDesc = NSTextField(labelWithString: "直接上传：本机即时生效；AI 生成：上传一次，逐状态各生成一张 · 最大 10 MB")
        spriteDesc.font = .systemFont(ofSize: 11)
        spriteDesc.textColor = .tertiaryLabelColor
        spriteDesc.lineBreakMode = .byTruncatingTail
        spriteDesc.frame = NSRect(x: 14, y: 146, width: rw - 28, height: 14)
        spriteDesc.autoresizingMask = .width
        spriteRow.addSubview(spriteDesc)
        spriteDescLabel = spriteDesc

        // 每个状态一格：预览图（点击=切到该状态，当前态高亮）+ 直接上传 + 恢复默认
        let customStates = CatAnimationState.allCases
        let cellW: CGFloat = 76
        let cellGap: CGFloat = 8
        let gridW = CGFloat(customStates.count) * cellW + CGFloat(customStates.count - 1) * cellGap
        var cellX = max(14, (rw - gridW) / 2)
        for (index, state) in customStates.enumerated() {
            let preview = NSButton(frame: NSRect(x: cellX, y: 76, width: cellW, height: 64))
            preview.title = state.displayName
            preview.font = .systemFont(ofSize: 10, weight: .medium)
            preview.alignment = .center
            preview.imagePosition = .imageAbove
            preview.imageScaling = .scaleProportionallyDown
            preview.image = customSpriteImage(for: state)
            preview.setButtonType(.toggle)
            preview.isBordered = false
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 10
            preview.layer?.masksToBounds = true
            preview.tag = index
            preview.target = self
            preview.action = #selector(stateTileClicked(_:))
            preview.toolTip = "点击切换宠物到\(state.displayName)状态"
            spriteRow.addSubview(preview)
            spritePreviewButtons[state] = preview

            let upload = NSButton(title: "直接上传", target: self, action: #selector(directUploadCustomSprite(_:)))
            upload.frame = NSRect(x: cellX, y: 52, width: cellW, height: 22)
            upload.font = .systemFont(ofSize: 10, weight: .medium)
            upload.bezelStyle = .rounded
            upload.controlSize = .small
            upload.tag = index
            upload.toolTip = "原图（含 GIF 动图）直接作为\(state.displayName)状态图片，仅保存在本机"
            spriteRow.addSubview(upload)
            customSpriteButtons[state] = upload

            let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetCustomSprite(_:)))
            reset.frame = NSRect(x: cellX, y: 28, width: cellW, height: 20)
            reset.font = .systemFont(ofSize: 9)
            reset.bezelStyle = .rounded
            reset.controlSize = .small
            reset.tag = index
            reset.toolTip = "清除\(state.displayName)状态的图片，恢复内置默认图"
            spriteRow.addSubview(reset)
            customSpriteResetButtons[state] = reset
            cellX += cellW + cellGap
        }

        // 底部工具条：AI 生成全部状态（左）+ 剩余次数/进度（右）
        let aiButton = NSButton(title: "🪄 AI 生成所有状态图片", target: self, action: #selector(generateAllStatesWithAI(_:)))
        aiButton.frame = NSRect(x: 14, y: 2, width: 210, height: 22)
        aiButton.font = .systemFont(ofSize: 11, weight: .medium)
        aiButton.bezelStyle = .rounded
        aiButton.toolTip = "上传一张照片，AI 为全部 5 个状态各生成一张图片（姿态按状态区分）并自动应用；整批仅消耗该激活码的 1 次生成配额"
        spriteRow.addSubview(aiButton)
        aiGenerateAllButton = aiButton

        let aiStatus = NSTextField(labelWithString: "")
        aiStatus.font = .systemFont(ofSize: 10)
        aiStatus.textColor = .secondaryLabelColor
        aiStatus.lineBreakMode = .byTruncatingTail
        aiStatus.frame = NSRect(x: 232, y: 6, width: rw - 246, height: 15)
        aiStatus.autoresizingMask = .width
        spriteRow.addSubview(aiStatus)
        aiStatusLabel = aiStatus

        refreshStateCards()
        refreshSpriteAccessUI()
        refreshQuotaFromServer()
    }

    /// AI 生成需要有效服务端激活码；直接上传、历史图片、本地切图均不需要。
    private func refreshSpriteAccessUI() {
        let hasCode = AccessControl.serverActivationCode != nil
        let quotaExhausted = hasCode && petQuotaRemaining == 0
        petHistoryButton?.isEnabled = !petImageBusy
        aiGenerateAllButton?.isEnabled = hasCode && !petImageBusy && !quotaExhausted
        for state in CatAnimationState.allCases {
            customSpriteButtons[state]?.isEnabled = !petImageBusy
            let hasLocal = CustomSpriteStore.hasLocalImage(for: state)
            customSpriteButtons[state]?.title = hasLocal ? "● 直接上传" : "直接上传"
            customSpriteResetButtons[state]?.isEnabled =
                !petImageBusy && (hasLocal || CustomSpriteStore.hasCustomImage(for: state))
        }
        if hasCode {
            spriteDescLabel?.stringValue = "直接上传：本机即时生效；AI 生成：上传一次，逐状态各生成一张 · 最大 10 MB"
            spriteDescLabel?.textColor = .tertiaryLabelColor
            if !petImageBusy, let remaining = petQuotaRemaining, let limit = petQuotaLimit, limit > 0 {
                aiStatusLabel?.stringValue = remaining > 0
                    ? "剩余 AI 生成次数：\(remaining)/\(limit)"
                    : "AI 生成次数已用完（\(limit)/\(limit)）"
            }
        } else {
            spriteDescLabel?.stringValue = "直接上传与本机历史随时可用；AI 生成需服务端激活码"
            spriteDescLabel?.textColor = .systemOrange
        }
    }

    /// 使用当前激活码刷新剩余生成次数；仅在有码且空闲时发起，避免与图片同步互扰。
    private func refreshQuotaFromServer() {
        guard AccessControl.serverActivationCode != nil, !petImageBusy else { return }
        Task { @MainActor [weak self] in
            guard let self, let library = try? await PetImageService.library() else { return }
            self.applyQuota(library)
        }
    }
    private func applyQuota(_ library: PetImageLibrary) {
        petQuotaLimit = library.generationLimit
        petQuotaRemaining = library.generationRemaining
        refreshSpriteAccessUI()
    }

    private func showSpriteUnlockHint() {
        let alert = NSAlert()
        alert.messageText = "该功能需要解锁"
        alert.informativeText = "请在「通用设置 → 权限」输入有效的服务端激活码；AI 生成与重试生成需要它，直接上传、本机历史与本地切图不受影响。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func customSpriteImage(for state: CatAnimationState) -> NSImage? {
        return viewModel?.spriteSheets[state]?.frame(at: 0)
    }

    private weak var petHistoryButton: NSButton?
    private weak var aiGenerateAllButton: NSButton?
    /// 图片历史面板（sheet）：关闭时由 onDismiss 置空
    private var petHistoryWindow: PetImageHistoryWindow?
    private var petImageBusy = false
    private var petQuotaLimit: Int?
    private var petQuotaRemaining: Int?

    private func customSpriteState(for sender: NSButton) -> CatAnimationState? {
        let states = CatAnimationState.allCases
        guard states.indices.contains(sender.tag) else { return nil }
        return states[sender.tag]
    }

    /// 直接上传：原图（含 GIF 动图）仅存本机，不需要激活码、不占生成配额、即时生效。
    @objc private func directUploadCustomSprite(_ sender: NSButton) {
        guard !petImageBusy, let state = customSpriteState(for: sender) else { return }
        let panel = NSOpenPanel()
        panel.title = "选择\(state.displayName)状态图片"
        panel.message = "PNG/JPEG/GIF，最大 10 MB；原图直接作为\(state.displayName)状态图片，仅保存在本机"
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count > 0, data.count <= 10 * 1024 * 1024 else {
                    throw PetImageService.failure("图片不得超过 10 MB")
                }
                try CustomSpriteStore.installLocalImage(data, for: state)
                self.viewModel?.reloadSpriteSheets()
                self.refreshCustomSpriteControls()
                self.aiStatusLabel?.stringValue = "已更新\(state.displayName)状态图片（仅本机）"
            } catch {
                self.showSpriteError(error)
            }
        }
    }

    /// AI 生成：一张照片上传一次，服务端逐状态各生成一张（共 5 张），整批只扣 1 次配额、占 1 个任务槽。
    @objc private func generateAllStatesWithAI(_ sender: Any?) {
        guard AccessControl.serverActivationCode != nil else { showSpriteUnlockHint(); return }
        if petQuotaRemaining == 0 {
            aiStatusLabel?.stringValue = "AI 生成次数已用完，请更换激活码或联系管理员"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择宠物照片"
        panel.message = "PNG/JPEG，最大 10 MB；照片将通过 OpenRouter 调用 Seedream 模型，为全部 5 个状态各生成一张图片（姿态按状态区分），整批仅消耗 1 次生成配额"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self else { return }
            self.viewModel?.cancelCloudRestore()
            self.petImageBusy = true
            self.refreshSpriteAccessUI()
            self.spriteDescLabel?.stringValue = "正在上传照片…"
            Task { @MainActor [weak self] in
                // 本批任务：服务端生成记录 ID → 状态，供落盘与失败重试使用
                var batch: [String: String] = [:]
                do {
                    let library = try await PetImageService.uploadAllStates(url)
                    // admit 保证同设备此刻无并发生成，因此刚返回的生成中记录即为本批全部状态。
                    for record in library.images where record.isGenerating {
                        guard let raw = record.state, CatAnimationState(rawValue: raw) != nil else { continue }
                        batch[record.id] = raw
                    }
                    guard !batch.isEmpty else { throw PetImageService.failure("未返回生成记录") }
                    let ids = Array(batch.keys)
                    let finished = try await PetImageService.waitForGeneration(ids, initial: library) { stage in
                        self?.aiStatusLabel?.stringValue = stage
                    }
                    self?.applyQuota(finished)
                    // 结果直接落本机并本地生效：历史与选中都不再依赖服务端记录。
                    // 本机没拿到图即视为生成失败，记下任务 ID 以便在历史图片里重试。
                    var applied = 0
                    var failed = 0
                    for (id, raw) in batch {
                        guard let state = CatAnimationState(rawValue: raw) else { continue }
                        let record = finished.images.first { $0.id == id }
                        guard record?.isReady == true, let data = try? await PetImageService.image(id) else {
                            failed += 1
                            CustomSpriteStore.recordFailure(for: state, serverID: id,
                                                            message: record?.error ?? "未取到图片")
                            continue
                        }
                        do {
                            try CustomSpriteStore.installCloudImage(id: id, data: data, for: state)
                            applied += 1
                        } catch {
                            failed += 1
                            CustomSpriteStore.recordFailure(for: state, serverID: id, message: error.localizedDescription)
                        }
                    }
                    self?.viewModel?.reloadSpriteSheets()
                    self?.aiStatusLabel?.stringValue = failed == 0
                        ? "已为全部 \(applied) 个状态各生成一张并应用"
                        : "已应用 \(applied) 个状态，\(failed) 个失败（可在历史图片重试）"
                } catch {
                    // 上传或等待失败：本批已知状态全部记为失败，保留任务 ID 便于重试
                    for (id, raw) in batch {
                        if let state = CatAnimationState(rawValue: raw) {
                            CustomSpriteStore.recordFailure(for: state, serverID: id, message: error.localizedDescription)
                        }
                    }
                    self?.showSpriteError(error)
                }
                self?.petImageBusy = false
                self?.refreshCustomSpriteControls()
            }
        }
    }

    @objc private func resetCustomSprite(_ sender: NSButton) {
        guard let state = customSpriteState(for: sender) else { return }
        // 完全本地：清掉直传图与选中标识，回到内置默认图，不改动服务端。
        do {
            try CustomSpriteStore.restoreDefault(for: state)
            viewModel?.reloadSpriteSheets()
            refreshCustomSpriteControls()
            aiStatusLabel?.stringValue = "已恢复\(state.displayName)状态的默认图片"
        } catch {
            showSpriteError(error)
        }
    }

    /// 历史图片完全读本机文件：服务端只负责生成与存储，打开本弹窗不需要网络。
    @objc private func showPetImageHistory(_ sender: NSButton) {
        if let existing = petHistoryWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = PetImageHistoryWindow(items: CustomSpriteStore.localImages(),
                                           failures: CustomSpriteStore.failures(),
                                           initialState: viewModel?.animationState ?? .idel)
        window.onApply = { [weak self] item, state in
            self?.applyLocalImage(item, to: state)
        }
        // 删除/重试等本机文件变化后，重新枚举本机清单推回面板，窗口不关可连续操作
        window.onDelete = { [weak self] item in
            self?.deleteLocalImage(item, failureState: nil)
            self?.reloadPetImageHistory()
        }
        window.onClearFailure = { [weak self] state in
            self?.deleteLocalImage(nil, failureState: state)
            self?.reloadPetImageHistory()
        }
        window.onRetry = { [weak self] state, failure in
            self?.retryFailedGeneration(for: state, failure: failure)
        }
        window.onDismiss = { [weak self] in
            self?.petHistoryWindow = nil
        }
        petHistoryWindow = window
        beginSheet(window)
        backfillHistoryOwnership()
    }

    private func reloadPetImageHistory() {
        petHistoryWindow?.reload(items: CustomSpriteStore.localImages(),
                                 failures: CustomSpriteStore.failures())
    }

    /// 老版本的 AI 图本机没记生成状态：有激活码时用服务端记录补一次归属，
    /// 不阻塞面板打开，失败就保持离线（未归属的图仍可见可用）。
    private func backfillHistoryOwnership() {
        guard AccessControl.serverActivationCode != nil else { return }
        Task { @MainActor [weak self] in
            guard let library = try? await PetImageService.library() else { return }
            var records: [String: String] = [:]
            for record in library.images {
                guard let state = record.state, CatAnimationState(rawValue: state) != nil else { continue }
                records[record.id] = state
            }
            guard CustomSpriteStore.mergeCloudStates(records) else { return }
            self?.reloadPetImageHistory()
        }
    }

    /// 本地切图：只改本机 selections 清单，不请求服务端；文件缺失时该状态回退内置默认图。
    private func applyLocalImage(_ item: CustomSpriteStore.LocalImageItem?, to state: CatAnimationState) {
        guard let item else {
            aiStatusLabel?.stringValue = "请先选择一张本机图片"
            return
        }
        do {
            try CustomSpriteStore.selectLocalImage(key: item.key, for: state)
            viewModel?.reloadSpriteSheets()
            refreshCustomSpriteControls()
            aiStatusLabel?.stringValue = "已将本机图片应用到\(state.displayName)状态"
        } catch {
            refreshCustomSpriteControls()
            showSpriteError(error)
        }
    }

    /// 删除本机图片（选中则回退默认图）；选中的是失败记录时改为清除该记录。
    private func deleteLocalImage(_ item: CustomSpriteStore.LocalImageItem?, failureState: CatAnimationState?) {
        if let item {
            do {
                try CustomSpriteStore.removeLocalImage(key: item.key)
                viewModel?.reloadSpriteSheets()
                refreshCustomSpriteControls()
                aiStatusLabel?.stringValue = "已删除本机图片，被影响的状态已恢复默认图"
            } catch {
                showSpriteError(error)
            }
        } else if let failureState {
            CustomSpriteStore.clearFailure(for: failureState)
            refreshCustomSpriteControls()
            aiStatusLabel?.stringValue = "已清除\(failureState.displayName)状态的失败记录"
        }
    }

    /// 本机没拿到图片即视为生成失败：用记录的服务端任务 ID 重试，成功后落盘并选中。
    private func retryFailedGeneration(for state: CatAnimationState, failure: CustomSpriteStore.SpriteFailure?) {
        guard let failure else {
            aiStatusLabel?.stringValue = "\(state.displayName)状态没有失败记录"
            return
        }
        guard AccessControl.serverActivationCode != nil else { showSpriteUnlockHint(); return }
        guard let serverID = failure.serverID else {
            aiStatusLabel?.stringValue = "该失败任务缺少服务端 ID，请重新 AI 生成"
            return
        }
        guard !petImageBusy else { return }
        viewModel?.cancelCloudRestore()
        petImageBusy = true
        refreshSpriteAccessUI()
        spriteDescLabel?.stringValue = "正在重试生成，请稍候…"
        Task { @MainActor [weak self] in
            do {
                let retried = try await PetImageService.retry(serverID, for: state)
                let finished = try await PetImageService.waitForGeneration(serverID, initial: retried) { stage in
                    self?.aiStatusLabel?.stringValue = stage
                }
                guard let record = finished.images.first(where: { $0.id == serverID }) else {
                    throw PetImageService.failure("未返回生成记录")
                }
                guard record.isReady else {
                    throw PetImageService.failure(record.error ?? "生成失败，请稍后重试")
                }
                let data = try await PetImageService.image(serverID)
                try CustomSpriteStore.installCloudImage(id: serverID, data: data, for: state)
                self?.viewModel?.reloadSpriteSheets()
                self?.aiStatusLabel?.stringValue = "已重新生成并应用到\(state.displayName)状态"
            } catch {
                CustomSpriteStore.recordFailure(for: state, serverID: serverID, message: error.localizedDescription)
                self?.showSpriteError(error)
            }
            self?.petImageBusy = false
            self?.refreshCustomSpriteControls()
        }
    }

    /// 图片内容发生变化后统一刷新面板：按钮圆点/可用性 + 状态格预览图。
    /// 预览图只在 refreshStateCards 里重新取帧，单靠 refreshSpriteAccessUI 不会换图，
    /// 否则更换图片后要等面板重开或宠物切换状态才看得见新图。
    private func refreshCustomSpriteControls() {
        refreshSpriteAccessUI()
        refreshStateCards()
    }

    private func showSpriteError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "图片同步失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: self)
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

        let itemDesc = NSTextField(labelWithString: "登录 macOS 后自动启动宠物")
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

        // 条目 3：宠物大小（基础权限即可调整）
        let sizeRow = makeStackRow(height: 56)

        let sizeTitle = NSTextField(labelWithString: "宠物大小")
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

        let accessDesc = NSTextField(labelWithString: "输入校验码解锁全部功能；如需获取校验码，请添加微信：Ideal2020life")
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

        let versionLabel = NSTextField(labelWithString: AppVersion.displayVersion)
        versionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .right
        versionLabel.frame = NSRect(x: vrw - 16 - 150, y: 15, width: 150, height: 18)
        versionLabel.autoresizingMask = .minXMargin
        versionRow.addSubview(versionLabel)

        // 「检查更新」按钮：手动触发更新检查（无更新/失败都会有提示）
        let checkBtn = NSButton(title: "检查更新", target: self, action: #selector(checkUpdateNow(_:)))
        checkBtn.frame = NSRect(x: vrw - 16 - 150 - 8 - 84, y: 11, width: 84, height: 26)
        checkBtn.bezelStyle = .rounded
        checkBtn.font = .systemFont(ofSize: 12)
        checkBtn.autoresizingMask = .minXMargin
        versionRow.addSubview(checkBtn)
        checkUpdateBtn = checkBtn
    }

    /// 手动检查更新（结果通过弹窗反馈）
    @objc private func checkUpdateNow(_ sender: Any?) {
        checkUpdateBtn?.isEnabled = false
        checkUpdateBtn?.title = "检查中…"
        UpdateService.shared.checkForUpdate(userInitiated: true) { [weak self] in
            self?.checkUpdateBtn?.isEnabled = true
            self?.checkUpdateBtn?.title = "检查更新"
        }
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

        let descLbl = NSTextField(labelWithString: "喝水、天气提醒与主动搭话")
        descLbl.font = .systemFont(ofSize: 11)
        descLbl.textColor = .tertiaryLabelColor
        descLbl.frame = NSRect(x: 16, y: ch - 58, width: cw - 32, height: 15)
        container.addSubview(descLbl)

        let divider = NSBox(frame: NSRect(x: 16, y: ch - 66, width: cw - 32, height: 1))
        divider.boxType = .separator
        divider.autoresizingMask = .width
        container.addSubview(divider)

        // ── 垂直堆栈：各行间距自动管理 ──
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

        // ═══ 卡片 1：喝水提醒（预设 + 自定义合并为一行）═══
        let waterCard = makeStackRow(height: 104)
        let wcw = waterCard.bounds.width

        let waterTitle = NSTextField(labelWithString: "喝水提醒")
        waterTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        waterTitle.textColor = .labelColor
        waterTitle.frame = NSRect(x: 14, y: 74, width: 200, height: 18)
        waterCard.addSubview(waterTitle)

        let waterDesc = NSTextField(labelWithString: "每隔一段时间提醒你起身喝水")
        waterDesc.font = .systemFont(ofSize: 11)
        waterDesc.textColor = .tertiaryLabelColor
        waterDesc.frame = NSRect(x: 14, y: 56, width: 260, height: 15)
        waterCard.addSubview(waterDesc)

        let currentInterval = viewModel?.reminderInterval ?? PetViewModel.defaultReminderInterval
        let currentLabel = NSTextField(labelWithString: "当前：\(currentInterval) 分钟")
        currentLabel.font = .systemFont(ofSize: 12, weight: .medium)
        currentLabel.textColor = .controlAccentColor
        currentLabel.alignment = .right
        currentLabel.frame = NSRect(x: wcw - 16 - 140, y: 70, width: 140, height: 18)
        currentLabel.autoresizingMask = .minXMargin
        waterCard.addSubview(currentLabel)
        currentIntervalLabel = currentLabel

        // 控制行：预设按钮 + 自定义输入 + 应用
        let presets = [15, 30, 45, 60]
        let presetW: CGFloat = 52
        let ctrlH: CGFloat = 28
        var px: CGFloat = 14
        for minutes in presets {
            let btn = NSButton(frame: NSRect(x: px, y: 12, width: presetW, height: ctrlH))
            btn.title = "\(minutes)"
            btn.bezelStyle = .rounded
            btn.target = self
            btn.action = #selector(intervalButtonClicked(_:))
            btn.tag = minutes
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 8
            waterCard.addSubview(btn)
            intervalButtons.append((minutes, btn))
            px += presetW + 8
        }

        let unitHint = NSTextField(labelWithString: "分钟")
        unitHint.font = .systemFont(ofSize: 11)
        unitHint.textColor = .tertiaryLabelColor
        unitHint.frame = NSRect(x: px + 2, y: 18, width: 40, height: 15)
        waterCard.addSubview(unitHint)

        let applyW: CGFloat = 52
        let applyBtn = NSButton(title: "应用", target: self, action: #selector(applyCustomInterval(_:)))
        applyBtn.frame = NSRect(x: wcw - 16 - applyW, y: 12, width: applyW, height: ctrlH)
        applyBtn.bezelStyle = .rounded
        applyBtn.autoresizingMask = .minXMargin
        waterCard.addSubview(applyBtn)

        let fieldW: CGFloat = 66
        let field = NSTextField(frame: NSRect(x: wcw - 16 - applyW - 8 - fieldW, y: 12, width: fieldW, height: ctrlH))
        field.font = .systemFont(ofSize: 13)
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.placeholderString = "自定义"
        field.delegate = self
        field.autoresizingMask = .minXMargin
        waterCard.addSubview(field)
        customIntervalField = field

        refreshIntervalButtons(currentInterval: currentInterval)

        // ═══ 卡片 2：天气提醒（仅解锁可用；天气接口按量付费）═══
        let weatherCard = makeStackRow(height: 104)
        let ecw = weatherCard.bounds.width

        let weatherTitle = NSTextField(labelWithString: "天气提醒")
        weatherTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        weatherTitle.textColor = .labelColor
        weatherTitle.frame = NSRect(x: 14, y: 74, width: 200, height: 18)
        weatherCard.addSubview(weatherTitle)

        let weatherDesc = NSTextField(labelWithString: "")
        weatherDesc.font = .systemFont(ofSize: 11)
        weatherDesc.textColor = .tertiaryLabelColor
        weatherDesc.frame = NSRect(x: 14, y: 56, width: ecw - 200, height: 15)
        weatherCard.addSubview(weatherDesc)
        weatherDescLabel = weatherDesc

        let toggle = ToggleSwitch(frame: NSRect(x: ecw - 16 - 52, y: 70, width: 52, height: 26))
        toggle.autoresizingMask = .minXMargin
        toggle.isOn = WeatherReminderService.shared.isEnabled
        toggle.onToggle = { [weak self] on in
            guard AccessControl.isFullAccess else {
                // 基础权限：不开启（天气接口付费），并提示解锁
                WeatherReminderService.shared.isEnabled = false
                self?.refreshWeatherControls()
                self?.showWeatherUnlockHint()
                return
            }
            WeatherReminderService.shared.isEnabled = on
            self?.refreshWeatherControls()
        }
        weatherCard.addSubview(toggle)
        weatherToggle = toggle

        // 时间选择器（只选时/分，强制 24 小时制，避免用户对格式产生歧义）
        let timePicker = NSDatePicker(frame: NSRect(x: 14, y: 11, width: 96, height: 30))
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.datePickerMode = .single
        timePicker.locale = Locale(identifier: "zh_CN")   // 强制 24 小时制显示
        timePicker.font = .systemFont(ofSize: 13)
        timePicker.target = self
        timePicker.action = #selector(weatherTimeChanged(_:))
        timePicker.dateValue = Self.dateForTime(hour: WeatherReminderService.shared.hour,
                                               minute: WeatherReminderService.shared.minute)
        weatherCard.addSubview(timePicker)
        weatherTimePicker = timePicker

        let timeHint = NSTextField(labelWithString: "每天提醒时间（24 小时制）")
        timeHint.font = .systemFont(ofSize: 11)
        timeHint.textColor = .tertiaryLabelColor
        timeHint.frame = NSRect(x: 118, y: 18, width: 170, height: 15)
        weatherCard.addSubview(timeHint)

        let cityField = NSTextField(frame: NSRect(x: 292, y: 12, width: ecw - 292 - 16 - 52 - 12, height: ctrlH))
        cityField.font = .systemFont(ofSize: 13)
        cityField.placeholderString = "城市（留空按定位）"
        cityField.stringValue = WeatherReminderService.shared.city
        cityField.delegate = self
        cityField.autoresizingMask = [.width]
        weatherCard.addSubview(cityField)
        weatherCityField = cityField

        let previewBtn = NSButton(title: "预览", target: self, action: #selector(previewWeatherReminder(_:)))
        previewBtn.frame = NSRect(x: ecw - 16 - 52, y: 12, width: 52, height: ctrlH)
        previewBtn.bezelStyle = .rounded
        previewBtn.autoresizingMask = .minXMargin
        weatherCard.addSubview(previewBtn)
        weatherPreviewBtn = previewBtn

        refreshWeatherControls()

        // ═══ 卡片 3：主动搭话（结合新闻 / Todo 的陪伴式气泡）═══
        let chatCard = makeStackRow(height: 104)
        let ccw = chatCard.bounds.width

        let chatTitle = NSTextField(labelWithString: "主动搭话")
        chatTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        chatTitle.textColor = .labelColor
        chatTitle.frame = NSRect(x: 14, y: 74, width: 200, height: 18)
        chatCard.addSubview(chatTitle)

        let chatDesc = NSTextField(labelWithString: "")
        chatDesc.font = .systemFont(ofSize: 11)
        chatDesc.textColor = .tertiaryLabelColor
        chatDesc.frame = NSRect(x: 14, y: 56, width: ccw - 90, height: 15)
        chatCard.addSubview(chatDesc)
        chatDescLabel = chatDesc

        let chatToggle = ToggleSwitch(frame: NSRect(x: ccw - 16 - 52, y: 70, width: 52, height: 26))
        chatToggle.autoresizingMask = .minXMargin
        chatToggle.isOn = viewModel?.proactiveChatEnabled ?? true
        chatToggle.onToggle = { [weak self] on in
            self?.viewModel?.proactiveChatEnabled = on
            self?.refreshChatControls()
        }
        chatCard.addSubview(chatToggle)
        self.chatToggle = chatToggle

        // 间隔预设（分钟 / 次）：点击立即生效
        let chatPresets = [15, 30, 60]
        let chatPresetW: CGFloat = 52
        var cx: CGFloat = 14
        for minutes in chatPresets {
            let btn = NSButton(frame: NSRect(x: cx, y: 12, width: chatPresetW, height: 28))
            btn.title = "\(minutes)"
            btn.bezelStyle = .rounded
            btn.target = self
            btn.action = #selector(chatIntervalButtonClicked(_:))
            btn.tag = minutes
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 8
            chatCard.addSubview(btn)
            chatIntervalButtons.append((minutes, btn))
            cx += chatPresetW + 8
        }

        let chatUnit = NSTextField(labelWithString: "分钟 / 次")
        chatUnit.font = .systemFont(ofSize: 11)
        chatUnit.textColor = .tertiaryLabelColor
        chatUnit.frame = NSRect(x: cx + 2, y: 18, width: 80, height: 15)
        chatCard.addSubview(chatUnit)

        refreshChatControls()
    }

    /// 天气提醒控件可用状态：基础权限全部置灰（天气接口按量付费）
    private func refreshWeatherControls() {
        let unlocked = AccessControl.isFullAccess
        weatherToggle?.isEnabled = unlocked
        weatherTimePicker?.isEnabled = unlocked
        weatherCityField?.isEnabled = unlocked
        weatherPreviewBtn?.isEnabled = unlocked

        if unlocked {
            let on = WeatherReminderService.shared.isEnabled
            weatherDescLabel?.stringValue = on
                ? "每天 \(WeatherReminderService.shared.timeText)（24 小时制）提醒今天的天气"
                : "打开开关后，每天在你选择的时间提醒今天的天气"
            weatherDescLabel?.textColor = .tertiaryLabelColor
        } else {
            weatherDescLabel?.stringValue = "需解锁全部功能后可用（天气接口按量付费）"
            weatherDescLabel?.textColor = .systemOrange
        }
    }

    private func showWeatherUnlockHint() {
        let alert = NSAlert()
        alert.messageText = "该功能需要解锁"
        alert.informativeText = "天气提醒使用付费天气接口，请在「通用设置 → 权限」输入校验码解锁后使用。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func previewWeatherReminder(_ sender: Any?) {
        guard AccessControl.isFullAccess else { return }
        WeatherReminderService.shared.deliver()
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

    // MARK: - 主动搭话操作

    @objc private func chatIntervalButtonClicked(_ sender: NSButton) {
        let minutes = sender.tag
        viewModel?.chatIntervalMinutes = minutes
        viewModel?.restartProactiveChat()
        refreshChatControls()
    }

    /// 同步主动搭话卡片：描述文案随开关变化，间隔按钮高亮当前值（关闭时间隔按钮置灰）
    private func refreshChatControls() {
        let on = viewModel?.proactiveChatEnabled ?? true
        let minutes = viewModel?.chatIntervalMinutes ?? PetViewModel.defaultChatInterval
        chatDescLabel?.stringValue = on
            ? "宠物会适时冒泡，结合热搜与你的 Todo 打个招呼（勿扰/睡觉时不打扰）"
            : "关闭后宠物不会主动搭话（喝水、天气提醒不受影响）"
        chatToggle?.isOn = on
        for (m, btn) in chatIntervalButtons {
            let selected = (m == minutes)
            btn.isEnabled = on
            btn.alphaValue = on ? 1.0 : 0.4
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
            case .expired:
                alert.messageText = "激活码已过期"
                alert.informativeText = "该激活码已超过有效期，请联系客服获取新的激活码"
            case .networkError:
                alert.messageText = "网络异常"
                alert.informativeText = "无法连接校验服务，请检查网络后重试"
            case .badFormat:
                alert.messageText = "激活码格式不正确"
                alert.informativeText = "激活码是 12 位字母数字（形如 XXXX-XXXX-XXXX）\n请检查是否误粘贴了其它内容"
            case .localError:
                alert.messageText = "本地处理失败"
                alert.informativeText = "校验码加密失败，请重试；若持续出现请反馈日志"
            case .serverError:
                alert.messageText = "服务异常"
                alert.informativeText = "校验服务返回异常，请稍后重试"
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
        // 宠物大小为基础功能，不随权限禁用
    }

    // MARK: - 宠物大小滑块

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
        guard let field = obj.object as? NSTextField else { return }

        if field === petNameField {
            // 仅当仍处于编辑态时保存（保存按钮内部已先置只读，不会重复触发）
            if field.isEditable {
                savePetName(nil)
            }
            return
        }

        if field === weatherCityField {
            WeatherReminderService.shared.city = field.stringValue
            field.stringValue = WeatherReminderService.shared.city
            FileLogger.log("[WeatherReminder] 城市设置为：\(field.stringValue.isEmpty ? "按定位" : field.stringValue)")
            return
        }
    }

    /// 把 hour/minute 转成今天对应的 Date（仅用于日期选择器回显）
    static func dateForTime(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    /// 天气提醒时间变化（日期选择器只提供合法时分）
    @objc private func weatherTimeChanged(_ sender: NSDatePicker) {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: sender.dateValue)
        WeatherReminderService.shared.hour = comps.hour ?? WeatherReminderService.defaultHour
        WeatherReminderService.shared.minute = comps.minute ?? WeatherReminderService.defaultMinute
        refreshWeatherControls()
    }

    // MARK: - 分区 4：菜单设置（右键菜单项展示开关）

    private func fillMenuSettingsSection(_ container: NSView) {
        let cw = container.bounds.width
        let ch = container.bounds.height

        let titleLbl = NSTextField(labelWithString: "右键菜单")
        titleLbl.font = .systemFont(ofSize: 16, weight: .bold)
        titleLbl.textColor = .labelColor
        titleLbl.frame = NSRect(x: 16, y: ch - 42, width: cw - 32, height: 22)
        container.addSubview(titleLbl)

        let descLbl = NSTextField(labelWithString: "勾选宠物右键菜单中展示的功能项，取消勾选后菜单不再显示")
        descLbl.font = .systemFont(ofSize: 11)
        descLbl.textColor = .tertiaryLabelColor
        descLbl.frame = NSRect(x: 16, y: ch - 58, width: cw - 32, height: 15)
        container.addSubview(descLbl)

        let divider = NSBox(frame: NSRect(x: 16, y: ch - 66, width: cw - 32, height: 1))
        divider.boxType = .separator
        divider.autoresizingMask = .width
        container.addSubview(divider)

        // ── 卡片：菜单项复选框两列排布 ──
        let rowH: CGFloat = 34
        let rowCount = (ContextMenuPrefs.items.count + 1) / 2
        let cardH = CGFloat(rowCount) * rowH + 24
        let card = NSView(frame: NSRect(x: 16, y: ch - 66 - 14 - cardH, width: cw - 32, height: cardH))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0, alpha: 0.04).cgColor
        card.layer?.cornerRadius = 10
        // 窗口拉高时卡片贴顶（与堆栈区行为一致）
        card.autoresizingMask = [.width, .minYMargin]
        container.addSubview(card)

        let colW = (card.bounds.width - 28) / 2
        for (i, item) in ContextMenuPrefs.items.enumerated() {
            let col = i % 2
            let row = i / 2
            let cb = NSButton(checkboxWithTitle: item.title, target: self, action: #selector(contextMenuToggle(_:)))
            cb.tag = i
            cb.state = ContextMenuPrefs.isVisible(key: item.key) ? .on : .off
            cb.font = .systemFont(ofSize: 13)
            cb.frame = NSRect(
                x: 14 + CGFloat(col) * colW,
                y: card.bounds.height - 12 - CGFloat(row + 1) * rowH + (rowH - 18) / 2,
                width: colW - 8,
                height: 18
            )
            cb.autoresizingMask = .minYMargin
            card.addSubview(cb)
        }

        // 尾部说明：「关闭」等基础项固定展示，不参与配置
        let noteLbl = NSTextField(labelWithString: "注：「关闭 ❌」与「解锁更多功能 🔓」为固定项，始终展示")
        noteLbl.font = .systemFont(ofSize: 11)
        noteLbl.textColor = .tertiaryLabelColor
        noteLbl.frame = NSRect(x: 16, y: ch - 66 - 14 - cardH - 24, width: cw - 32, height: 15)
        noteLbl.autoresizingMask = [.width, .minYMargin]
        container.addSubview(noteLbl)
    }

    /// 右键菜单项展示开关（即改即生效，下次弹出菜单即应用）
    @objc private func contextMenuToggle(_ sender: NSButton) {
        let item = ContextMenuPrefs.items[sender.tag]
        ContextMenuPrefs.setVisible(sender.state == .on, key: item.key)
    }

    // MARK: - 分区 5：好友消息

    private func fillSocialSection(_ container: NSView) {
        let cw = container.bounds.width
        let ch = container.bounds.height

        let titleLbl = NSTextField(labelWithString: "好友消息")
        titleLbl.font = .systemFont(ofSize: 16, weight: .bold)
        titleLbl.textColor = .labelColor
        titleLbl.frame = NSRect(x: 16, y: ch - 42, width: cw - 32, height: 22)
        container.addSubview(titleLbl)

        let descLbl = NSTextField(labelWithString: "每只宠物都有一个专属宠物号；互加好友后可发消息，对方下次心跳即在头顶气泡收到")
        descLbl.font = .systemFont(ofSize: 11)
        descLbl.textColor = .tertiaryLabelColor
        descLbl.lineBreakMode = .byTruncatingTail
        descLbl.frame = NSRect(x: 16, y: ch - 60, width: cw - 32, height: 15)
        container.addSubview(descLbl)

        let divider = NSBox(frame: NSRect(x: 16, y: ch - 68, width: cw - 32, height: 1))
        divider.boxType = .separator
        divider.autoresizingMask = .width
        container.addSubview(divider)

        // ── 卡片 1：我的宠物号 ──
        let card1H: CGFloat = 60
        let card1Y = ch - 68 - 14 - card1H
        let petRow = makeSettingRow(frame: NSRect(x: 16, y: card1Y, width: cw - 32, height: card1H), in: container)
        let pw = petRow.bounds.width

        let petTitle = NSTextField(labelWithString: "我的宠物号")
        petTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        petTitle.textColor = .labelColor
        petTitle.frame = NSRect(x: 14, y: card1H - 26, width: 120, height: 18)
        petRow.addSubview(petTitle)

        let petNoValue = NSTextField(labelWithString: "尚未分配")
        petNoValue.font = .systemFont(ofSize: 15, weight: .bold)
        petNoValue.textColor = .controlAccentColor
        petNoValue.frame = NSRect(x: 14, y: 9, width: 220, height: 22)
        petRow.addSubview(petNoValue)
        myPetNoLabel = petNoValue

        let copyW: CGFloat = 60
        let refreshW: CGFloat = 84
        let copyBtn = NSButton(title: "复制", target: self, action: #selector(copyMyPetNo(_:)))
        copyBtn.bezelStyle = .rounded
        copyBtn.font = .systemFont(ofSize: 12)
        copyBtn.frame = NSRect(x: pw - 12 - refreshW - 8 - copyW, y: (card1H - 26) / 2, width: copyW, height: 26)
        copyBtn.autoresizingMask = .minXMargin
        petRow.addSubview(copyBtn)

        let refreshBtn = NSButton(title: "刷新", target: self, action: #selector(refreshSocialFromServer(_:)))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.font = .systemFont(ofSize: 12)
        refreshBtn.frame = NSRect(x: pw - 12 - refreshW, y: (card1H - 26) / 2, width: refreshW, height: 26)
        refreshBtn.autoresizingMask = .minXMargin
        petRow.addSubview(refreshBtn)
        refreshSocialBtn = refreshBtn

        // ── 卡片 2：添加好友 ──
        let card2H: CGFloat = 52
        let card2Y = card1Y - 12 - card2H
        let addRow = makeSettingRow(frame: NSRect(x: 16, y: card2Y, width: cw - 32, height: card2H), in: container)
        let aw = addRow.bounds.width

        let addTitle = NSTextField(labelWithString: "添加好友")
        addTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        addTitle.textColor = .labelColor
        addTitle.frame = NSRect(x: 14, y: (card2H - 18) / 2, width: 80, height: 18)
        addRow.addSubview(addTitle)

        let addBtnW: CGFloat = 60
        let field = NSTextField(frame: NSRect(x: 100, y: (card2H - 28) / 2, width: aw - 100 - 12 - addBtnW - 8, height: 28))
        field.placeholderString = "输入对方宠物号"
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.target = self
        field.action = #selector(addFriendClicked(_:))
        field.autoresizingMask = .width
        addRow.addSubview(field)
        addFriendField = field

        let addBtn = NSButton(title: "添加", target: self, action: #selector(addFriendClicked(_:)))
        addBtn.bezelStyle = .rounded
        addBtn.frame = NSRect(x: aw - 12 - addBtnW, y: (card2H - 26) / 2, width: addBtnW, height: 26)
        addBtn.autoresizingMask = .minXMargin
        addRow.addSubview(addBtn)

        // ── 好友列表标题 ──
        let friendsTitle = NSTextField(labelWithString: "我的好友")
        friendsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        friendsTitle.textColor = .labelColor
        friendsTitle.frame = NSRect(x: 16, y: card2Y - 14 - 18, width: 200, height: 18)
        friendsTitle.autoresizingMask = .minYMargin
        container.addSubview(friendsTitle)

        // 好友列表（独立竖向滚动容器，容纳不定数量好友）
        let listTopY = card2Y - 14 - 18 - 8
        let listBottomY: CGFloat = 40
        let listH = max(120, listTopY - listBottomY)
        let listFrame = NSRect(x: 16, y: listBottomY, width: cw - 32, height: listH)
        let scroll = NSScrollView(frame: listFrame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.autoresizingMask = [.width, .height, .minYMargin]
        container.addSubview(scroll)

        let doc = FlippedContainer(frame: NSRect(x: 0, y: 0, width: listFrame.width, height: listH))
        doc.autoresizingMask = [.width]
        scroll.documentView = doc
        friendsDocView = doc
        friendsListWidth = listFrame.width
        friendsViewportHeight = listH

        // ── 底部状态标签 ──
        let statusLbl = NSTextField(labelWithString: "")
        statusLbl.font = .systemFont(ofSize: 11)
        statusLbl.textColor = .secondaryLabelColor
        statusLbl.lineBreakMode = .byTruncatingTail
        statusLbl.frame = NSRect(x: 16, y: 14, width: cw - 32, height: 16)
        statusLbl.autoresizingMask = [.width, .minYMargin]
        container.addSubview(statusLbl)
        socialStatusLabel = statusLbl

        refreshMyPetNoUI()
        rebuildFriendsList(emptyHint: "还没有好友，输入对方宠物号点「添加」")
        refreshSocialFromServer(nil)
    }

    /// 单条好友行：名字 + 「发消息」 + 「删除」（发消息/删除按 index 绑定当前 socialFriends）
    private func makeFriendRow(_ f: PetFriend, index: Int, width: CGFloat, height: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor(white: 0, alpha: 0.04).cgColor
        row.layer?.cornerRadius = 8

        let delW: CGFloat = 56
        let sendW: CGFloat = 66

        let name = NSTextField(labelWithString: f.display)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 12, y: (height - 18) / 2, width: width - 200, height: 18)
        row.addSubview(name)

        let send = NSButton(title: "发消息", target: self, action: #selector(sendToFriend(_:)))
        send.bezelStyle = .rounded
        send.controlSize = .small
        send.font = .systemFont(ofSize: 11)
        send.tag = index
        send.frame = NSRect(x: width - 12 - delW - 8 - sendW, y: (height - 24) / 2, width: sendW, height: 24)
        row.addSubview(send)

        let del = NSButton(title: "删除", target: self, action: #selector(removeFriendClicked(_:)))
        del.bezelStyle = .rounded
        del.controlSize = .small
        del.font = .systemFont(ofSize: 11)
        del.tag = index
        del.frame = NSRect(x: width - 12 - delW, y: (height - 24) / 2, width: delW, height: 24)
        row.addSubview(del)

        return row
    }

    /// 依据 socialFriends 重建好友列表；列表短于视口时保持视口高度，超出时随内容增高（可滚动）
    private func rebuildFriendsList(emptyHint: String) {
        guard let doc = friendsDocView else { return }
        for v in doc.subviews { v.removeFromSuperview() }
        let w = friendsListWidth

        if socialFriends.isEmpty {
            let hint = NSTextField(labelWithString: emptyHint)
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .tertiaryLabelColor
            hint.alignment = .center
            hint.frame = NSRect(x: 0, y: 24, width: w, height: 18)
            doc.addSubview(hint)
            doc.frame = NSRect(x: 0, y: 0, width: w, height: friendsViewportHeight)
            return
        }

        var y: CGFloat = 0
        let rowH: CGFloat = 40
        let gap: CGFloat = 6
        for (i, f) in socialFriends.enumerated() {
            let row = makeFriendRow(f, index: i, width: w, height: rowH)
            row.frame = NSRect(x: 0, y: y, width: w, height: rowH)
            doc.addSubview(row)
            y += rowH + gap
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(y, friendsViewportHeight))
    }

    private func refreshMyPetNoUI() {
        let petNo = FriendService.myPetNo
        myPetNoLabel?.stringValue = petNo > 0 ? "#\(petNo)" : "尚未分配（联网后自动同步）"
    }

    @objc private func copyMyPetNo(_ sender: Any?) {
        let petNo = FriendService.myPetNo
        guard petNo > 0 else {
            socialStatusLabel?.stringValue = "宠物号尚未分配，先点「刷新」获取"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(petNo), forType: .string)
        socialStatusLabel?.stringValue = "已复制你的宠物号 #\(petNo)，发给好友即可被搜索添加"
    }

    /// 向服务端注册取宠物号 + 拉好友列表（打开分区与「刷新」按钮触发）
    @objc private func refreshSocialFromServer(_ sender: Any?) {
        guard !socialLoading else { return }
        socialLoading = true
        refreshSocialBtn?.title = "刷新中…"
        socialStatusLabel?.stringValue = "正在同步…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.socialLoading = false; self.refreshSocialBtn?.title = "刷新" }
            do {
                _ = try await FriendService.refreshMyPetNo()
                self.refreshMyPetNoUI()
                self.socialFriends = try await FriendService.listFriends()
                self.rebuildFriendsList(emptyHint: "还没有好友，输入对方宠物号点「添加」")
                self.socialStatusLabel?.stringValue = ""
            } catch {
                self.socialStatusLabel?.stringValue = "同步失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func addFriendClicked(_ sender: Any?) {
        guard let field = addFriendField else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let petNo = Int(raw), petNo > 0 else {
            socialStatusLabel?.stringValue = "请输入正确的宠物号（纯数字）"
            return
        }
        guard !socialLoading else { return }
        socialLoading = true
        socialStatusLabel?.stringValue = "正在添加…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.socialLoading = false }
            do {
                self.socialFriends = try await FriendService.addFriend(petNo: petNo)
                field.stringValue = ""
                field.window?.makeFirstResponder(nil)
                self.rebuildFriendsList(emptyHint: "还没有好友")
                self.socialStatusLabel?.stringValue = "已添加好友 #\(petNo)"
            } catch {
                self.socialStatusLabel?.stringValue = "添加失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func removeFriendClicked(_ sender: NSButton) {
        guard socialFriends.indices.contains(sender.tag) else { return }
        let f = socialFriends[sender.tag]
        guard !socialLoading else { return }
        socialLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.socialLoading = false }
            do {
                self.socialFriends = try await FriendService.removeFriend(petNo: f.petNo)
                self.rebuildFriendsList(emptyHint: "还没有好友")
                self.socialStatusLabel?.stringValue = "已删除好友 \(f.display)"
            } catch {
                self.socialStatusLabel?.stringValue = "删除失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func sendToFriend(_ sender: NSButton) {
        guard socialFriends.indices.contains(sender.tag) else { return }
        let f = socialFriends[sender.tag]
        let alert = NSAlert()
        alert.messageText = "发消息给 \(f.display)"
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "想对 TA 说的话…"
        field.font = .systemFont(ofSize: 13)
        alert.accessoryView = field
        alert.addButton(withTitle: "发送")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: self) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let self else { return }
            self.socialStatusLabel?.stringValue = "正在发送…"
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await FriendService.sendMessage(toPetNo: f.petNo, text: text)
                    self.socialStatusLabel?.stringValue = "已发送，对方下次心跳（约 1 分钟内）即可收到"
                } catch {
                    self.socialStatusLabel?.stringValue = "发送失败：\(error.localizedDescription)"
                }
            }
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

    // MARK: - 状态格（形象切换 + 图片预览）

    /// 状态格点击：切换到该状态并刷新高亮。
    @objc private func stateTileClicked(_ sender: NSButton) {
        guard let state = customSpriteState(for: sender) else { return }
        viewModel?.transitionTo(state)
        refreshStateCards()
    }

    /// 状态格选中样式（当前态 accent 描边 + 淡底）。
    private func applyTileStyle(_ btn: NSButton, selected: Bool) {
        btn.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            : NSColor(white: 0, alpha: 0.03).cgColor
        btn.layer?.borderWidth = selected ? 2 : 1
        btn.layer?.borderColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        btn.contentTintColor = selected ? .controlAccentColor : .labelColor
    }

    /// 根据 viewModel 当前真实动画状态刷新所有状态格的选中样式与预览图
    /// （在面板显示时和动画状态变化时调用，保证面板与真实状态同步）
    func refreshStateCards() {
        guard let current = viewModel?.animationState else { return }
        for state in CatAnimationState.allCases {
            guard let tile = spritePreviewButtons[state] else { continue }
            tile.image = customSpriteImage(for: state)
            let selected = (current == state)
            tile.state = selected ? .on : .off
            tile.title = selected ? "✓ \(state.displayName)" : state.displayName
            applyTileStyle(tile, selected: selected)
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

// MARK: - 好友列表翻转文档视图（内容自顶向下排布）

final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
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

    /// 是否可交互（false 时置灰且不响应点击）
    var isEnabled: Bool = true {
        didSet { refresh(animated: false) }
    }

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
        guard isEnabled else { return }
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
        trackLayer.backgroundColor = (isOn ? NSColor.systemGreen : NSColor.systemGray)
            .withAlphaComponent(isEnabled ? 1.0 : 0.4).cgColor

        // 滑块：白色圆钮，随开关左右移动
        let thumbSize = h - 6
        let x = isOn ? w - thumbSize - 3 : 3
        thumbLayer.frame = NSRect(x: x, y: 3, width: thumbSize, height: thumbSize)
        thumbLayer.cornerRadius = thumbSize / 2
        thumbLayer.backgroundColor = NSColor.white.withAlphaComponent(isEnabled ? 1.0 : 0.6).cgColor
        thumbLayer.shadowOpacity = 0.3
        thumbLayer.shadowRadius = 1
        thumbLayer.shadowOffset = CGSize(width: 0, height: 0.5)

        CATransaction.commit()
    }
}


