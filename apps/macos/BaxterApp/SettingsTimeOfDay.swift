import Foundation
import SwiftUI

enum SettingsTimeOfDay {
    static let fallback = "09:00"

    static func components(from value: String) -> DateComponents? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2 else {
            return nil
        }
        guard let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        return DateComponents(hour: hour, minute: minute)
    }

    static func date(from value: String, calendar: Calendar = .current) -> Date {
        let components = components(from: value) ?? DateComponents(hour: 9, minute: 0)
        let startOfReferenceDay = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        return calendar.date(
            bySettingHour: components.hour ?? 9,
            minute: components.minute ?? 0,
            second: 0,
            of: startOfReferenceDay
        ) ?? startOfReferenceDay
    }

    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 9, components.minute ?? 0)
    }
}

extension BaxterSettingsModel {
    func timeOfDayBinding(_ keyPath: ReferenceWritableKeyPath<BaxterSettingsModel, String>) -> Binding<Date> {
        Binding(
            get: { SettingsTimeOfDay.date(from: self[keyPath: keyPath]) },
            set: { newValue in
                self[keyPath: keyPath] = SettingsTimeOfDay.string(from: newValue)
                self.validateDraft()
            }
        )
    }
}
