// WeatherService.swift
// DesktopPetForMacApp — 天气数据查询服务

import Foundation

struct WeatherHourly {
    let time: String
    let temp: String
    let text: String
    let icon: String
}

struct WeatherDaily {
    let dayName: String
    let textDay: String
    let tempMax: String
    let tempMin: String
    let icon: String
}

struct WeatherForecast {
    let city: String
    let nowTemp: String
    let nowText: String
    let todayMax: String
    let todayMin: String
    let hourly: [WeatherHourly]
    let daily: [WeatherDaily]
}

struct WeatherService {
    /// 说明：天气改为走自建 PetServer 转发（/api/weather），
    /// 上游 Key 只存在服务端，客户端不再持有任何天气服务密钥。
    private static var cachedLocation: (city: String, lat: Double, lon: Double)?
    private static let locationLock = NSLock()

    /// 通过 GPS/Wi-Fi 定位获取天气（CoreLocation + 反地理编码，精度远高于 IP 定位）
    /// 失败（权限拒绝/超时）返回 nil，由调用方回退 IP 定位
    static func fetchWeatherForecastWithGPS() -> WeatherForecast? {
        guard let loc = LocationService.fetchGPSLocation() else { return nil }
        return fetchWeatherForecast(city: loc.city, lat: loc.lat, lon: loc.lon)
    }

    /// 通过定位获取天气（带缓存）
    static func fetchWeatherForecastWithLocation() -> WeatherForecast? {
        locationLock.lock()
        let cached = cachedLocation
        locationLock.unlock()
        if let loc = cached {
            return fetchWeatherForecast(city: loc.city, lat: loc.lat, lon: loc.lon)
        }
        guard let loc = fetchLocation() else { return nil }
        locationLock.lock()
        cachedLocation = loc
        locationLock.unlock()
        return fetchWeatherForecast(city: loc.city, lat: loc.lat, lon: loc.lon)
    }

    /// 天气描述 → emoji 映射
    static func weatherEmoji(for text: String) -> String {
        if text.contains("晴") { return "☀️" }
        if text.contains("多云") { return "⛅" }
        if text.contains("阴") { return "☁️" }
        if text.contains("雨") { return "🌧️" }
        if text.contains("雪") { return "❄️" }
        if text.contains("雷") { return "⛈️" }
        if text.contains("雾") || text.contains("霾") { return "🌫️" }
        return "🌤️"
    }
    
    /// 格式化 ISO 时间为中文小时（如 "18时"）
    static func formatHour(from isoTime: String) -> String {
        let parts = isoTime.split(separator: "T")
        guard parts.count == 2 else { return isoTime }
        let timePart = String(parts[1])
        let hourParts = timePart.split(separator: ":")
        guard let hour = hourParts.first else { return isoTime }
        return "\(hour)时"
    }
    
    /// 获取当前城市名和坐标（国内友好：api.ip.sb，5秒超时）
    static func fetchLocation() -> (city: String, lat: Double, lon: Double)? {
        guard let data = NetworkClient.fetchData("https://api.ip.sb/geoip", timeout: 5),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let city = json["city"] as? String,
              let lat = json["latitude"] as? Double,
              let lon = json["longitude"] as? Double else {
            return nil
        }
        return (city, lat, lon)
    }
    
    /// 通过城市名查询天气（先地理编码再查天气）
    static func fetchWeatherForecast(forCity cityName: String) -> WeatherForecast? {
        let encoded = cityName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cityName
        let nominatimURL = "https://nominatim.openstreetmap.org/search?q=\(encoded)&format=json&limit=1"
        guard let geoData = NetworkClient.fetchData(nominatimURL, timeout: 8, userAgent: "DesktopPetForMacApp/1.0"),
              let geoJson = try? JSONSerialization.jsonObject(with: geoData) as? [[String: Any]],
              let first = geoJson.first,
              let latStr = first["lat"] as? String,
              let lonStr = first["lon"] as? String,
              let lat = Double(latStr),
              let lon = Double(lonStr),
              let displayName = first["display_name"] as? String else {
            return nil
        }
        let shortName = displayName.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? cityName
        return fetchWeatherForecast(city: shortName, lat: lat, lon: lon)
    }
    
    /// 通过坐标查询天气（走自建后端转发，服务端代持上游 Key）
    static func fetchWeatherForecast(city: String, lat: Double, lon: Double) -> WeatherForecast? {
        var comps = URLComponents(string: ServerConfig.baseURL + "/api/weather")
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", lon)),
            URLQueryItem(name: "city", value: city),
            URLQueryItem(name: "deviceId", value: AccessControl.deviceID)
        ]
        guard let url = comps?.url else { return nil }

        guard let data = NetworkClient.fetchData(url.absoluteString, timeout: 8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            FileLogger.log("[Weather] 后端响应异常")
            return nil
        }
        guard (json["code"] as? Int) == 0, let d = json["data"] as? [String: Any] else {
            let msg = json["msg"] as? String ?? "unknown"
            FileLogger.log("[Weather] 查询失败: \(msg)")
            return nil
        }

        let hourly: [WeatherHourly] = (d["hourly"] as? [[String: Any]] ?? []).map { h in
            let text = h["text"] as? String ?? ""
            return WeatherHourly(
                time: h["time"] as? String ?? "",
                temp: h["temp"] as? String ?? "?",
                text: text,
                icon: weatherEmoji(for: text)
            )
        }

        let daily: [WeatherDaily] = (d["daily"] as? [[String: Any]] ?? []).map { day in
            let textDay = day["textDay"] as? String ?? "未知"
            return WeatherDaily(
                dayName: day["dayName"] as? String ?? "",
                textDay: textDay,
                tempMax: day["tempMax"] as? String ?? "?",
                tempMin: day["tempMin"] as? String ?? "?",
                icon: weatherEmoji(for: textDay)
            )
        }

        return WeatherForecast(
            city: d["city"] as? String ?? city,
            nowTemp: d["nowTemp"] as? String ?? "?",
            nowText: d["nowText"] as? String ?? "未知",
            todayMax: d["todayMax"] as? String ?? "?",
            todayMin: d["todayMin"] as? String ?? "?",
            hourly: hourly,
            daily: daily
        )
    }
}
