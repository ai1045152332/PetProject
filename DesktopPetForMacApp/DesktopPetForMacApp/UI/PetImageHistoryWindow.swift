// PetImageHistoryWindow.swift
// DesktopPetForMacApp — 图片历史浏览器（缩略图网格 + 单击预览 / 双击应用）
//
// 旧版是「状态下拉 + 图片下拉 + 4 个 alert 按钮」：想认出一张图要逐条展开菜单，应用一张图
// 要「切筛选 → 选条目 → 点应用」三步。这里把本机历史摊平成缩略图网格，一眼看全，双击即用。

import AppKit

/// 本机图片历史面板（以 sheet 形式挂在设置面板上）
///
/// 数据全部来自本机文件，服务端只负责生成与存储；打开面板不走网络。
@MainActor
final class PetImageHistoryWindow: NSWindow {

    // MARK: - 尺寸约定

    private enum Layout {
        static let pad: CGFloat = 16
        static let topBarH: CGFloat = 26
        static let bottomBarH: CGFloat = 26
        static let detailW: CGFloat = 232
        static let columns = 4
        static let tileGap: CGFloat = 10
        static let rowGap: CGFloat = 12
        static let tileH: CGFloat = 165
        static let windowW: CGFloat = 820
        static let windowH: CGFloat = 580
    }

    // MARK: - 数据

    private var items: [CustomSpriteStore.LocalImageItem] = []
    private var failures: [String: CustomSpriteStore.SpriteFailure] = [:]
    /// 当前筛选（也就是应用目标）的状态：面板永远只看一个状态，不再提供「全部」总览
    private var filterState: CatAnimationState
    /// 当前选中卡片：图片用 item.key，失败记录用 "failure:<state>"
    private var selectedKey: String?
    /// 上一次渲染详情对应的 key：换图时才重置「应用目标」，同一张图刷新不打断用户选择
    private var lastDetailKey: String?
    /// 打开面板时宠物所处状态：默认排序靠前、应用目标的兜底
    private let preferredState: CatAnimationState

    private var tiles: [HistoryTileView] = []
    private var itemByKey: [String: CustomSpriteStore.LocalImageItem] = [:]
    private var failureByKey: [String: (state: CatAnimationState, failure: CustomSpriteStore.SpriteFailure)] = [:]
    /// 缩略图与预览共用解码缓存，反复切换不重复读盘
    private var imageCache: [String: NSImage] = [:]

    // MARK: - 回调（业务由设置面板处理，面板只负责展示与交互）

    /// 应用某张本机图片到某状态
    var onApply: ((CustomSpriteStore.LocalImageItem, CatAnimationState) -> Void)?
    var onDelete: ((CustomSpriteStore.LocalImageItem) -> Void)?
    var onClearFailure: ((CatAnimationState) -> Void)?
    var onRetry: ((CatAnimationState, CustomSpriteStore.SpriteFailure) -> Void)?
    /// 面板已关闭（供设置面板清掉强引用）
    var onDismiss: (() -> Void)?

    // MARK: - 子视图

    private var filterControl: NSSegmentedControl!
    private var countLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var gridView: FlippedDocumentView!
    private var previewView: NSImageView!
    private var detailLabel: NSTextField!
    private var targetPopUp: NSPopUpButton!
    private var primaryButton: NSButton!
    private var secondaryButton: NSButton!
    private var tertiaryButton: NSButton!

    // MARK: - 初始化

