// StockService.swift
// DesktopPetForMacApp — 股票数据查询服务

import Foundation

struct StockInfo {
    let name: String
    let code: String
    let currentPrice: Double
    let prevClose: Double
    let openPrice: Double
    let high: Double
    let low: Double
    let volume: Double
    let turnover: Double
    let change: Double
    let changePercent: Double
}

struct StockService {
    /// 规范化股票代码（如 600000 → sh600000）
    static func normalizeStockCode(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        
        let prefixes = ["sh", "sz", "bj", "hk"]
        for p in prefixes {
            if trimmed.lowercased().hasPrefix(p) {
                return trimmed.lowercased()
            }
        }
        
        if trimmed.count == 6, trimmed.allSatisfy({ $0.isNumber }) {
            if trimmed.hasPrefix("6") || trimmed.hasPrefix("68") {
                return "sh" + trimmed
            } else if trimmed.hasPrefix("0") || trimmed.hasPrefix("3") {
                return "sz" + trimmed
            } else if trimmed.hasPrefix("8") || trimmed.hasPrefix("4") {
                return "bj" + trimmed
            }
        }
        
        return nil
    }
    
    /// 查询股票信息（腾讯财经接口）
    static func fetchStockInfo(code: String) -> StockInfo? {
        guard let normalized = normalizeStockCode(code) else { return nil }
        let url = "https://qt.gtimg.cn/q=\(normalized)"
        guard let data = NetworkClient.fetchData(url, timeout: 5, userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36") else { return nil }
        
        // 腾讯 API 返回 GBK/GB18030 编码，先尝试 GB18030，再尝试 UTF-8
        let text: String
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let gbText = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) {
            text = gbText
        } else if let utf8Text = String(data: data, encoding: .utf8) {
            text = utf8Text
        } else {
            return nil
        }
        
        let prefix = "v_\(normalized)=\""
        guard let start = text.range(of: prefix)?.upperBound else { return nil }
        guard let end = text[start...].range(of: "\"")?.lowerBound else { return nil }
        let content = String(text[start..<end])
        let parts = content.components(separatedBy: "~")
        
        guard parts.count > 5 else { return nil }
        
        let name = parts[1]
        let currentPrice = Double(parts[3]) ?? 0
        let prevClose = Double(parts[4]) ?? 0
        let openPrice = Double(parts[5]) ?? 0
        let high = parts.count > 19 ? (Double(parts[19]) ?? 0) : 0
        let low = parts.count > 20 ? (Double(parts[20]) ?? 0) : 0
        let volume = parts.count > 6 ? (Double(parts[6]) ?? 0) : 0
        let turnover = parts.count > 7 ? (Double(parts[7]) ?? 0) : 0
        
        let change = currentPrice - prevClose
        let changePercent = prevClose > 0 ? (change / prevClose) * 100 : 0
        
        return StockInfo(
            name: name, code: normalized,
            currentPrice: currentPrice, prevClose: prevClose,
            openPrice: openPrice, high: high, low: low,
            volume: volume, turnover: turnover,
            change: change, changePercent: changePercent
        )
    }
}
