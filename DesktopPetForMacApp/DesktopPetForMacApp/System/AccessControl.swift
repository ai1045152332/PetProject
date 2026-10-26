// AccessControl.swift
// DesktopPetForMacApp — 权限控制系统
// 基础权限：只能使用简单功能（小猫显示、系统信息、状态切换、提醒等）
// 输入校验码后解锁全部功能（一键清理内存、宠物大小调整等高级能力）
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
        case expired        // 激活码已过期
        case deviceLimit    // 该码绑定设备数已达上限
        case networkError   // 网络/服务异常
        case localError     // 本地加密或请求构造失败（非网络问题）
        case badFormat      // 输入格式不是激活码（如误粘了其它文本）
        case serverError    // 服务端返回异常
    }

    private static let prefsKey = "settings.accessLevel"
    private static let fullLevel = "full"
    /// 解锁时使用的校验码（用于后续定时复核；本地后门码不记录）
    private static let codeKey = "settings.accessCode"

    /// 权限变化通知（供设置面板等界面刷新）
    static let accessLevelChanged = Notification.Name("AccessControl.accessLevelChanged")

    /// 当前是否已解锁全部功能
    static var isFullAccess: Bool {
        UserDefaults.standard.string(forKey: prefsKey) == fullLevel
    }

    static var serverActivationCode: String? {
        guard isFullAccess, let code = UserDefaults.standard.string(forKey: codeKey), code != fullCode else { return nil }
        return normalizedCode(code)
    }

    /// 定时复核结果
    enum RevalidateResult {
        case ok         // 复核通过
        case skipped    // 无需复核（未解锁 / 本地后门码 / 网络异常，均不影响现有权限）
        case revoked    // 服务端判定失效，权限已收回
    }

    /// 定时复核授权（与版本检查同一节奏调用）：
    /// 用解锁时记录的校验码请求服务端，仅当服务端**明确判定无效**（失效/过期/超设备数）才收回权限；
    /// 网络异常一律保留权限，避免误伤离线用户。
    static func revalidate(completion: @escaping (RevalidateResult) -> Void) {
        guard isFullAccess else {
            completion(.skipped)
            return
        }
        guard let code = UserDefaults.standard.string(forKey: codeKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            // 旧版本解锁未记录校验码：不处理
            completion(.skipped)
            return
        }
        // 本地后门码不参与远程复核
        if code == fullCode {
            completion(.skipped)
            return
        }

        verifyRemote(code: code) { result in
            switch result {
            case .success:
                completion(.ok)
            case .invalidCode, .expired, .deviceLimit:
                FileLogger.log("[AccessControl] 定时复核未通过，收回权限: \(result)")
                clearAccess()
                completion(.revoked)
            default:
                // 网络/服务异常等：保留现有权限
                completion(.skipped)
            }
        }
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
        // 本地校验码直接通过（不记录，避免参与远程复核）
        if trimmed == fullCode {
            persistFullAccess(code: nil)
            completion(.success)
            return
        }
        // 格式预检：激活码为 12 位字母数字（可含横线/空格），避免误粘其它文本时只报「校验码错误」
        if !isPlausibleActivationCode(trimmed) {
            FileLogger.log("[Access] 输入格式不像激活码，已阻止请求")
            completion(.badFormat)
            return
        }
        // 否则走后端接口校验（激活码 + 设备绑定）
        verifyRemote(code: trimmed) { result in
            if result == .success { persistFullAccess(code: trimmed) }
            completion(result)
        }
    }

    /// 清除现有权限，回到基础权限（高级功能锁定）
    static func clearAccess() {
        UserDefaults.standard.removeObject(forKey: prefsKey)
        UserDefaults.standard.removeObject(forKey: codeKey)
        notifyAccessLevelChanged()
    }

    // MARK: - 私有

    /// 归一化：大写、去掉非字母数字（与后端 normalizeCode 对齐）
    static func normalizedCode(_ code: String) -> String {
        let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let filtered = upper.unicodeScalars.filter { scalar in
            (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 48 && scalar.value <= 57)
        }
        return String(String.UnicodeScalarView(filtered))
    }

    /// 格式预检：归一化后应为 12 位（激活码 XXXX-XXXX-XXXX）
    private static func isPlausibleActivationCode(_ code: String) -> Bool {
        normalizedCode(code).count == 12
    }

    private static func persistFullAccess(code: String?) {
        UserDefaults.standard.set(fullLevel, forKey: prefsKey)
        if let code {
            UserDefaults.standard.set(code, forKey: codeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: codeKey)
        }
        notifyAccessLevelChanged()
    }

    private static func notifyAccessLevelChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: accessLevelChanged, object: nil)
        }
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
        // 激活码与设备 ID 用服务端公钥加密后传输，不发明文
        let plain = try? JSONSerialization.data(withJSONObject: [
            "code": normalizedCode(code),
            "deviceId": deviceID
        ])
        guard let plain, let body = PayloadCrypto.encryptedEnvelope(plain) else {
            FileLogger.log("[Access] 激活码加密失败，取消本次校验")
            DispatchQueue.main.async { completion(.localError) }
            return
        }
        request.httpBody = body

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
                    switch dataDict["reason"] as? String {
                    case "device_limit": result = .deviceLimit
                    case "expired":      result = .expired
                    default:             result = .invalidCode
                    }
                }
            } else {
                FileLogger.log("[Access] 校验码远程验证响应解析失败: \(String(data: data ?? Data(), encoding: .utf8) ?? "nil")")
                result = .serverError
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
