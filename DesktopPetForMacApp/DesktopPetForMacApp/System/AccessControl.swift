// AccessControl.swift
// DesktopPetForMacApp — 权限控制系统
// 基础权限：只能使用简单功能（小猫显示、系统信息、状态切换、提醒等）
// 输入校验码后解锁全部功能（一键清理内存、小猫大小调整等高级能力）
// 校验规则：本地校验码 456 直接通过；否则请求后端接口校验（远程校验码由服务端维护）

import Foundation

enum AccessControl {

    /// 本地校验码（写死）
    static let fullCode = "456"

    private static let prefsKey = "settings.accessLevel"
    private static let fullLevel = "full"

    /// 当前是否已解锁全部功能
    static var isFullAccess: Bool {
        UserDefaults.standard.string(forKey: prefsKey) == fullLevel
    }

    /// 输入校验码解锁
    /// 先比对本地校验码，不匹配再请求后端接口校验；
    /// 校验通过则持久化为「全部功能」
    /// - Parameter completion: 在主线程回调，参数为是否解锁成功
    static func unlock(with code: String, completion: @escaping (Bool) -> Void) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(false)
            return
        }
        // 本地校验码直接通过
        if trimmed == fullCode {
            persistFullAccess()
            completion(true)
            return
        }
        // 否则走后端接口校验
        verifyRemote(code: trimmed) { valid in
            if valid { persistFullAccess() }
            completion(valid)
        }
    }

    /// 清除现有权限，回到基础权限（高级功能锁定）
    static func clearAccess() {
        UserDefaults.standard.removeObject(forKey: prefsKey)
    }

    // MARK: - 私有

    private static func persistFullAccess() {
        UserDefaults.standard.set(fullLevel, forKey: prefsKey)
    }

    /// 请求后端接口校验校验码（网络失败按校验失败处理，回调统一回到主线程）
    private static func verifyRemote(code: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: ServerConfig.baseURL + "/api/access/verify") else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])

        URLSession.shared.dataTask(with: request) { data, _, error in
            var valid = false
            if let error {
                FileLogger.log("[Access] 校验码远程验证请求失败: \(error.localizedDescription)")
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataDict = json["data"] as? [String: Any],
                      let v = dataDict["valid"] as? Bool {
                valid = v
            } else {
                FileLogger.log("[Access] 校验码远程验证响应解析失败: \(String(data: data ?? Data(), encoding: .utf8) ?? "nil")")
            }
            DispatchQueue.main.async { completion(valid) }
        }.resume()
    }
}
