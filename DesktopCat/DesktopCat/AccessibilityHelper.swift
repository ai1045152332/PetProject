// AccessibilityHelper.swift

import Foundation
import AppKit
import ApplicationServices

enum AccessibilityHelper {
    
    /// 检测当前应用是否拥有辅助功能权限
    static func checkPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    /// 异步检测权限（不阻塞主线程）
    static func checkPermissionAsync(completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = checkPermission()
            completion(granted)
        }
    }
    
}
