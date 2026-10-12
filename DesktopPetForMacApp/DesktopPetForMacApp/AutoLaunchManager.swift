// AutoLaunchManager.swift
// DesktopPetForMacApp — 开机自启管理
// 使用 LaunchAgent 方案（写入 ~/Library/LaunchAgents + launchctl bootstrap），
// 不依赖 app 安装位置与签名，比 SMAppService 更稳定

import Foundation

enum AutoLaunchManager {
    static let prefsKey = "settings.autoLaunch"
    static let agentLabel = "com.desktoppetformacapp.autolaunch"

    /// 开机自启是否开启（默认 true）
    static func isEnabled() -> Bool {
        if let v = UserDefaults.standard.object(forKey: prefsKey) as? Bool { return v }
        return true
    }

    /// 应用启动时应用配置：开启则确保安装，关闭则卸载
    static func applyOnLaunch() {
        if isEnabled() {
            installIfNeeded()
        } else {
            uninstallIfPresent()
        }
    }

    /// 用户切换开关
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: prefsKey)
        if enabled {
            installIfNeeded()
        } else {
            uninstallIfPresent()
        }
    }

    private static func agentPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// 安装 LaunchAgent（已安装则跳过）
    static func installIfNeeded() {
        let url = agentPlistURL()
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        guard FileManager.default.fileExists(atPath: exe) else { return }
        if FileManager.default.fileExists(atPath: url.path) { return }

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null"
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch { return }

        launchctlBootstrap(url.path)
    }

    /// 卸载 LaunchAgent
    static func uninstallIfPresent() {
        let url = agentPlistURL()
        launchctlBootout(agentLabel)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - launchctl

    private static func launchctlBootstrap(_ plistPath: String) {
        let uid = String(getuid())
        // 先解除旧实例，再装载新的（忽略单步失败）
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
        run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
    }

    private static func launchctlBootout(_ label: String) {
        let uid = String(getuid())
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }
}
