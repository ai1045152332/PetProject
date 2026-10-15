// FocusModeMonitor.swift
// DesktopPetForMacApp — 系统勿扰/专注模式监视器（单向跟随，只读检测）
// 原理：macOS 12+ 开启勿扰/专注模式时，系统会向
//   ~/Library/DoNotDisturb/DB/Assertions.json 写入活跃断言（storeAssertionRecords，
//   其中 assertionClock.running == 1 表示生效中）。
// 本监视器只读取该文件判断系统状态，不做任何写入，不改变系统勿扰状态。

import Foundation

final class FocusModeMonitor {

    static let shared = FocusModeMonitor()

    /// 系统勿扰/专注状态变化回调（主线程；true = 系统进入勿扰/专注，false = 退出）
    var onSystemFocusChange: ((Bool) -> Void)?

    /// 当前系统是否处于勿扰/专注模式（上次检测结果）
    private(set) var isSystemFocusActive = false

    /// 兜底轮询定时器（目录监听失效时的安全网）
    private var pollTimer: Timer?
    /// DB 目录监听（断言文件被系统频繁替换，监听目录而非文件本身）
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    private init() {}

    // MARK: - 对外

    /// 启动监视（重复调用安全）
    func start() {
        if pollTimer != nil { return }
        checkNow()

        // 兜底轮询：每 1s 检查一次（目录监听通常毫秒级感知；文件仅几 KB，读取开销可忽略）
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        watchDirectory()
        FileLogger.log("[FocusMode] 勿扰模式监视已启动，当前系统勿扰状态: \(isSystemFocusActive)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        dirSource?.cancel()
        dirSource = nil
    }

    /// 立即检测一次，状态有变化则回调
    func checkNow() {
        let active = Self.readIsSystemFocusActive()
        if active != isSystemFocusActive {
            isSystemFocusActive = active
            FileLogger.log("[FocusMode] 系统勿扰状态变化 → \(active ? "已开启(专注)" : "已关闭(休闲)")")
            onSystemFocusChange?(active)
        }
    }

    // MARK: - 检测逻辑（纯读取）

    /// 读取系统勿扰/专注状态
    /// 实测（macOS 15）：勿扰开启时 data[0].storeAssertionRecords 会出现
    /// 来自 com.apple.focus.activity-manager 的断言（无 assertionClock 字段）；
    /// 勿扰关闭时该数组为空（断言移入 storeInvalidationRecords）。
    /// 因此「存在活跃断言」即判定开启，文件缺失同样判为关闭。
    static func readIsSystemFocusActive() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            return false
        }
        for record in arr {
            guard let assertions = record["storeAssertionRecords"] as? [[String: Any]] else { continue }
            if !assertions.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - 目录监听（秒级响应）

    private func watchDirectory() {
        let dirPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true).path
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else {
            FileLogger.log("[FocusMode] 勿扰 DB 目录监听打开失败，仅靠轮询")
            return
        }
        dirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.checkNow()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.dirFD >= 0 else { return }
            close(self.dirFD)
            self.dirFD = -1
        }
        source.resume()
        dirSource = source
    }
}

