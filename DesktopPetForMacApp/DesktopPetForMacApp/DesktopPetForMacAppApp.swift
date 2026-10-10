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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }
    
    private func startGlobalMouseTracking() {
        // 使用 60ms 轮询获取鼠标位置，性能友好
        Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let mouseLocation = NSEvent.mouseLocation
            self.viewModel?.updateMousePosition(mouseLocation)
        }
    }
    
    @MainActor private func showPermissionBanner() {
        // 非阻塞式权限提示：在控制台输出，不弹窗阻止用户使用
        NSLog("[DesktopPetForMacApp] 辅助功能权限未授权，鼠标跟随功能不可用。如需开启，请前往「系统设置 > 隐私与安全性 > 辅助功能」中启用 DesktopPetForMacApp。")
    }
    
}
