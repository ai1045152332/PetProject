// LocationService.swift
// DesktopPetForMacApp — CoreLocation 定位服务
// macOS 无真实 GPS 芯片，CoreLocation 通过 Wi-Fi 热点数据库定位，精度远高于 IP 定位；
// 定位到坐标后用 CLGeocoder 反地理编码取城市名（中文）
// 使用方式：后台线程调用 fetchGPSLocation()（同步阻塞），权限拒绝/超时返回 nil

import Foundation
import CoreLocation

final class LocationService: NSObject, CLLocationManagerDelegate {

    static let shared = LocationService()

    private let lock = NSLock()
    /// CLLocationManager 必须在带 runloop 的线程创建/使用，这里统一主线程懒创建
    private var manager: CLLocationManager?
    /// 进行中的一次性定位回调
    private var pendingCompletion: ((CLLocation?) -> Void)?
    /// 总超时保护任务
    private var timeoutItem: DispatchWorkItem?

    private override init() { super.init() }

    // MARK: - 对外

    /// 一次性获取当前位置与城市名（同步阻塞，请在后台线程调用）
    /// - Parameter timeout: 定位总超时（含首次权限弹窗等待时间）
    /// - Returns: (城市名, 纬度, 经度)；权限被拒/超时/定位失败返回 nil
    static func fetchGPSLocation(timeout: TimeInterval = 25) -> (city: String, lat: Double, lon: Double)? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (city: String, lat: Double, lon: Double)?
        DispatchQueue.main.async {
            shared.locateOnce(timeout: timeout) { location in
                guard let location else {
                    semaphore.signal()
                    return
                }
                // 反地理编码：坐标 → 中文城市名（locality 优先，缺失回退省级行政区）
                CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")) { placemarks, _ in
                    let pm = placemarks?.first
                    let city = pm?.locality ?? pm?.administrativeArea ?? "当前位置"
                    result = (city, location.coordinate.latitude, location.coordinate.longitude)
                    semaphore.signal()
                }
            }
        }
        // 外层多留 5s 给反地理编码；超时则丢弃挂起任务
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            FileLogger.log("[Location] GPS 定位整体超时(\(Int(timeout))s)")
            shared.cancelPending()
            return nil
        }
        return result
    }

    // MARK: - 内部（以下均在主线程执行）

    /// 主线程发起一次性定位
    private func locateOnce(timeout: TimeInterval, completion: @escaping (CLLocation?) -> Void) {
        lock.lock()
        if pendingCompletion != nil {
            // 已有进行中的定位请求（如上次超时未清理），放弃本次
            lock.unlock()
            completion(nil)
            return
        }
        pendingCompletion = completion
        lock.unlock()

        let m = ensureManager()
        switch m.authorizationStatus {
        case .notDetermined:
            // 首次使用：弹系统授权框，授权结果走 locationManagerDidChangeAuthorization 回调
            m.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            m.requestLocation()
        default:
            // 用户已拒绝 / 受限
            FileLogger.log("[Location] 定位权限被拒绝")
            finishWithLocation(nil)
            return
        }

        // 总超时保护（含等待用户点击授权弹窗的时间）
        let item = DispatchWorkItem { [weak self] in
            FileLogger.log("[Location] 定位超时（权限未授权或信号弱）")
            self?.finishWithLocation(nil)
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// 懒创建 CLLocationManager（主线程）
    private func ensureManager() -> CLLocationManager {
        if let m = manager { return m }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        manager = m
        return m
    }

    /// 结束当前定位请求并回调
    private func finishWithLocation(_ location: CLLocation?) {
        timeoutItem?.cancel()
        timeoutItem = nil
        lock.lock()
        let completion = pendingCompletion
        pendingCompletion = nil
        lock.unlock()
        completion?(location)
    }

    /// 外层超时后的兜底清理（丢弃迟到的回调）
    private func cancelPending() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timeoutItem?.cancel()
            self.timeoutItem = nil
            self.lock.lock()
            self.pendingCompletion = nil
            self.lock.unlock()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finishWithLocation(nil)
        default:
            break // notDetermined：等待用户在授权弹窗中操作
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finishWithLocation(locations.first)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        FileLogger.log("[Location] 定位失败: \(error.localizedDescription)")
        finishWithLocation(nil)
    }
}

