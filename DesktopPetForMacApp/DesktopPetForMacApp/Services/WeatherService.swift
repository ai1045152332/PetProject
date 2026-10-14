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
    private static let qweatherHost = "kv359hcbtd.re.qweatherapi.com"
    private static let qweatherKey  = "f1f27eaa954e40aa975a0a9418a205f0"
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
    
    /// 通过坐标查询天气
    static func fetchWeatherForecast(city: String, lat: Double, lon: Double) -> WeatherForecast? {
        let loc = "\(lon),\(lat)"
        
        // 1. 实时天气
        let nowURL = "https://\(qweatherHost)/v7/weather/now?location=\(loc)&key=\(qweatherKey)"
        guard let nowData = NetworkClient.fetchData(nowURL, timeout: 5),
              let nowJson = try? JSONSerialization.jsonObject(with: nowData) as? [String: Any],
              let nowCode = nowJson["code"] as? String, nowCode == "200",
              let now = nowJson["now"] as? [String: Any] else {
            return nil
        }
        let nowTemp = now["temp"] as? String ?? "?"
        let nowText = now["text"] as? String ?? "未知"
        
        // 2. 逐小时预报
        var hourly: [WeatherHourly] = []
        let h24URL = "https://\(qweatherHost)/v7/weather/24h?location=\(loc)&key=\(qweatherKey)"
        if let h24Data = NetworkClient.fetchData(h24URL, timeout: 5),
           let h24Json = try? JSONSerialization.jsonObject(with: h24Data) as? [String: Any],
           let h24Code = h24Json["code"] as? String, h24Code == "200",
           let h24List = h24Json["hourly"] as? [[String: Any]] {
            for h in h24List.prefix(6) {
                let fxTime = h["fxTime"] as? String ?? ""
                let hourStr = formatHour(from: fxTime)
                let temp = h["temp"] as? String ?? "?"
                let text = h["text"] as? String ?? ""
                hourly.append(WeatherHourly(time: hourStr, temp: temp, text: text, icon: weatherEmoji(for: text)))
            }
        }
        
        // 3. 3天预报
        let d3URL = "https://\(qweatherHost)/v7/weather/3d?location=\(loc)&key=\(qweatherKey)"
        guard let d3Data = NetworkClient.fetchData(d3URL, timeout: 5),
              let d3Json = try? JSONSerialization.jsonObject(with: d3Data) as? [String: Any],
              let d3Code = d3Json["code"] as? String, d3Code == "200",
              let dailyList = d3Json["daily"] as? [[String: Any]],
              !dailyList.isEmpty else {
            return nil
        }
        
        var daily: [WeatherDaily] = []
        let dayNames = ["今天", "明天", "后天"]
        for (i, d) in dailyList.enumerated() {
            let name = i < 3 ? dayNames[i] : "第\(i+1)天"
            let textDay = d["textDay"] as? String ?? "未知"
            daily.append(WeatherDaily(
                dayName: name,
                textDay: textDay,
                tempMax: d["tempMax"] as? String ?? "?",
                tempMin: d["tempMin"] as? String ?? "?",
                icon: weatherEmoji(for: textDay)
            ))
        }
        
        let today = dailyList.first
        let todayMax = today?["tempMax"] as? String ?? "?"
        let todayMin = today?["tempMin"] as? String ?? "?"
        
        return WeatherForecast(
            city: city,
            nowTemp: nowTemp,
            nowText: nowText,
            todayMax: todayMax,
            todayMin: todayMin,
            hourly: hourly,
            daily: daily
        )
    }
}
