// AccessControl.swift
// DesktopPetForMacApp — 权限控制系统
// 基础权限：只能使用简单功能（小猫显示、系统信息、状态切换、提醒等）
// 输入校验码后解锁全部功能（一键清理内存、小猫大小调整等高级能力）
// 校验规则：本地校验码 456 直接通过；否则请求后端接口校验（远程校验码由服务端维护）

import Foundation
import IOKit

enum AccessControl {

    /// 本地校验码（写死）
    static let fullCode = "456"

    /// 设备唯一标识（IOPlatformUUID，重装系统/换机才会变）
    static let deviceID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return uuid ?? "unknown-device"
    }()

    /// 解锁结果（供 UI 区分失败原因）
    enum UnlockResult {
        case success        // 解锁成功
        case invalidCode    // 校验码错误
        case deviceLimit    // 该码绑定设备数已达上限
        case networkError   // 网络/服务异常
    }

    private static let prefsKey = "settings.accessLevel"
    private static let fullLevel = "full"
    /// 权限通过时的 App 版本号（用于新版本安装后清除旧权限）
    private static let grantedVersionKey = "settings.accessGrantedVersion"

    /// 当前是否已解锁全部功能
    static var isFullAccess: Bool {
        UserDefaults.standard.string(forKey: prefsKey) == fullLevel
    }

    /// 启动时调用：版本号变化（新安装/升级）则清除旧版本通过的校验权限
    static func resetIfVersionChanged() {
        let grantedVersion = UserDefaults.standard.string(forKey: grantedVersionKey)
        guard grantedVersion != AppVersion.current else { return }
        if isFullAccess {
            FileLogger.log("[AccessControl] 检测到新版本 \(AppVersion.current)（旧权限版本 \(grantedVersion ?? "无")），清除旧权限")
            clearAccess()
        }
        UserDefaults.standard.set(AppVersion.current, forKey: grantedVersionKey)
    }

    /// 输入校验码解锁
    /// 先比对本地校验码，不匹配再请求后端接口校验；
    /// 校验通过则持久化为「全部功能」
    /// - Parameter completion: 在主线程回调解锁结果
    static func unlock(with code: String, completion: @escaping (UnlockResult) -> Void) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.invalidCode)
            return
        }
        // 本地校验码直接通过
        if trimmed == fullCode {
            persistFullAccess()
            completion(.success)
            return
        }
        // 否则走后端接口校验（激活码 + 设备绑定）
        verifyRemote(code: trimmed) { result in
            if result == .success { persistFullAccess() }
            completion(result)
        }
    }

    /// 清除现有权限，回到基础权限（高级功能锁定）
    static func clearAccess() {
        UserDefaults.standard.removeObject(forKey: prefsKey)
    }

    // MARK: - 私有

    private static func persistFullAccess() {
        UserDefaults.standard.set(fullLevel, forKey: prefsKey)
        UserDefaults.standard.set(AppVersion.current, forKey: grantedVersionKey)
    }

    /// 请求后端接口校验激活码（回调统一回到主线程）
    private static func verifyRemote(code: String, completion: @escaping (UnlockResult) -> Void) {
        guard let url = URL(string: ServerConfig.baseURL + "/api/access/verify") else {
            DispatchQueue.main.async { completion(.networkError) }
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": code.uppercased(),
            "deviceId": deviceID
        ])

        URLSession.shared.dataTask(with: request) { data, _, error in
            var result = UnlockResult.networkError
            if let error {
                FileLogger.log("[Access] 校验码远程验证请求失败: \(error.localizedDescription)")
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataDict = json["data"] as? [String: Any],
                      let valid = dataDict["valid"] as? Bool {
                if valid {
                    result = .success
                } else {
                    result = (dataDict["reason"] as? String) == "device_limit" ? .deviceLimit : .invalidCode
                }
            } else {
                FileLogger.log("[Access] 校验码远程验证响应解析失败: \(String(data: data ?? Data(), encoding: .utf8) ?? "nil")")
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
