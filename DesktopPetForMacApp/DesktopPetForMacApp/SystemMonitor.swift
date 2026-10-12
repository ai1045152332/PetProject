// SystemMonitor.swift
// DesktopPetForMacApp — 系统指标采集（CPU / 内存 / CPU 温度）
// 供菜单栏展示与设置面板选择

import Foundation
import IOKit

/// 系统资源监控
enum SystemMonitor {

    // MARK: - 菜单栏显示配置（UserDefaults Key）

    enum MenuPrefs {
        static let showCPU    = "menuBar.showCPU"
        static let showMemory = "menuBar.showMemory"
        static let showTemp   = "menuBar.showTemp"

        /// 读取勾选状态（未设置时按默认值）
        static func isOn(_ key: String, default defaultValue: Bool) -> Bool {
            if let v = UserDefaults.standard.object(forKey: key) as? Bool { return v }
            return defaultValue
        }
    }

    // MARK: - CPU 占用率

    private static let cpuLock = NSLock()
    private static var lastCPUInfo: host_cpu_load_info?
    private static var cachedCPU: Double?
    private static var cachedCPUTime: Date = .distantPast
    private static let cpuCacheInterval: TimeInterval = 1.5

    /// CPU 总占用率（0-100）
    /// 首次采样无基线返回 nil，之后基于两次采样的 tick 差值计算
    static func cpuUsage() -> Double? {
        cpuLock.lock()
        defer { cpuLock.unlock() }

        if let cached = cachedCPU, Date().timeIntervalSince(cachedCPUTime) < cpuCacheInterval {
            return cached
        }

        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { base in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, base, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return cachedCPU }

        defer { lastCPUInfo = info }
        guard let prev = lastCPUInfo else { return nil }

        let user   = Double(info.cpu_ticks.0 - prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 - prev.cpu_ticks.1)
        let idle   = Double(info.cpu_ticks.2 - prev.cpu_ticks.2)
        let nice   = Double(info.cpu_ticks.3 - prev.cpu_ticks.3)
        let total  = user + system + idle + nice
        guard total > 0 else { return cachedCPU }

        let usage = min(max((user + system + nice) / total * 100.0, 0), 100)
        cachedCPU = usage
        cachedCPUTime = Date()
        return usage
    }

    // MARK: - 内存占用率

    /// 内存使用率（0-100）与容量（GB）
    /// 口径接近活动监视器：已用 ≈ 总量 - 空闲 - 非活跃 - 推测
    static func memoryUsage() -> (percent: Double, usedGB: Double, totalGB: Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { base in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, base, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize

        let used = total > (free + inactive + speculative) ? total - free - inactive - speculative : total
        let percent = min(max(Double(used) / Double(total) * 100.0, 0), 100)
        return (percent, Double(used) / 1_000_000_000, Double(total) / 1_000_000_000)
    }

    // MARK: - CPU 温度（AppleSMC）

    private static let tempLock = NSLock()
    private static var cachedTemp: Double?
    private static var lastTempAttempt: Date = .distantPast
    private static let tempCacheInterval: TimeInterval = 3.0

    /// 可能的 CPU 温度 SMC 键：Intel 常用 TC0P/TC0E/TC0F，Apple Silicon 常用 Tp09/Tp0T/Tp01
    private static let temperatureKeys = [
        "TC0P", "TC0E", "TC0F", "TC0c", "TC0G", "TC0H",
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D"
    ]

    /// CPU 温度（摄氏度）。读取失败 / 无权限返回 nil（菜单栏对应项自动隐藏）
    static func cpuTemperature() -> Double? {
        tempLock.lock()
        defer { tempLock.unlock() }

        if Date().timeIntervalSince(lastTempAttempt) < tempCacheInterval {
            return cachedTemp
        }
        lastTempAttempt = Date()

        guard let conn = smcConnection else { return nil }
        for key in temperatureKeys {
            if let t = readSMCFloat(conn, key: key), t > 5, t < 130 {
                cachedTemp = Double(t)
                return cachedTemp
            }
        }
        cachedTemp = nil
        return nil
    }

    // MARK: - SMC 底层（手工构造 88 字节 SMCParamStruct）

    private static let smcConnection: io_connect_t? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == kIOReturnSuccess else { return nil }
        return conn
    }()

    /// 读取单个 SMC 浮点键。
    /// 布局：key(4) | vers(4) | pLimitData(4) | dataSize(4) | dataType(4) | dataAttributes(4)
    ///       | result(1) | status(1) | data8(1) | data32(4) | bytes(32) | padding(16) | result(4) = 88 字节
    private static func readSMCFloat(_ conn: io_connect_t, key: String) -> Float? {
        var input = [UInt8](repeating: 0, count: 88)
        var output = [UInt8](repeating: 0, count: 88)

        // key（大端 fourcc）
        let k = fourCC(key)
        input[0] = UInt8((k >> 24) & 0xFF)
        input[1] = UInt8((k >> 16) & 0xFF)
        input[2] = UInt8((k >> 8) & 0xFF)
        input[3] = UInt8(k & 0xFF)

        input[4] = 1                      // vers = 1.0
        input[12] = 4                     // keyInfo.dataSize = 4
        let dt: UInt32 = 0x666c7420       // 'flt '（浮点类型）
        input[16] = UInt8(dt & 0xFF)
        input[17] = UInt8((dt >> 8) & 0xFF)
        input[18] = UInt8((dt >> 16) & 0xFF)
        input[19] = UInt8((dt >> 24) & 0xFF)
        input[26] = 5                     // data8 = SMC_CMD_READ_BYTES

        var outSize = output.count
        let inputCount = input.count
        let kr = input.withUnsafeMutableBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                IOConnectCallStructMethod(conn, 2, inBuf.baseAddress, inputCount, outBuf.baseAddress, &outSize)
            }
        }
        guard kr == kIOReturnSuccess, outSize >= 32 else { return nil }

        // data32（小端）即浮点值
        let v = UInt32(output[28]) |
                (UInt32(output[29]) << 8) |
                (UInt32(output[30]) << 16) |
                (UInt32(output[31]) << 24)
        let f = Float(bitPattern: v)
        guard f.isFinite, f > -100, f < 200 else { return nil }
        return f
    }

    private static func fourCC(_ s: String) -> UInt32 {
        let chars = Array(s.utf8)
        guard chars.count >= 4 else { return 0 }
        return UInt32(chars[0]) << 24 |
               UInt32(chars[1]) << 16 |
               UInt32(chars[2]) << 8 |
               UInt32(chars[3])
    }
}
