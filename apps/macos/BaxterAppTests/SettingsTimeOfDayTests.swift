import XCTest
@testable import BaxterApp

@MainActor
final class SettingsTimeOfDayTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    func testRoundTripsConfigTimes() {
        for value in ["00:00", "09:00", "13:45", "23:59"] {
            let date = SettingsTimeOfDay.date(from: value, calendar: calendar)
            XCTAssertEqual(SettingsTimeOfDay.string(from: date, calendar: calendar), value)
        }
    }

    func testInvalidTimeFallsBackToDefault() {
        for value in ["", "9:0", "24:00", "12:60", "noon"] {
            XCTAssertNil(SettingsTimeOfDay.components(from: value))
            let date = SettingsTimeOfDay.date(from: value, calendar: calendar)
            XCTAssertEqual(SettingsTimeOfDay.string(from: date, calendar: calendar), SettingsTimeOfDay.fallback)
        }
    }

    func testStringPadsHourAndMinute() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 7, minute: 5))!
        XCTAssertEqual(SettingsTimeOfDay.string(from: date, calendar: calendar), "07:05")
    }

    func testBindingWritesConfigTimeAndMarksDraftChanged() {
        let model = BaxterSettingsModel()
        let binding = model.timeOfDayBinding(\.dailyTime)
        let current = SettingsTimeOfDay.components(from: model.dailyTime)
        let nextHour = ((current?.hour ?? 9) + 1) % 24
        let date = Calendar.current.date(bySettingHour: nextHour, minute: 30, second: 0, of: Date())!

        binding.wrappedValue = date

        XCTAssertEqual(model.dailyTime, String(format: "%02d:30", nextHour))
        XCTAssertNil(model.validationMessage(for: .dailyTime))
        XCTAssertEqual(SettingsTimeOfDay.string(from: binding.wrappedValue), model.dailyTime)
    }
}
