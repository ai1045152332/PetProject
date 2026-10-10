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
        
        // 5. 创建顶部菜单栏图标
        setupStatusBar()
    }
    
    // MARK: - 菜单栏
    @MainActor private func setupStatusBar() {
        let statusBar = NSStatusBar.system
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item
        
        let btn = item.button!
        
        // 创建一个更明显的猫咪图标（大尺寸 + 高对比度）
        let img = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            // 背景圆形（亮橙色）
            let bg = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.0, alpha: 1.0).setFill()
            bg.fill()
            
            // 左耳
            let leftEar = NSBezierPath()
            leftEar.move(to: NSPoint(x: 5, y: 19))
            leftEar.line(to: NSPoint(x: 9, y: 12))
            leftEar.line(to: NSPoint(x: 2, y: 12))
            leftEar.close()
            NSColor.white.setFill()
            leftEar.fill()
            
            // 右耳
            let rightEar = NSBezierPath()
            rightEar.move(to: NSPoint(x: 17, y: 19))
            rightEar.line(to: NSPoint(x: 13, y: 12))
            rightEar.line(to: NSPoint(x: 20, y: 12))
            rightEar.close()
            rightEar.fill()
            
            // 左眼
            let leftEye = NSBezierPath(ovalIn: NSRect(x: 6, y: 8, width: 3, height: 4))
            NSColor.black.setFill()
            leftEye.fill()
            
            // 右眼
            let rightEye = NSBezierPath(ovalIn: NSRect(x: 13, y: 8, width: 3, height: 4))
            rightEye.fill()
            
            // 鼻子/嘴
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: 11, y: 6))
            mouth.line(to: NSPoint(x: 9, y: 4))
            mouth.move(to: NSPoint(x: 11, y: 6))
            mouth.line(to: NSPoint(x: 13, y: 4))
            NSColor(calibratedRed: 0.8, green: 0.3, blue: 0.0, alpha: 1.0).setStroke()
            mouth.lineWidth = 1
            mouth.stroke()
            
            return true
        }
        
        btn.image = img
        
        // 创建菜单
        let menu = NSMenu()
        
        let toggleItem = NSMenuItem(title: "显示/隐藏小猫", action: #selector(toggleCat(_:)), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
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
    
    @MainActor @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
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
