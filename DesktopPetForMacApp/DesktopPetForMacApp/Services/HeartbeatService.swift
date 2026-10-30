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
    /// 上一次已记录的失败原因：心跳每 60s 一次，网络持续不通时同一原因只记一条，避免日志被刷满
    private var lastLoggedFailure = ""

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
            // 心跳成功路径不再写日志（每 60s 一条，量级过大），只保留「有变化」的异常信号
            let failure: String?
            if let error = error {
                failure = "上报失败: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                failure = nil
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                failure = "上报异常，状态码: \(code)"
            }

            if let failure {
                Task { @MainActor in HeartbeatService.shared.recordFailure(failure) }
                return
            }

            Task { @MainActor in
                // 恢复成功后清空记录，下次再断开会重新记一条
                HeartbeatService.shared.lastLoggedFailure = ""
                // 心跳响应顺带回传宠物号、待展示好友消息与待处理好友申请
                if let data { HeartbeatService.consume(data) }
            }
        }.resume()
    }

    /// 同一失败原因连续出现时只记首条、原因变化时再记新的一条（断网时不会被 60s 一条刷满日志）
    private func recordFailure(_ message: String) {
        guard message != lastLoggedFailure else { return }
        lastLoggedFailure = message
        FileLogger.log("[Heartbeat] \(message)")
    }

    /// 解析心跳响应：缓存宠物号，并把好友消息用常驻卡片展示、好友申请用申请卡询问（于 MainActor 上调用）
    @MainActor private static func consume(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any] else { return }

        // 宠物号：写入本地缓存（供设置面板展示），变化时广播通知
        if let petNo = intValue(payload["petNo"]), petNo > 0 {
            FriendService.setMyPetNo(petNo)
        }

        // 待处理好友申请：服务端在用户同意/拒绝前会持续下发，靠本地「已弹过 ID」去重只弹一次
        if let rawRequests = payload["requests"] as? [[String: Any]] {
            let requests = rawRequests.compactMap { dict -> PetFriendRequest? in
                guard let petNo = intValue(dict["fromPetNo"]), petNo > 0 else { return nil }
                let id = dict["id"] as? String ?? ""
                guard !id.isEmpty else { return nil }
                return PetFriendRequest(id: id, fromPetNo: petNo, fromName: dict["fromName"] as? String ?? "")
            }
            for req in FriendService.markRequestsShown(requests) {
                FileLogger.log("[Heartbeat] 收到好友申请: #\(req.fromPetNo) \(req.fromName)")
                HeartbeatService.shared.viewModel?.onFriendRequest?(req)
            }
        }

        // 待展示消息：服务端已按发送时间升序返回，整批交给会话窗展示（可回看记录、直接回复）
        guard let messages = payload["messages"] as? [[String: Any]], !messages.isEmpty else { return }
        let incoming = messages.compactMap { dict -> PetChatMessage? in
            let fromPetNo = intValue(dict["fromPetNo"]) ?? 0
            let text = (dict["text"] as? String) ?? ""
            guard fromPetNo > 0, !text.isEmpty else { return nil }
            // 心跳载荷不带发送时间（留痕在服务端才有），聊天窗拉到历史后会自动补上时刻
            return PetChatMessage(
                id: dict["id"] as? String ?? "",
                fromPetNo: fromPetNo,
                fromName: dict["fromName"] as? String ?? "",
                text: text,
                sentAt: nil,
                isRead: false
            )
        }
        guard !incoming.isEmpty else { return }
        // 待确认已读的消息 ID 由会话窗按展示的那一批自行收集（关卡时才上报）
        FileLogger.log("[Heartbeat] 收到好友消息 \(incoming.count) 条")
        // 不再用会自动淡出的气泡，也不再把几位好友的留言挤在同一张卡上：
        // 改开常驻会话窗，展示最近一位的往来记录并支持回复
        HeartbeatService.shared.viewModel?.onFriendMessage?(incoming)
    }

    /// JSON 数字统一取 Int
    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
