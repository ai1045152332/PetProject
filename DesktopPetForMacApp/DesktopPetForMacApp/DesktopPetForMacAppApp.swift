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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化文件日志
        FileLogger.setup()

        // 直接启动小猫，不阻塞在权限检测上
        // 辅助功能权限只影响"看向鼠标"效果，不影响基本显示
        setupCat()
        
        // 后台检测权限，未授权时静默提示
        AccessibilityHelper.checkPermissionAsync { [weak self] granted in
            DispatchQueue.main.async {
                if !granted {
                    // 可选：显示一个低调的权限提示
                    self?.showPermissionBanner()
                }
            }
        }
    }
    
    @MainActor private func setupCat() {
        // 2. 创建状态机
        let vm = PetViewModel()
        self.viewModel = vm
        
        // 3. 创建浮动窗口
        let window = FloatingWindow(viewModel: vm)
        self.floatingWindow = window
        window.show()
        
        // 4. 启动全局鼠标位置监听（用于"看向鼠标"效果）
        startGlobalMouseTracking()
        
        // 5. 创建顶部菜单栏图标
        setupStatusBar()
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
    
    @MainActor private func showPermissionBanner() {
        // 非阻塞式权限提示：在控制台输出，不弹窗阻止用户使用
        NSLog("[DesktopPetForMacApp] 辅助功能权限未授权，鼠标跟随功能不可用。如需开启，请前往「系统设置 > 隐私与安全性 > 辅助功能」中启用 DesktopPetForMacApp。")
    }
    
}
