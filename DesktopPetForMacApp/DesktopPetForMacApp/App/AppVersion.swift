// AppVersion.swift
// DesktopPetForMacApp — 应用版本号（本地维护，随发布手动更新）

import Foundation

enum AppVersion {
    /// 基础版本号（唯一版本源，随发布手动更新；设置面板 > 通用设置 中展示）
    static let current = "v1.0.031"

    /// 运行时版本号：打包版优先读 Bundle Info.plist（本地打包脚本会追加 test 标识），
    /// 未打包（swift run / 单元测试）回退 AppVersion.swift 常量。
    static let displayVersion: String = {
        if let plist = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !plist.isEmpty {
            return plist.hasPrefix("v") ? plist : "v\(plist)"
        }
        return current
    }()
}
