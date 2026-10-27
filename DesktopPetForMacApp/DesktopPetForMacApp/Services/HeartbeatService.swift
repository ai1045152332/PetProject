// HeartbeatService.swift
// DesktopPetForMacApp — 心跳上报服务
// 每 1 分钟向 Go 后端上报一次本机简单信息与版本号

import Foundation

@MainActor
final class HeartbeatService {
    static let shared = HeartbeatService()

    /// 心跳接口地址
    private let heartbeatURL = ServerConfig.baseURL + "/api/heartbeat"

    /// 上报间隔：1 分钟
    private let interval: TimeInterval = 60

    private var timer: Timer?
    private var started = false
    /// 宠物状态机（弱引用，用于上报当前状态）
    private weak var viewModel: PetViewModel?

    private init() {}

    /// 绑定宠物状态机（在 start 前调用）
    func attach(viewModel: PetViewModel) {
        self.viewModel = viewModel
    }

    /// 启动心跳（启动时立即上报一次，之后每 1 分钟上报）
    func start() {
        guard !started else { return }
        started = true

        sendHeartbeat()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendHeartbeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        FileLogger.log("[Heartbeat] 心跳服务已启动，间隔 \(Int(interval))s → \(heartbeatURL)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        started = false
    }

    // MARK: - 私有

    /// 收集本机简单信息并组装上报体
    private func makePayload() -> [String: Any] {
        var sysInfo = utsname()
        uname(&sysInfo)
        let machine = withUnsafeBytes(of: &sysInfo.machine) { rawBuffer in
            String(bytes: rawBuffer.prefix { $0 != 0 }, encoding: .utf8) ?? "unknown"
        }

        return [
            "version": AppVersion.current,
            "hostname": ProcessInfo.processInfo.hostName,
            "os": "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "machine": machine,
            "petName": PetName.currentName(),
            "petState": viewModel?.animationState.rawValue ?? CatAnimationState.idel.rawValue,
            "deviceId": AccessControl.deviceID
        ]
    }

    private func sendHeartbeat() {
        guard let url = URL(string: heartbeatURL) else { return }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: makePayload())
        } catch {
            FileLogger.log("[Heartbeat] 序列化失败: \(error.localizedDescription)")
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                FileLogger.log("[Heartbeat] 上报失败: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                FileLogger.log("[Heartbeat] 上报成功")
                // 心跳响应顺带回传宠物号与待展示好友消息（后端取后即清）
                if let data {
                    Task { @MainActor in HeartbeatService.consume(data) }
                }
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                FileLogger.log("[Heartbeat] 上报异常，状态码: \(code)")
            }
        }.resume()
    }

    /// 解析心跳响应：缓存宠物号，并把好友消息用宠物头顶气泡展示（于 MainActor 上调用）
    @MainActor private static func consume(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any] else { return }

        // 宠物号：写入本地缓存（供设置面板展示），变化时广播通知
        if let petNo = intValue(payload["petNo"]), petNo > 0 {
            FriendService.setMyPetNo(petNo)
        }

        // 待展示消息：合并为一条气泡（多条时前缀条数，展示最新一条正文）
        guard let messages = payload["messages"] as? [[String: Any]], !messages.isEmpty else { return }
        let latest = messages.last ?? [:]
        let fromName = latest["fromName"] as? String ?? ""
        let fromPetNo = intValue(latest["fromPetNo"]) ?? 0
        let text = latest["text"] as? String ?? ""
        var bubble = "\(fromName.isEmpty ? "好友" : fromName)(#\(fromPetNo))：\(text)"
        if messages.count > 1 { bubble = "收到 \(messages.count) 条好友消息｜" + bubble }
        FileLogger.log("[Heartbeat] 收到好友消息 \(messages.count) 条")
        HeartbeatService.shared.viewModel?.onPetSay?(bubble)
    }

    /// JSON 数字统一取 Int
    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
