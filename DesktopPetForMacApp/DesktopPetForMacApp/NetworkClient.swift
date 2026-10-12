// NetworkClient.swift
// DesktopPetForMacApp — 统一网络请求层（替换 runCurl）

import Foundation

struct NetworkClient {
    /// 同步阻塞获取网络数据（内部使用 URLSession + Semaphore 桥接）
    /// - Parameters:
    ///   - urlString: 请求 URL
    ///   - timeout: 超时秒数
    ///   - userAgent: 自定义 User-Agent，nil 则使用默认
    /// - Returns: 原始响应数据
    static func fetchData(_ urlString: String, timeout: TimeInterval = 5, userAgent: String? = nil) -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url, timeoutInterval: timeout + 2)
        if let ua = userAgent {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("[DesktopPetForMacApp] 网络请求失败: %@", error.localizedDescription)
            }
            result = data
            semaphore.signal()
        }
        task.resume()
        
        let waitResult = semaphore.wait(timeout: .now() + timeout + 2)
        if waitResult == .timedOut {
            task.cancel()
            NSLog("[DesktopPetForMacApp] 网络请求超时: %@", urlString)
        }
        
        return result
    }
}
