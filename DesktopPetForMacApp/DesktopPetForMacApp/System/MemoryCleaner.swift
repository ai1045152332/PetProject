// MemoryCleaner.swift
// DesktopPetForMacApp — 一键清理内存（测试版）
// 原理：申请并 touch 大块内存，促使系统压缩/回收 inactive 与压缩内存页，
// 然后立即释放，使空闲+非活跃内存显著回升。无需 root 权限。

import Foundation

enum MemoryCleaner {

    /// 当前「空闲 + 非活跃」内存（MB）
    private static func reclaimableMB() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { base in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, base, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_page_size)
        let freeMB = Double(UInt64(stats.free_count) * pageSize) / 1_000_000
        let inactiveMB = Double(UInt64(stats.inactive_count) * pageSize) / 1_000_000
        return freeMB + inactiveMB
    }

    /// 执行一次清理。返回 (释放前可回收MB, 释放后可回收MB, 回收增量MB)
    static func clean() -> (before: Double, after: Double, freed: Double)? {
        guard let before = reclaimableMB() else { return nil }

        // 申请目标：可回收内存的 60%，上限 4GB（避免过度挤压）
        let targetMB = min(before * 0.6, 4096)
        guard targetMB > 64 else { return (before, before, 0) }

        let bytes = Int(targetMB * 1_000_000)
        guard let ptr = malloc(bytes) else { return (before, before, 0) }
        defer { free(ptr) }

        // touch 每一页（每 4KB 写 1 字节），强制分配物理页
        let base = ptr.assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < bytes {
            base[i] = 0x01
            i += 4096
        }

        // 释放后等待系统回收页
        free(ptr)
        Thread.sleep(forTimeInterval: 0.8)

        guard let after = reclaimableMB() else { return (before, before, 0) }
        return (before, after, max(after - before, 0))
    }
}
