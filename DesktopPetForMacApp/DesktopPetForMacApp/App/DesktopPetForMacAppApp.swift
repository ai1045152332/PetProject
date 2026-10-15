// DesktopPetForMacAppApp.swift
// DesktopPetForMacApp — macOS 桌面小猫应用
// 入口文件：初始化浮动窗口、检测权限、启动事件监听

import SwiftUI
import AppKit

@main
struct DesktopPetForMacAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var floatingWindow: FloatingWindow?
    var viewModel: PetViewModel?
    var statusItem: NSStatusItem?
    private var settingsPanel: SettingsPanel?
    private var menuBarTimer: Timer?
    private var sysInfoTimer: Timer?
    // 系统信息二级菜单及其条目（实时刷新）
    private var sysInfoMenu: NSMenu?
    private var sysInfoItems: [NSMenuItem] = []
    /// CPU 环形图菜单项视图（始终刷新，不受勾选控制）
    private var cpuChartView: RingChartView?
    /// 内存环形图菜单项视图（始终刷新，不受勾选控制）
    private var memChartView: RingChartView?
    /// 一键清理内存菜单项（基础权限置灰）
    private var cleanMemoryItem: NSMenuItem?
    // ── 环形图配色（浅灰底上加深一档，清晰协调）──
    private let userColor = NSColor(calibratedRed: 0.35, green: 0.47, blue: 0.88, alpha: 1.0)      // CPU 用户-蓝紫
    private let systemColor = NSColor(calibratedRed: 0.92, green: 0.58, blue: 0.12, alpha: 1.0)   // CPU 系统-琥珀
    private let idleColor = NSColor(calibratedRed: 0.30, green: 0.65, blue: 0.38, alpha: 1.0)     // CPU 闲置-绿
    private let memUsedColor = NSColor(calibratedRed: 0.85, green: 0.33, blue: 0.42, alpha: 1.0)  // 内存已用-玫红
    private let memFreeColor = NSColor(calibratedRed: 0.40, green: 0.72, blue: 0.48, alpha: 1.0)  // 内存空闲-青绿
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化文件日志
        FileLogger.setup()

        // 单实例保护：若已有同 BundleID 实例在运行，激活旧实例并退出自身
        // （避免 LaunchAgent 自动启动 + 手动启动 导致两个小猫并存）
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != selfPID }) {
            existing.activate(options: [.activateAllWindows])
            FileLogger.log("[DesktopPet] 检测到已有实例(pid=\(existing.processIdentifier))，本次退出")
            NSApp.terminate(nil)
            return
        }

        // 开机自启配置（默认开启，启动时确保 LaunchAgent 已安装/卸载）
        AutoLaunchManager.applyOnLaunch()

        // 说明：升级不再清空校验权限，改为随版本检查一起定时向服务端复核授权

        // 首次启动随机分配宠物名称（已设置过的不变）
        PetName.ensureAssigned()

        // 后台初始化词库并打印加载诊断（避免阻塞主线程，利于排查「背单词找不到单词」）
        DispatchQueue.global(qos: .utility).async {
            WordBankManager.shared.printAllWordBankInfo()
        }

        // 直接启动小猫，不做密码验证
        DispatchQueue.main.async { [weak self] in
            self?.setupCat()
            // 后台检测权限，未授权时静默提示
            AccessibilityHelper.checkPermissionAsync { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self?.showPermissionBanner()
                    }
                }
            }
        }
    }
    
    @MainActor private func setupCat() {
        // 2. 创建状态机
        let vm = PetViewModel()
        self.viewModel = vm
        
        // 动画状态变化时，若设置面板已存在则刷新其状态卡片（保持与真实状态同步）
        vm.onStateChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.settingsPanel?.refreshStateCards()
            }
        }
        
        // 3. 创建浮动窗口
        let window = FloatingWindow(viewModel: vm)
        self.floatingWindow = window
        window.show()
        
        // 4. 启动全局鼠标位置监听（用于"看向鼠标"效果）
        startGlobalMouseTracking()
        
        // 4.5 连接窗口缩放回调（滑块修改 catScale 后触发）
        vm.onResizeWindow = { [weak self] scale in
            self?.floatingWindow?.resizeWindow(scale: scale)
        }
        
        // 5. 创建顶部菜单栏图标
        setupStatusBar()
        
        // 6. 菜单栏系统指标监控（CPU / 内存 / 温度）
        startMenuBarMonitoring()
        
        // 7. 系统信息二级菜单实时监控（CPU / 内存 / 磁盘 / 网络）
        startSysInfoMonitoring()
        
        // 8. 启动心跳上报（每 1 分钟向 Go 后端上报本机信息、版本号与宠物状态）
        HeartbeatService.shared.attach(viewModel: vm)
        HeartbeatService.shared.start()
        
        // 9. 启动自动更新检查（启动后延迟检查，之后每 6 小时一次）
        UpdateService.shared.start()

        // 8.5 系统勿扰/专注模式单向跟随（只读检测，不改变系统状态）：
        // 系统勿扰开启 → 小猫切专注；退出 → 小猫回休闲
        FocusModeMonitor.shared.onSystemFocusChange = { [weak vm] active in
            DispatchQueue.main.async {
                guard let vm else { return }
                vm.systemFocusActive = active
                vm.transitionTo(active ? .focus : .idel)
            }
        }
        FocusModeMonitor.shared.start()

        // 9. 首次启动引导弹窗（填写宠物名称）
        OnboardingWindow.showIfNeeded { [weak self] in
            DispatchQueue.main.async {
                self?.refreshMenuAccess()
            }
        }

        // 10. 「解锁更多功能」引导：右键菜单点击后打开设置、锚定通用设置并高亮闪烁「权限」栏
        NotificationCenter.default.addObserver(
            forName: .init("DesktopPet.ShowAccessSettings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showSettings(nil)
                self?.settingsPanel?.showGeneralAndFlashAccess()
            }
        }
    }
    
    // MARK: - 菜单栏
    @MainActor private func setupStatusBar() {
        let statusBar = NSStatusBar.system
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item
        
        let btn = item.button!
        
        // 使用项目 Resources 中的白猫图标
        let iconPath = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png")
        ?? Bundle.main.bundlePath + "/Contents/Resources/MenuBarIcon.png"
        let img = NSImage(contentsOfFile: iconPath)
        img?.size = NSSize(width: 22, height: 22)
        img?.isTemplate = true  // 系统会根据菜单栏深浅色自动反色为白色
        btn.image = img
        
        // 创建菜单
        let menu = NSMenu()
        // 关闭自动启用：否则 AppKit 会按 target/action 自动启用所有项，覆盖权限置灰
        menu.autoenablesItems = false

        // ── 最上面：系统信息（二级菜单，悬停/点击展开，实时监控）──
        // 二级菜单的每个指标条目都可点击勾选：勾选后显示在顶部菜单栏
        let sysInfoItem = NSMenuItem(title: "系统信息", action: nil, keyEquivalent: "")
        let subMenu = NSMenu()
        // 强制浅色外观：白灰背景 + 黑色文字，与环形图浅色主题统一
        subMenu.appearance = NSAppearance(named: .aqua)
        let cpuItem = NSMenuItem(title: "CPU", action: #selector(toggleSysInfoMetric(_:)), keyEquivalent: "")
        cpuItem.target = self
        cpuItem.tag = 0
        // CPU 环形图条目（自定义 view：系统 / 用户 / 闲置 三段环形图，实时刷新）
        let cpuChartItem = NSMenuItem()
        let cpuChart = RingChartView(title: "CPU 占用", labels: ("系统", "用户", "闲置"), colors: (systemColor, userColor, idleColor))
        cpuChart.frame = NSRect(x: 0, y: 0, width: 252, height: 126)
        cpuChartView = cpuChart
        cpuChartItem.view = cpuChart
        cpuChartItem.isEnabled = false
        let memItem = NSMenuItem(title: "内存", action: #selector(toggleSysInfoMetric(_:)), keyEquivalent: "")
        memItem.target = self
        memItem.tag = 1
        // 内存环形图条目（已用 / 缓存 / 空闲 三段环形图，实时刷新）
        let memChartItem = NSMenuItem()
        let memChart = RingChartView(title: "内存占用", labels: ("已用", "空闲", ""), colors: (memUsedColor, memFreeColor, .clear), segmentCount: 2, totalSource: { a, _ in a })
        memChart.frame = NSRect(x: 0, y: 0, width: 252, height: 126)
        memChartView = memChart
        memChartItem.view = memChart
        memChartItem.isEnabled = false
        let diskItem = NSMenuItem(title: "磁盘", action: #selector(toggleSysInfoMetric(_:)), keyEquivalent: "")
        diskItem.target = self
        diskItem.tag = 2
        let netItem = NSMenuItem(title: "网络", action: #selector(toggleSysInfoMetric(_:)), keyEquivalent: "")
        netItem.target = self
        netItem.tag = 3
        subMenu.addItem(cpuItem)
        subMenu.addItem(cpuChartItem)
        subMenu.addItem(DashedSeparatorMenuItem())
        subMenu.addItem(memItem)
        subMenu.addItem(memChartItem)
        subMenu.addItem(DashedSeparatorMenuItem())
        subMenu.addItem(diskItem)
        subMenu.addItem(DashedSeparatorMenuItem())
        subMenu.addItem(netItem)
        sysInfoMenu = subMenu
        sysInfoItems = [cpuItem, memItem, diskItem, netItem]
        sysInfoItem.submenu = subMenu
        menu.addItem(sysInfoItem)

        // 一键清理内存
        let cleanItem = NSMenuItem(title: "一键清理内存", action: #selector(cleanMemory(_:)), keyEquivalent: "")
        cleanItem.target = self
        // 基础权限置灰，解锁后启用（解锁/清除权限时由 refreshMenuAccess 刷新）
        cleanItem.isEnabled = AccessControl.isFullAccess
        cleanMemoryItem = cleanItem
        menu.addItem(cleanItem)

        menu.addItem(NSMenuItem.separator())
        
        let toggleItem = NSMenuItem(title: "显示/隐藏小猫", action: #selector(toggleCat(_:)), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        let settingsItem = NSMenuItem(title: "设置", action: #selector(showSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
    }
    
    @MainActor @objc private func toggleCat(_ sender: Any?) {
        guard let window = floatingWindow else { return }
        if window.isVisible {
            window.hide()
        } else {
            window.show()
        }
    }

    @MainActor @objc private func showSettings(_ sender: Any?) {
        if settingsPanel == nil, let vm = viewModel {
            settingsPanel = SettingsPanel(viewModel: vm)
            // 解锁/清除权限后同步刷新菜单栏权限
            settingsPanel?.onAccessLevelChanged = { [weak self] in
                DispatchQueue.main.async {
                    self?.refreshMenuAccess()
                }
            }
        }
        settingsPanel?.showCentered()
    }

    /// 按权限刷新菜单栏可用性（解锁后启用一键清理内存等高级项）
    @MainActor private func refreshMenuAccess() {
        cleanMemoryItem?.isEnabled = AccessControl.isFullAccess
    }
    
    @MainActor @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
    
    private func startGlobalMouseTracking() {
        // 已移除"看向鼠标"朝向跟随功能（该功能导致小猫翻转后消失）
        // 保留方法签名以便将来恢复，当前不再启动 Timer 轮询
    }
    
    // MARK: - 菜单栏系统指标（CPU / 内存 / CPU 温度）
    
    @MainActor private func startMenuBarMonitoring() {
        menuBarTimer?.invalidate()
        menuBarTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshMenuBarMetrics()
        }
        refreshMenuBarMetrics()
    }
    
    /// 是否有任何系统信息指标被勾选（决定定时器是否采集）
    private var anyMetricEnabled: Bool {
        SystemMonitor.MenuPrefs.isOn(SystemMonitor.MenuPrefs.showCPU, default: false) ||
        SystemMonitor.MenuPrefs.isOn(SystemMonitor.MenuPrefs.showMemory, default: false) ||
        SystemMonitor.MenuPrefs.isOn(SystemMonitor.MenuPrefs.showDisk, default: false) ||
        SystemMonitor.MenuPrefs.isOn(SystemMonitor.MenuPrefs.showNet, default: false)
    }

    /// 按二级菜单勾选项采集指标并刷新菜单栏（SF Symbol 图标 + 数值，比纯文字省空间）
    private func refreshMenuBarMetrics() {
        // 无任何指标勾选时跳过采集，避免空转
        guard anyMetricEnabled else {
            DispatchQueue.main.async {
                self.statusItem?.button?.attributedTitle = NSAttributedString(string: "")
            }
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var parts: [(symbol: String, text: String)] = []

            if SystemMonitor.MenuPrefs.isOn(SystemMonitor.MenuPrefs.showCPU, default: false),
               let cpu = SystemMonitor.cpuUsage() {
                parts.append((symbol: "cpu", text: "\(Int(cpu.rounded()))%"))
            }
            if SystemMonitor.MenuPrefs.isOn(SystemMonitor.MenuPrefs.showMemory, default: false),
               let mem = SystemMonitor.memoryUsage() {
                parts.append((symbol: "memorychip", text: "\(Int(mem.percent.rounded()))%"))
            }
            if SystemMonitor.MenuPrefs.isOn(SystemMonitor.MenuPrefs.showDisk, default: false),
               let disk = SystemMonitor.diskUsage() {
                parts.append((symbol: "internaldrive", text: "\(Int(disk.percent.rounded()))%"))
            }
            if SystemMonitor.MenuPrefs.isOn(SystemMonitor.MenuPrefs.showNet, default: false),
               let net = SystemMonitor.networkRate() {
                parts.append((symbol: "arrow.up.arrow.down", text: "\(Int(net.downKBps.rounded()))K/\(Int(net.upKBps.rounded()))K"))
            }

            let attributed = Self.buildMetricTitle(parts)
            DispatchQueue.main.async {
                self?.statusItem?.button?.attributedTitle = attributed
            }
        }
    }

    /// 将「图标 + 数值」列表拼装为带 SF Symbol 的富文本
    /// （模板图片 + labelColor，图标随菜单栏深浅色自动适配）
    private static func buildMetricTitle(_ parts: [(symbol: String, text: String)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        for (i, part) in parts.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: " ")) }
            if let img = NSImage(systemSymbolName: part.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig) {
                img.isTemplate = true
                let att = NSTextAttachment()
                att.image = img
                att.bounds = NSRect(x: 0, y: -2, width: 14, height: 13)
                result.append(NSAttributedString(attachment: att))
            }
            result.append(NSAttributedString(string: part.text,
                                            attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        }
        result.addAttribute(.foregroundColor, value: NSColor.labelColor,
                            range: NSRange(location: 0, length: result.length))
        return result
    }
    
    /// 一键清理内存：后台执行内存回收，完成后弹窗展示效果
    @MainActor @objc private func cleanMemory(_ sender: Any?) {
        // 高级功能：基础权限需先在校验码解锁
        guard AccessControl.isFullAccess else {
            let alert = NSAlert()
            alert.messageText = "需要校验码"
            alert.informativeText = "「一键清理内存」属于高级功能，请在 设置 > 通用设置 > 权限 中输入校验码解锁"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MemoryCleaner.clean()
            DispatchQueue.main.async {
                guard let r = result else {
                    let alert = NSAlert()
                    alert.messageText = "内存清理失败"
                    alert.informativeText = "无法读取系统内存信息，请稍后重试"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "好")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                    return
                }
                let alert = NSAlert()
                alert.messageText = "内存清理完成"
                alert.informativeText = String(
                    format: "空闲内存：%.0f → %.0f MB\n压缩内存：%.0f → %.0f MB\n本次回收：%.0f MB",
                    r.beforeFree, r.afterFree, r.beforeCompressed, r.afterCompressed, r.freedMB
                )
                alert.alertStyle = .informational
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @MainActor private func showPermissionBanner() {
        // 非阻塞式权限提示：在控制台输出，不弹窗阻止用户使用
        NSLog("[DesktopPetForMacApp] 辅助功能权限未授权，鼠标跟随功能不可用。如需开启，请前往「系统设置 > 隐私与安全性 > 辅助功能」中启用 DesktopPetForMacApp。")
    }

    // MARK: - 系统信息二级菜单（CPU / 内存 / 磁盘 / 网络 实时监控）

    /// 每秒刷新一次二级菜单条目标题（菜单未打开时也保持数据新鲜，展开即见最新值）
    @MainActor private func startSysInfoMonitoring() {
        sysInfoTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshSysInfo()
        }
        // 关键：加入 .common mode。菜单展开期间 runloop 处于 .eventTracking mode，
        // 默认 .default mode 的 timer 会被暂停，导致菜单打开时数据不刷新
        RunLoop.main.add(timer, forMode: .common)
        sysInfoTimer = timer
        refreshSysInfo()
    }

    /// 点击二级菜单指标条目：切换顶栏是否显示该项，并刷新菜单勾选状态
    @MainActor @objc private func toggleSysInfoMetric(_ sender: NSMenuItem) {
        let key: String
        switch sender.tag {
        case 0: key = SystemMonitor.MenuPrefs.showCPU
        case 1: key = SystemMonitor.MenuPrefs.showMemory
        case 2: key = SystemMonitor.MenuPrefs.showDisk
        default: key = SystemMonitor.MenuPrefs.showNet
        }
        let current = SystemMonitor.MenuPrefs.isOn(key, default: false)
        UserDefaults.standard.set(!current, forKey: key)
        refreshSysInfo()      // 刷新菜单勾选与数值
        refreshMenuBarMetrics() // 刷新顶栏文字
    }

    private func refreshSysInfo() {
        // CPU / 内存环形图始终刷新（菜单展示，不依赖任何勾选），每秒更新三段数据
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cpuBd = SystemMonitor.cpuBreakdown()
            let memBd = SystemMonitor.memoryBreakdown()
            DispatchQueue.main.async {
                if let chart = self?.cpuChartView, let bd = cpuBd {
                    chart.setBreakdown(a: bd.system, b: bd.user, c: bd.idle)
                }
                if let chart = self?.memChartView, let bd = memBd {
                    chart.setBreakdown(a: bd.used, b: bd.free, c: 0)
                }
            }
        }
        // 无任何指标勾选时跳过文本采集
        guard anyMetricEnabled else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var cpuText = "CPU"
            var memText = "内存"
            var diskText = "磁盘"
            var netText = "网络"

            if let bd = SystemMonitor.cpuBreakdown() {
                // 标题只留名称，百分比数据由下方环形图（中心+图例）展示，避免冗余
                cpuText = "CPU"
            }
            if let mem = SystemMonitor.memoryUsage() {
                memText = "内存"
            }
            if let disk = SystemMonitor.diskUsage() {
                diskText = String(format: "磁盘  %.0f%%（已用 %.1fGB / 共 %.1fGB）", disk.percent, disk.usedGB, disk.totalGB)
            }
            if let net = SystemMonitor.networkRate() {
                netText = String(format: "网络  ↓ %.0fKB/s  ↑ %.0fKB/s", net.downKBps, net.upKBps)
            }

            let texts = [cpuText, memText, diskText, netText]
            let keys = [
                SystemMonitor.MenuPrefs.showCPU,
                SystemMonitor.MenuPrefs.showMemory,
                SystemMonitor.MenuPrefs.showDisk,
                SystemMonitor.MenuPrefs.showNet
            ]
            let states = keys.map { SystemMonitor.MenuPrefs.isOn($0, default: false) }

            DispatchQueue.main.async {
                guard let menuItems = self?.sysInfoItems, menuItems.count == texts.count else { return }
                for (i, item) in menuItems.enumerated() {
                    item.title = texts[i]
                    item.state = states[i] ? .on : .off
                }
            }
        }
    }
    
}

// MARK: - 虚线分隔菜单项（NSMenuItem 自定义 view，画一条水平虚线）

final class DashedSeparatorMenuItem: NSMenuItem {
    init() {
        super.init(title: "", action: nil, keyEquivalent: "")
        let view = DashedSeparatorView(frame: NSRect(x: 0, y: 0, width: 220, height: 12))
        view.autoresizingMask = [.width]
        self.view = view
        self.isEnabled = false
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class DashedSeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let line = NSBezierPath()
        let y = bounds.midY.rounded()
        line.move(to: NSPoint(x: bounds.minX + 8, y: y))
        line.line(to: NSPoint(x: bounds.maxX - 8, y: y))
        line.lineWidth = 1.0
        line.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.systemTeal.withAlphaComponent(0.6).setStroke()
        line.stroke()
    }
}

// MARK: - 环形图菜单项视图（三段数据：系统 / 用户之类的组合）

/// 右侧菜单「系统信息 > CPU / 内存」下方的环形图条目：两/三段彩色环形 + 中心占用 + 右侧图例
/// 通用实现：段数（2 或 3）、每段数值/颜色/图例标签均由调用方指定
final class RingChartView: NSView {
    // 各段当前值（0-100）
    private var values: (a: Double, b: Double, c: Double) = (a: 0, b: 0, c: 100)
    private let segmentCount: Int  // 2（已用/空闲）或 3（系统/用户/闲置）
    private let title: String
    private let colors: (a: NSColor, b: NSColor, c: NSColor)
    private let labels: (a: String, b: String, c: String)

    /// 中心占用口径：对 CPU 为「用户+系统」，对内存为「已用」（即第 0 段）
    private let totalSource: (Double, Double) -> Double

    init(title: String,
         labels: (a: String, b: String, c: String),
         colors: (a: NSColor, b: NSColor, c: NSColor),
         segmentCount: Int = 3,
         totalSource: @escaping (Double, Double) -> Double = { $0 + $1 }) {
        self.segmentCount = max(2, min(3, segmentCount))
        self.title = title
        self.labels = labels
        self.colors = colors
        self.totalSource = totalSource
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 更新三段数值（0-100）并重绘
    func setBreakdown(a: Double, b: Double, c: Double) {
        values = (a, b, c)
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 252, height: 126) }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // ── 环形图 ──
        let ringCenter = NSPoint(x: 46, y: bounds.midY)
        let radius: CGFloat = 32
        let lineWidth: CGFloat = 9

        // 底部浅灰背景环（白灰底上做浅灰兜底环，增加立体感）
        let bgPath = NSBezierPath()
        bgPath.appendArc(withCenter: ringCenter, radius: radius, startAngle: 0, endAngle: 360, clockwise: true)
        bgPath.lineWidth = lineWidth
        NSColor(white: 0, alpha: 0.10).setStroke()
        bgPath.stroke()

        var segmentData: [(value: Double, color: NSColor)] = [
            (values.a, colors.a),
            (values.b, colors.b),
            (values.c, colors.c)
        ]
        if segmentCount < 3 { segmentData.removeLast() }
        // 各段弧无间隙铺满 360°（平头端帽），任何时刻都是完整整圆、各段合计正好 100%
        var startAngle = 90.0
        for seg in segmentData {
            let angle = seg.value / 100.0 * 360.0
            guard angle > 0.1 else { continue }
            let path = NSBezierPath()
            path.appendArc(withCenter: ringCenter, radius: radius, startAngle: startAngle, endAngle: startAngle - angle, clockwise: true)
            path.lineWidth = lineWidth
            path.lineCapStyle = .butt  // 平头：交接处平整不圆滑
            seg.color.setStroke()
            path.stroke()
            startAngle -= angle
        }

        // 中心文字：总占用率（整数小号黑字，不遮挡环形图）
        let aR = Int((values.a + 0.5).rounded())
        let bR = Int((values.b + 0.5).rounded())
        let cR = segmentCount > 2 ? max(0, 100 - aR - bR) : 0  // 三段时第三段补齐，保证合计正好 100%
        let total = Int(totalSource(Double(aR), Double(bR)).rounded())
        // 中心仅显示总占用率（整数黑字，垂直居中，去掉冗余小标题）
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let pctStr = "\(total)%" as NSString
        let pctSize = pctStr.size(withAttributes: pctAttrs)
        pctStr.draw(at: NSPoint(x: ringCenter.x - pctSize.width / 2, y: ringCenter.y - pctSize.height / 2 + 1), withAttributes: pctAttrs)

        // ── 右侧图例（整数显示，第三段 = 100 - 前两段，合计正好 100%）──
        let legendX: CGFloat = 92
        var legendRows: [(label: String, value: Int, color: NSColor)] = [
            (labels.a, aR, colors.a),
            (labels.b, bR, colors.b),
            (labels.c, cR, colors.c)
        ]
        if segmentCount < 3 { legendRows.removeLast() }
        let rowH: CGFloat = 31
        let firstY = bounds.height - 26
        for (i, row) in legendRows.enumerated() {
            let y = firstY - CGFloat(i) * rowH
            // 色点
            let dot = NSBezierPath(ovalIn: NSRect(x: legendX, y: y - 3, width: 10, height: 10))
            row.color.setFill()
            dot.fill()
            // 文本（黑色，浅色底上清晰）
            let text = "\(row.label)   \(row.value)%" as NSString
            text.draw(at: NSPoint(x: legendX + 17, y: y - 6), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(white: 0.15, alpha: 1.0)
            ])
        }
    }
}