    init(items: [CustomSpriteStore.LocalImageItem],
         failures: [String: CustomSpriteStore.SpriteFailure],
         initialState: CatAnimationState) {
        self.items = items
        self.failures = failures
        self.preferredState = initialState
        self.filterState = initialState
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowW, height: Layout.windowH),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        title = "图片历史"
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        buildUI()
        reload(items: items, failures: failures)
    }

    /// 外部数据变化后刷新（补全归属、删除、重试落盘都会走这里）
    func reload(items: [CustomSpriteStore.LocalImageItem], failures: [String: CustomSpriteStore.SpriteFailure]) {
        self.items = items
        self.failures = failures
        // 已删除的图不再占内存；直传图在 thumbnail() 里始终重新读盘
        let alive = Set(items.map(\.key))
        imageCache = imageCache.filter { alive.contains($0.key) }
        rebuildTiles()
    }

    // MARK: - UI 构建

    private func buildUI() {
        guard let contentView else { return }
        let W = Layout.windowW
        let H = Layout.windowH

        let bg = NSVisualEffectView(frame: contentView.bounds)
        bg.material = .windowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.autoresizingMask = [.width, .height]
        contentView.addSubview(bg)

        // ── 顶部：状态切换（分段控件，一屏一个状态） ──
        let filterTop = H - Layout.pad - Layout.topBarH
        filterControl = NSSegmentedControl(
            labels: CatAnimationState.allCases.map(\.displayName),
            trackingMode: .selectOne,
            target: self,
            action: #selector(filterChanged(_:))
        )
        filterControl.frame = NSRect(x: Layout.pad, y: filterTop, width: 380, height: Layout.topBarH)
        filterControl.segmentStyle = .rounded
        filterControl.selectedSegment = CatAnimationState.allCases.firstIndex(of: preferredState) ?? 0
        filterControl.toolTip = "查看某个状态的可用图片；直接上传只属于它的状态，AI 图可应用到任意状态"
        bg.addSubview(filterControl)

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: W - Layout.pad - 260, y: filterTop + 5, width: 260, height: 16)
        bg.addSubview(countLabel)

        // ── 中部：左网格 + 右详情 ──
        let middleY = Layout.pad + Layout.bottomBarH + 16
        let middleH = filterTop - 12 - middleY
        let gridW = W - Layout.pad * 3 - Layout.detailW

        scrollView = NSScrollView(frame: NSRect(x: Layout.pad, y: middleY, width: gridW, height: middleH))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        gridView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: gridW, height: middleH))
        scrollView.documentView = gridView
        bg.addSubview(scrollView)

        buildDetailBox(x: Layout.pad * 2 + gridW, y: middleY, width: Layout.detailW, height: middleH, in: bg)

        // ── 底部：操作提示 + 关闭 ──
        let hint = NSTextField(labelWithString: "单击选中看大图 · 双击直接应用 · 右键更多操作")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: Layout.pad, y: Layout.pad + 5, width: 520, height: 16)
        bg.addSubview(hint)

        let closeBtn = NSButton(title: "完成", target: self, action: #selector(closePressed))
        closeBtn.bezelStyle = .rounded
        closeBtn.frame = NSRect(x: W - Layout.pad - 84, y: Layout.pad, width: 84, height: Layout.bottomBarH)
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.toolTip = "关闭图片历史（Esc）"
        bg.addSubview(closeBtn)
    }

    private func buildDetailBox(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, in parent: NSView) {
        let box = NSVisualEffectView(frame: NSRect(x: x, y: y, width: width, height: height))
        box.material = .contentBackground
        box.blendingMode = .withinWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        parent.addSubview(box)

        previewView = NSImageView(frame: NSRect(x: 16, y: height - 8 - 200, width: 200, height: 200))
        previewView.imageScaling = .scaleProportionallyDown
        previewView.imageAlignment = .alignCenter
        previewView.animates = true
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 10
        previewView.layer?.masksToBounds = true
        previewView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        box.addSubview(previewView)

        detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        box.addSubview(detailLabel)

        let targetTitle = NSTextField(labelWithString: "应用目标")
        targetTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        targetTitle.textColor = .secondaryLabelColor
        targetTitle.frame = NSRect(x: 12, y: 134, width: 208, height: 14)
        box.addSubview(targetTitle)

        targetPopUp = NSPopUpButton(frame: NSRect(x: 12, y: 104, width: 208, height: 26))
        targetPopUp.addItems(withTitles: CatAnimationState.allCases.map(\.displayName))
        targetPopUp.selectItem(at: CatAnimationState.allCases.firstIndex(of: preferredState) ?? 0)
        targetPopUp.target = self
        targetPopUp.action = #selector(targetChanged)
        box.addSubview(targetPopUp)

        primaryButton = makeDetailButton("应用", action: #selector(primaryPressed))
        primaryButton.frame = NSRect(x: 12, y: 68, width: 208, height: 30)
        primaryButton.bezelColor = .controlAccentColor
        primaryButton.contentTintColor = .white
        primaryButton.font = .systemFont(ofSize: 12, weight: .semibold)
        box.addSubview(primaryButton)

        secondaryButton = makeDetailButton("删除", action: #selector(secondaryPressed))
        secondaryButton.frame = NSRect(x: 12, y: 34, width: 100, height: 26)
        box.addSubview(secondaryButton)

        tertiaryButton = makeDetailButton("在 Finder 显示", action: #selector(tertiaryPressed))
        tertiaryButton.frame = NSRect(x: 120, y: 34, width: 100, height: 26)
        tertiaryButton.font = .systemFont(ofSize: 10)
        box.addSubview(tertiaryButton)
    }

    private func makeDetailButton(_ title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .regular
        btn.font = .systemFont(ofSize: 11, weight: .medium)
        btn.autoresizingMask = []
        return btn
    }

    // MARK: - 列表重建

    private func rebuildTiles() {
        for tile in tiles { tile.removeFromSuperview() }
        tiles = []
        itemByKey = [:]
        failureByKey = [:]

        let list = filteredItems()
        let failureList = filteredFailures()

        for item in list {
            let title = tileTitle(for: item)
            let subtitle = "\(Self.formatDate(item.modified)) · \(Self.formatSize(item.size))"
            let tile = HistoryTileView(key: item.key, title: title, subtitle: subtitle,
                                       thumbnail: thumbnail(for: item), placeholder: nil)
            tile.onTap = { [weak self] tile, clickCount in self?.tileTapped(tile, clickCount: clickCount) }
            tile.onContextMenu = { [weak self] tile, event in self?.showContextMenu(for: tile, event: event) }
            itemByKey[item.key] = item
            tiles.append(tile)
        }
        for (state, failure) in failureList {
            let key = "failure:" + state.rawValue
            let title = "⚠ 失败 · \(state.displayName)"
            let subtitle = "\(Self.formatDate(failure.at)) · 点此重试"
            let tile = HistoryTileView(key: key, title: title, subtitle: subtitle,
                                       thumbnail: nil, placeholder: "⚠️")
            tile.onTap = { [weak self] tile, clickCount in self?.tileTapped(tile, clickCount: clickCount) }
            tile.onContextMenu = { [weak self] tile, event in self?.showContextMenu(for: tile, event: event) }
            failureByKey[key] = (state, failure)
            tiles.append(tile)
        }

        layoutTiles()

        countLabel.stringValue = "\(filterState.displayName) · \(tiles.count) 张"
        if tiles.isEmpty {
            select(key: nil)
        } else if let key = selectedKey, tiles.contains(where: { $0.key == key }) {
            select(key: key)
        } else {
            // 默认选中当前状态正在生效的那张，没有就选第一张
            let activeKey = list.first { $0.selectedStates.contains(preferredState) }?.key
            select(key: activeKey ?? tiles[0].key)
        }
    }

    private func layoutTiles() {
        let gridW = scrollView.frame.width
        let cols = Layout.columns
        let tileW = floor((gridW - CGFloat(cols - 1) * Layout.tileGap) / CGFloat(cols))
        let offsetX = max(0, (gridW - (tileW * CGFloat(cols) + Layout.tileGap * CGFloat(cols - 1))) / 2)
        for (index, tile) in tiles.enumerated() {
            let col = index % cols
            let row = index / cols
            tile.frame = NSRect(
                x: offsetX + CGFloat(col) * (tileW + Layout.tileGap),
                y: CGFloat(row) * (Layout.tileH + Layout.rowGap),
                width: tileW,
                height: Layout.tileH
            )
        }
        for tile in tiles where tile.superview !== gridView {
            gridView.addSubview(tile)
        }
        let rows = (tiles.count + cols - 1) / cols
        let contentH = rows == 0 ? 0 : CGFloat(rows) * Layout.tileH + CGFloat(rows - 1) * Layout.rowGap
        gridView.frame = NSRect(x: 0, y: 0, width: gridW, height: max(contentH, scrollView.contentSize.height))
    }

    /// 只列当前状态可用的图：直传图绑定该状态、AI 图按生成状态归类；未归属老图置底保留可达性。
    private func filteredItems() -> [CustomSpriteStore.LocalImageItem] {
        func newestFirst(_ list: [CustomSpriteStore.LocalImageItem]) -> [CustomSpriteStore.LocalImageItem] {
            list.sorted { $0.modified > $1.modified }
        }
        let state = filterState
        let unassigned = newestFirst(items.filter { !$0.isDirect && $0.boundState == nil })
        return newestFirst(items.filter { $0.boundState == state }) + unassigned
    }

    private func filteredFailures() -> [(CatAnimationState, CustomSpriteStore.SpriteFailure)] {
        failures[filterState.rawValue].map { [(filterState, $0)] } ?? []
    }

    private func tileTitle(for item: CustomSpriteStore.LocalImageItem) -> String {
        // 面板一屏只有一个状态，标题不再重复状态名，只说来源
        let mark = item.selectedStates.isEmpty ? "" : "✓ "
        if item.isDirect { return mark + "📷 直接上传" }
        return mark + (item.boundState == nil ? "🪄 未归属" : "🪄 AI 生成")
    }

    private func thumbnail(for item: CustomSpriteStore.LocalImageItem) -> NSImage? {
        // 直传图按状态复用同一文件名，重新上传后必须重新读盘，不能吃旧缓存
        if !item.isDirect, let cached = imageCache[item.key] { return cached }
        // NSImage 对 GIF 只画第一帧：网格里几十张图同时动画会拖慢面板，动图留给右侧大预览
        guard let image = NSImage(contentsOf: item.url) else { return nil }
        imageCache[item.key] = image
        return image
    }

    // MARK: - 选中与详情

    private func select(key: String?) {
        selectedKey = key
        for tile in tiles { tile.isSelected = (tile.key == key) }
        refreshDetail()
    }

    private var selectedItem: CustomSpriteStore.LocalImageItem? {
        selectedKey.flatMap { itemByKey[$0] }
    }

    private var selectedFailure: (state: CatAnimationState, failure: CustomSpriteStore.SpriteFailure)? {
        selectedKey.flatMap { failureByKey[$0] }
    }

    private var targetState: CatAnimationState {
        let idx = targetPopUp.indexOfSelectedItem
        return CatAnimationState.allCases.indices.contains(idx) ? CatAnimationState.allCases[idx] : preferredState
    }

    private func refreshDetail() {
        let switched = selectedKey != lastDetailKey
        lastDetailKey = selectedKey
        if let pair = selectedFailure {
            previewView.image = nil
            targetPopUp.isEnabled = false
            primaryButton.title = "🔁 重试生成"
            primaryButton.isEnabled = true
            secondaryButton.title = "清除记录"
            secondaryButton.isEnabled = true
            tertiaryButton.isHidden = true
            setDetail("\(pair.state.displayName)状态生成失败\n\(pair.failure.message)\n时间：\(Self.formatDate(pair.failure.at))\n任务：\(pair.failure.serverID.map { String($0.prefix(8)) } ?? "无")\n生成本机没拿到图，可重试一次。")
            return
        }
        guard let item = selectedItem else {
            previewView.image = nil
            targetPopUp.isEnabled = false
            primaryButton.title = "应用"
            primaryButton.isEnabled = false
            secondaryButton.isEnabled = false
            tertiaryButton.isHidden = false
            setDetail("这一栏暂时没有图片。\n用「直接上传」或「AI 生成」添加后，历史都会保存在本机。")
            return
        }

        if let cached = imageCache[item.key] {
            previewView.image = cached
        } else if let image = NSImage(contentsOf: item.url) {
            imageCache[item.key] = image
            previewView.image = image
        } else {
            previewView.image = nil
        }

        // 直传图只能回自己的状态；AI 图可应用到任意状态，默认先落到它的生成状态
        if item.isDirect, let bound = item.boundState {
            targetPopUp.selectItem(at: CatAnimationState.allCases.firstIndex(of: bound) ?? 0)
            targetPopUp.isEnabled = false
            primaryButton.title = "应用到\(bound.displayName)"
        } else {
            if switched, let owner = item.boundState {
                targetPopUp.selectItem(at: CatAnimationState.allCases.firstIndex(of: owner) ?? 0)
            }
            targetPopUp.isEnabled = true
            primaryButton.title = "应用到\(targetState.displayName)"
        }
        primaryButton.isEnabled = true
        secondaryButton.title = "删除"
        secondaryButton.isEnabled = true
        tertiaryButton.isHidden = false

        let owner = item.boundState.map { item.isDirect ? "\($0.displayName)（只属于该状态）" : "\($0.displayName)（生成状态）" }
            ?? "未归属（应用后自动归类）"
        let applied = item.selectedStates.isEmpty
            ? "未生效"
            : "生效中：\(item.selectedStates.map(\.displayName).joined(separator: "、"))"
        setDetail("\(item.isDirect ? "直接上传" : "AI 生成")\n所属状态：\(owner)\n\(applied)\n\(Self.formatDate(item.modified)) · \(Self.formatSize(item.size))")
    }

    /// 说明文字顶部对齐预览图下沿，高度随内容收缩。
    private func setDetail(_ text: String) {
        detailLabel.stringValue = text
        let width: CGFloat = Layout.detailW - 24
        let fitted = detailLabel.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        let height = max(16, min(fitted.height, 100))
        let previewBottom = previewView.frame.minY - 6
        detailLabel.frame = NSRect(x: 12, y: previewBottom - height, width: width, height: height)
    }

    // MARK: - 交互

    private func tileTapped(_ tile: HistoryTileView, clickCount: Int) {
        select(key: tile.key)
        guard clickCount >= 2 else { return }
        // 双击 = 立刻应用（失败卡片双击 = 重试）
        if failureByKey[tile.key] != nil {
            retrySelected()
        } else {
            applySelected()
        }
    }

    private func showContextMenu(for tile: HistoryTileView, event: NSEvent) {
        select(key: tile.key)
        let menu = NSMenu()
        if let pair = failureByKey[tile.key] {
            let retry = NSMenuItem(title: "重试生成\(pair.state.displayName)", action: #selector(primaryPressed), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
            let clear = NSMenuItem(title: "清除失败记录", action: #selector(clearFailureAction), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        } else if let item = itemByKey[tile.key] {
            let state = item.isDirect ? (item.boundState ?? targetState) : targetState
            let apply = NSMenuItem(title: "应用到\(state.displayName)", action: #selector(applyAction), keyEquivalent: "")
            apply.target = self
            menu.addItem(apply)
            let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(revealAction), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
            menu.addItem(.separator())
            let del = NSMenuItem(title: "删除这张图", action: #selector(deleteAction), keyEquivalent: "")
            del.target = self
            menu.addItem(del)
        }
        guard !menu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: tile)
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard CatAnimationState.allCases.indices.contains(index) else { return }
        filterState = CatAnimationState.allCases[index]
        // 应用目标跟着切到当前状态，切完即点「应用」不会落到上一个状态
        targetPopUp.selectItem(at: index)
        selectedKey = nil
        lastDetailKey = nil
        rebuildTiles()
    }

    @objc private func targetChanged() {
        if let item = selectedItem, !item.isDirect {
            primaryButton.title = "应用到\(targetState.displayName)"
        }
    }

    @objc private func primaryPressed() {
        if failureByKey[selectedKey ?? ""] != nil {
            retrySelected()
        } else {
            applySelected()
        }
    }

    @objc private func secondaryPressed() {
        if selectedFailure != nil {
            clearFailureAction()
        } else {
            deleteAction()
        }
    }

    @objc private func tertiaryPressed() { revealAction() }

    @objc private func applyAction() { applySelected() }
    @objc private func deleteAction() { deleteSelected() }
    @objc private func revealAction() {
        guard let item = selectedItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func clearFailureAction() {
        guard let pair = selectedFailure else { return }
        onClearFailure?(pair.state)
        selectedKey = nil
        // 外部刷新本机清单后会把新数据推回来
    }

    private func applySelected() {
        guard let item = selectedItem else { return }
        let state = item.isDirect ? (item.boundState ?? targetState) : targetState
        onApply?(item, state)
        dismiss()
    }

    private func retrySelected() {
        guard let pair = selectedFailure else { return }
        onRetry?(pair.state, pair.failure)
        dismiss()
    }

    private func deleteSelected() {
        guard let item = selectedItem else { return }
        let alert = NSAlert()
        alert.messageText = "删除这张本机图片？"
        alert.informativeText = "只删本机文件；若它正被某个状态使用，该状态会恢复内置默认图。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: self) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onDelete?(item)
        }
    }

    @objc private func closePressed() { dismiss() }

    private func dismiss() {
        if let parent = sheetParent {
            parent.endSheet(self)
        } else {
            orderOut(nil)
        }
        // 延后一拍再交还引用：避免在自身按钮的事件堆栈里释放该窗口
        DispatchQueue.main.async { [weak self] in self?.onDismiss?() }
    }

    // MARK: - 格式化

    private static func formatDate(_ date: Date) -> String {
        guard date != .distantPast else { return "未知时间" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - 滚动文档视图（flipped：内容自顶向下排布）

@MainActor
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 缩略图卡片

/// 一张缩略图：图片 + 两行文字 + 选中/hover 描边。
/// 用自绘而非嵌套控件，几十张卡片滚动时不产生额外视图层级与 GIF 解码开销。
@MainActor
private final class HistoryTileView: NSView {
    let key: String
    private let titleText: String
    private let subtitleText: String
    private let thumbnail: NSImage?
    private let placeholder: String?

    var onTap: ((HistoryTileView, Int) -> Void)?
    var onContextMenu: ((HistoryTileView, NSEvent) -> Void)?

    var isSelected = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(key: String, title: String, subtitle: String, thumbnail: NSImage?, placeholder: String?) {
        self.key = key
        self.titleText = title
        self.subtitleText = subtitle
        self.thumbnail = thumbnail
        self.placeholder = placeholder
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        onTap?(self, event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(self, event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: outer, xRadius: 10, yRadius: 10)

        let fill: NSColor
        if isSelected {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.16)
        } else if isHovered {
            fill = NSColor.labelColor.withAlphaComponent(0.09)
        } else {
            fill = NSColor.labelColor.withAlphaComponent(0.04)
        }
        fill.setFill()
        path.fill()

        let imageH = bounds.width - 12
        let imageRect = NSRect(x: 6, y: bounds.height - 6 - imageH, width: bounds.width - 12, height: imageH)
        let imagePath = NSBezierPath(roundedRect: imageRect, xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        imagePath.fill()

        NSGraphicsContext.saveGraphicsState()
        imagePath.addClip()
        if let thumbnail {
            let size = thumbnail.size
            let scale = min(imageRect.width / max(size.width, 1), imageRect.height / max(size.height, 1))
            let w = size.width * scale
            let h = size.height * scale
            let rect = NSRect(x: imageRect.midX - w / 2, y: imageRect.midY - h / 2, width: w, height: h)
            thumbnail.draw(in: rect)
        } else if let placeholder {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let text = placeholder as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: imageRect.midX - textSize.width / 2,
                                  y: imageRect.midY - textSize.height / 2),
                      withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        // 选中描边画在图片之上，避免被裁切
        NSColor.controlAccentColor.withAlphaComponent(isSelected ? 1 : 0).setStroke()
        let stroke = NSBezierPath(roundedRect: outer.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        stroke.lineWidth = 2
        stroke.stroke()

        let textWidth = bounds.width - 16
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Self.truncatingStyle
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: Self.truncatingStyle
        ]
        (titleText as NSString).draw(
            with: NSRect(x: 8, y: 22, width: textWidth, height: 15),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: titleAttrs
        )
        (subtitleText as NSString).draw(
            with: NSRect(x: 8, y: 7, width: textWidth, height: 13),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: subtitleAttrs
        )
    }

    private static let truncatingStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
}
