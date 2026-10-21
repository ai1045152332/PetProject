// PetTimerScheduler.swift
// DesktopPetForMacApp — 宠物定时器的统一调度器
// 负责：按「名字」管理所有定时器，重复调度同名会先取消旧的（杜绝重复触发），
// 一次性定时器触发后自动移除，销毁时 invalidateAll 一次性清理干净（避免遗漏）。

import Foundation

/// 轻量定时器管理容器：把散落在状态机里的多个 `Timer?` 收敛到一张按名字索引的表。
/// 不做 Actor 隔离（便于在 deinit 清理），但所有方法约定在主线程调用；
/// 回调统一通过 `Task { @MainActor }` 回主线程执行。
final class PetTimerScheduler {
    private var timers: [String: Timer] = [:]

    /// 调度一个定时器；同名旧定时器会先被取消并替换。
    /// - Parameters:
    ///   - name: 逻辑标识（如 "frame" / "idleSleep" / "oneShot"），用于后续取消与排查
    ///   - interval: 触发间隔（秒）
    ///   - repeats: 是否重复；false 时触发后自动从表中移除
    ///   - action: 触发回调（在主线程执行）
    @discardableResult
    func schedule(name: String,
                  interval: TimeInterval,
                  repeats: Bool,
                  action: @escaping @MainActor () -> Void) -> Timer {
        cancel(name)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { [weak self] _ in
            Task { @MainActor in
                // 非重复定时器触发即失效：先从表里摘掉，避免字典里堆积已完成的一次性定时器
                if !repeats { self?.timers[name] = nil }
                action()
            }
        }
        timers[name] = timer
        return timer
    }

    /// 取消并移除指定名字的定时器（不存在时静默返回）
    func cancel(_ name: String) {
        timers[name]?.invalidate()
        timers[name] = nil
    }

    /// 该名字当前是否有正在运行的定时器
    func isActive(_ name: String) -> Bool { timers[name] != nil }

    /// 清理全部定时器（对象销毁时调用）
    func invalidateAll() {
        for (_, timer) in timers { timer.invalidate() }
        timers.removeAll()
    }
}
