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
    /// 启动密码验证管理器
    private var authManager: AuthManager?
    
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

        // 启动密码验证：验证通过后才显示小猫
        let auth = AuthManager()
        self.authManager = auth
        auth.showAuthWindow { [weak self] in
            DispatchQueue.main.async {
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

        // ── 最上面：系统信息（二级菜单，悬停/点击展开，实时监控）──
        // 二级菜单的每个指标条目都可点击勾选：勾选后显示在顶部菜单栏
        let sysInfoItem = NSMenuItem(title: "系统信息", action: nil, keyEquivalent: "")
        let subMenu = NSMenu()
        let cpuItem = NSMenuItem(title: "CPU", action: #selector(toggleSysInfoMetric(_:)), keyEquivalent: "")
        cpuItem.target = self
        cpuItem.tag = 0
        let memItem = NSMenuItem(title: "内存", action: #selector(toggleSysInfoMetric(_:)), keyEquivalent: "")
        memItem.target = self
        memItem.tag = 1
        let diskItem = NSMenuItem(title: "磁盘", action: #selector(toggleSysInfoMetric(_:)), keyEquivalent: "")
        diskItem.target = self
        diskItem.tag = 2
        let netItem = NSMenuItem(title: "网络", action: #selector(toggleSysInfoMetric(_:)), keyEquivalent: "")
        netItem.target = self
        netItem.tag = 3
        subMenu.addItem(cpuItem)
        subMenu.addItem(DashedSeparatorMenuItem())
        subMenu.addItem(memItem)
        subMenu.addItem(DashedSeparatorMenuItem())
        subMenu.addItem(diskItem)
        subMenu.addItem(DashedSeparatorMenuItem())
        subMenu.addItem(netItem)
        sysInfoMenu = subMenu
        sysInfoItems = [cpuItem, memItem, diskItem, netItem]
        sysInfoItem.submenu = subMenu
        menu.addItem(sysInfoItem)

        // 一键清理内存（测试版）
        let cleanItem = NSMenuItem(title: "一键清理内存（测试版）", action: #selector(cleanMemory(_:)), keyEquivalent: "")
        cleanItem.target = self
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
        }
        settingsPanel?.showCentered()
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
    
    /// 一键清理内存（测试版）：后台执行内存回收，完成后弹窗展示效果
    @MainActor @objc private func cleanMemory(_ sender: Any?) {
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
                alert.messageText = "内存清理完成（测试版）"
                alert.informativeText = String(format: "清理前空闲：%.0f MB\n清理后空闲：%.0f MB\n本次回收：%.0f MB", r.before, r.after, r.freed)
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
        // 无任何指标勾选时跳过采集
        guard anyMetricEnabled else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var cpuText = "CPU"
            var memText = "内存"
            var diskText = "磁盘"
            var netText = "网络"

            if let cpu = SystemMonitor.cpuUsage() {
                cpuText = String(format: "CPU  %.0f%%", cpu)
            }
            if let mem = SystemMonitor.memoryUsage() {
                memText = String(format: "内存  %.0f%%（已用 %.1fGB / 共 %.1fGB）", mem.percent, mem.usedGB, mem.totalGB)
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
