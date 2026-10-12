// FileLogger.swift
// DesktopPetForMacApp — 本地文件日志（排查用）

import Foundation

enum FileLogger {
    static let logFile: URL = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        return desktop.appendingPathComponent("DesktopPetForMacApp_log.txt")
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
