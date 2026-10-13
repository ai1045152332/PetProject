// FileLogger.swift
// DesktopPetForMacApp — 本地文件日志（排查用）

import Foundation

enum FileLogger {
    /// 日志文件放在 ~/Library/Logs（Library 子目录无需 TCC「访问桌面/文稿」授权）
    /// 避免写入桌面目录触发 macOS「此 App 想访问您桌面中的文件」权限弹窗
    static let logFile: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logsDir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("DesktopPetForMacApp_log.txt")
    }()

    static func setup() {
        // 启动时清空旧日志
        let header = "=== DesktopPetForMacApp 日志 \(Date()) ===\n"
        try? header.write(to: logFile, atomically: true, encoding: .utf8)
    }

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? line.write(to: logFile, atomically: true, encoding: .utf8)
            }
        }
        // 同时输出到 NSLog
        NSLog("%@", message)
    }
}
