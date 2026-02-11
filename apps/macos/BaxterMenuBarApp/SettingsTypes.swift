import AppKit
import Foundation

enum BackupSchedule: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case manual

    var id: String { rawValue }
}

enum WeekdayOption: String, CaseIterable, Identifiable {
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: String { rawValue }
}

struct BaxterConfig {
    var backupRoots: [String]
    var schedule: BackupSchedule
    var dailyTime: String
    var weeklyDay: WeekdayOption
    var weeklyTime: String
    var s3Endpoint: String
    var s3Region: String
    var s3Bucket: String
    var s3Prefix: String
    var keychainService: String
    var keychainAccount: String

    static let `default` = BaxterConfig(
        backupRoots: [],
        schedule: .daily,
        dailyTime: "09:00",
        weeklyDay: .sunday,
        weeklyTime: "09:00",
        s3Endpoint: "",
        s3Region: "",
        s3Bucket: "",
        s3Prefix: "baxter/",
        keychainService: "baxter",
        keychainAccount: "default"
    )
}

enum SettingsField: Hashable {
    case backupRoots
    case dailyTime
    case weeklyDay
    case weeklyTime
    case s3Endpoint
    case s3Region
    case s3Bucket
    case s3Prefix
    case keychainService
    case keychainAccount
}

enum SettingsError: LocalizedError {
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .validation(let message):
            return message
        }
    }
}
