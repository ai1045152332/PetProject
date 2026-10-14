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
            "petState": viewModel?.animationState.rawValue ?? CatAnimationState.idel.rawValue
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

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                FileLogger.log("[Heartbeat] 上报失败: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                FileLogger.log("[Heartbeat] 上报成功")
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                FileLogger.log("[Heartbeat] 上报异常，状态码: \(code)")
            }
        }.resume()
    }
}
