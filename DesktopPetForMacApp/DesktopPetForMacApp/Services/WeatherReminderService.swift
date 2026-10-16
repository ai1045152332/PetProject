// WeatherReminderService.swift
// DesktopPetForMacApp — 每日天气提醒
// 到设定时间点抓取当天天气并弹卡片提醒；仅「已解锁全部功能」的用户可用（天气接口按量付费）

import Foundation
import AppKit

@MainActor
final class WeatherReminderService {
    static let shared = WeatherReminderService()

    private enum Keys {
        static let enabled = "settings.weatherReminderEnabled"
        static let hour = "settings.weatherReminderHour"
        static let minute = "settings.weatherReminderMinute"
        static let city = "settings.weatherReminderCity"
    }

    /// 默认提醒时间：早上 8:00
    static let defaultHour = 8
    static let defaultMinute = 0

    private var timer: Timer?

    private init() {}

    // MARK: - 配置读写

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
            FileLogger.log("[WeatherReminder] 开关：\(newValue ? "开启" : "关闭")")
            reschedule()
        }
    }

    var hour: Int {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.hour) as? Int
            return v ?? Self.defaultHour
        }
        set {
            UserDefaults.standard.set(max(0, min(23, newValue)), forKey: Keys.hour)
            reschedule()
        }
    }

    var minute: Int {
        get {
            let v = UserDefaults.standard.object(forKey: Keys.minute) as? Int
            return v ?? Self.defaultMinute
        }
        set {
            UserDefaults.standard.set(max(0, min(59, newValue)), forKey: Keys.minute)
            reschedule()
        }
    }

    /// 提醒用的城市（留空表示按定位）
    var city: String {
        get { UserDefaults.standard.string(forKey: Keys.city) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.city) }
    }

    /// 形如 08:00
    var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    // MARK: - 调度

    /// 启动时调用：开启状态则安排下一次提醒
    func start() {
        if isEnabled {
            scheduleNext()
        }
    }

    /// 配置变化后重排
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        scheduleNext()
    }

    private func scheduleNext() {
        guard isEnabled else { return }

        let cal = Calendar.current
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        comps.second = 0

        let now = Date()
        guard var next = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) else { return }
        // nextDate 在时间已过时会顺延到明天，若正好等于今天且已过则再确保一次
        if next <= now {
            next = cal.date(byAdding: .day, value: 1, to: next) ?? next
        }

        let t = Timer(fireAt: next, interval: 0, target: self, selector: #selector(handleFire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        FileLogger.log("[WeatherReminder] 已安排下次提醒：\(formatter.string(from: next))（城市：\(city.isEmpty ? "按定位" : city)）")
    }

    @objc private func handleFire() {
        timer = nil
        // 无论结果如何都先安排明天
        defer { scheduleNext() }

        // 基础权限不提醒（天气接口按量付费，仅解锁用户可用）
        guard AccessControl.isFullAccess else {
            FileLogger.log("[WeatherReminder] 当前为基础权限，跳过天气提醒")
            return
        }
        deliver()
    }

    /// 立即抓取并弹卡片（也用于设置面板的「预览」）
    func deliver() {
        let cityName = city
        DispatchQueue.global(qos: .utility).async {
            let forecast: WeatherForecast?
            if !cityName.isEmpty {
                forecast = WeatherService.fetchWeatherForecast(forCity: cityName)
            } else {
                forecast = WeatherService.fetchWeatherForecastWithGPS()
                    ?? WeatherService.fetchWeatherForecastWithLocation()
            }

            DispatchQueue.main.async {
                if let forecast {
                    HTMLAlertWindow.showWeatherCard(forecast, title: "今日天气 ☀️")
                    FileLogger.log("[WeatherReminder] 已推送今日天气（\(forecast.city)）")
                } else {
                    HTMLAlertWindow.show(
                        title: "天气提醒",
                        htmlBody: "<div style=\"text-align:center;padding:24px 10px;color:#c0c0d0;font-size:14px;line-height:1.8;\">天气获取失败，请稍后再试</div>",
                        width: 320
                    )
                    FileLogger.log("[WeatherReminder] 天气获取失败")
                }
            }
        }
    }
}
