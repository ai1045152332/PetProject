// WeatherReminderTests.swift
// DesktopPetForMacApp — 天气提醒的逾期补发判定
// 一次性 Timer 在系统睡眠期间不按时触发，唤醒后会立刻补发；这里锁住「积压就不弹」的契约。

import XCTest
@testable import DesktopPetForMacApp

final class WeatherReminderTests: XCTestCase {
    private let target = Date(timeIntervalSince1970: 1_700_000_000) // 设定提醒时刻
    private var now: Date { target.addingTimeInterval(8 * 3600) }    // 当天下午 8 小时才醒

    /// 睡眠多日唤醒后的补发必须静默跳过，否则会在午后弹出上午的天气提醒
    func testWakingLongAfterTargetSkipsReminder() {
        XCTAssertFalse(WeatherReminderService.deliverNow(target: target, now: now))
    }

    /// 宽限窗口内（晚开机一小会儿仍值得提醒）照常推送
    func testFiringWithinGraceDelivers() {
        let withinGrace = target.addingTimeInterval(WeatherReminderService.fireGraceInterval)
        XCTAssertTrue(WeatherReminderService.deliverNow(target: target, now: withinGrace))
        XCTAssertTrue(WeatherReminderService.deliverNow(target: target, now: target.addingTimeInterval(60)))
    }

    /// 提前触发（系统时钟/时区边界抖动）不应被当成积压
    func testEarlyFireDelivers() {
        XCTAssertTrue(WeatherReminderService.deliverNow(target: target, now: target.addingTimeInterval(-3600)))
    }

    /// 默认宽限为 2 小时：超过即跳过
    func testDefaultGraceWindowIsTwoHours() {
        XCTAssertEqual(WeatherReminderService.fireGraceInterval, 2 * 60 * 60)
        let justInside = target.addingTimeInterval(2 * 60 * 60 - 1)
        let justOutside = target.addingTimeInterval(2 * 60 * 60 + 1)
        XCTAssertTrue(WeatherReminderService.deliverNow(target: target, now: justInside))
        XCTAssertFalse(WeatherReminderService.deliverNow(target: target, now: justOutside))
    }
}
