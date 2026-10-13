// MemoryCleaner.swift
// DesktopPetForMacApp — 一键清理内存（测试版）
// 原理：申请并 touch 大块内存，保持压力数秒，促使系统压缩/回收 inactive
// 与压缩内存页，然后释放。无需 root 权限。
// 注意：macOS 会用 inactive/压缩内存做缓存，「空闲」偏低属正常；
// 只有当系统存在可回收的非活跃/压缩页时，本功能才有明显效果。

import Foundation

enum MemoryCleaner {

    /// 单次清理结果
    struct CleanResult {
        let beforeFree: Double
        let afterFree: Double
        let beforeInactive: Double
        let afterInactive: Double
        let beforeCompressed: Double
        let afterCompressed: Double

        /// 回收量 = 空闲增长 + 压缩内存减少（inactive 只是缓存，不纳入回收）
        var freedMB: Double {
            max(afterFree - beforeFree, 0) + max(beforeCompressed - afterCompressed, 0)
        }
    }

    /// 内存快照（MB）：空闲 / 非活跃 / 压缩
    private static func snapshot() -> (free: Double, inactive: Double, compressed: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { base in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, base, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_page_size)
        return (
            free: Double(UInt64(stats.free_count) * pageSize) / 1_000_000,
            inactive: Double(UInt64(stats.inactive_count) * pageSize) / 1_000_000,
            compressed: Double(UInt64(stats.compressor_page_count) * pageSize) / 1_000_000
        )
    }

    /// 执行一次清理
    static func clean() -> CleanResult? {
        guard let before = snapshot() else { return nil }

        // 压力目标：物理总内存的 35%，上限 8GB（确保触发系统回收动作）
        let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000
        let targetMB = min(totalMB * 0.35, 8192)
        guard targetMB > 128 else { return wrap(before, after: before) }

        for _ in 0..<2 {
            let bytes = Int(targetMB * 1_000_000)
            guard let ptr = malloc(bytes) else { return wrap(before, after: before) }
            let base = ptr.assumingMemoryBound(to: UInt8.self)

            // touch 每页 128 字节，强制提交物理页
            var i = 0
            while i < bytes {
                base[i] = 0x01
                base[i + 64] = 0x02
                i += 4096
            }

            // 保持压力 2 秒，给系统时间压缩/回收 inactive 页
            Thread.sleep(forTimeInterval: 2.0)
            free(ptr)
            // 释放后等待系统归还页面
            Thread.sleep(forTimeInterval: 1.5)
        }

        guard let after = snapshot() else { return wrap(before, after: before) }
        return wrap(before, after: after)
    }

    private static func wrap(_ before: (free: Double, inactive: Double, compressed: Double),
                             after: (free: Double, inactive: Double, compressed: Double)) -> CleanResult {
        CleanResult(
            beforeFree: before.free,
            afterFree: after.free,
            beforeInactive: before.inactive,
            afterInactive: after.inactive,
            beforeCompressed: before.compressed,
            afterCompressed: after.compressed
        )
    }
}
