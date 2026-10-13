// AccessControl.swift
// DesktopPetForMacApp — 权限控制系统
// 基础权限：只能使用简单功能（小猫显示、系统信息、状态切换、提醒等）
// 输入校验码后解锁全部功能（一键清理内存、小猫大小调整等高级能力）
// 校验码当前写死为 456，后续改为接口校验

import Foundation

enum AccessControl {

    /// 校验码（写死，TODO: 后续改为接口校验）
    static let fullCode = "456"

    private static let prefsKey = "settings.accessLevel"
    private static let fullLevel = "full"

    /// 当前是否已解锁全部功能
    static var isFullAccess: Bool {
        UserDefaults.standard.string(forKey: prefsKey) == fullLevel
    }

    /// 输入校验码解锁
    /// - 校验通过返回 true 并持久化为「全部功能」；校验失败返回 false
    static func unlock(with code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // TODO: 校验码后续改为接口校验（替换此处本地比较）
        guard trimmed == fullCode else { return false }
        UserDefaults.standard.set(fullLevel, forKey: prefsKey)
        return true
    }

    /// 清除现有权限，回到基础权限（高级功能锁定）
    static func clearAccess() {
        UserDefaults.standard.removeObject(forKey: prefsKey)
    }
}
