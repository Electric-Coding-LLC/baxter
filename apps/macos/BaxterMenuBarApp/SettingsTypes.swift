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
    var verifySchedule: BackupSchedule
    var verifyDailyTime: String
    var verifyWeeklyDay: WeekdayOption
    var verifyWeeklyTime: String
    var verifyPrefix: String
    var verifyLimit: Int
    var verifySample: Int

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
        keychainAccount: "default",
        verifySchedule: .manual,
        verifyDailyTime: "09:00",
        verifyWeeklyDay: .sunday,
        verifyWeeklyTime: "09:00",
        verifyPrefix: "",
        verifyLimit: 0,
        verifySample: 0
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
    case verifyDailyTime
    case verifyWeeklyDay
    case verifyWeeklyTime
    case verifyLimit
    case verifySample
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

struct DaemonStatus: Decodable {
    let state: String
    let verifyState: String?
    let lastBackupAt: String?
    let nextScheduledAt: String?
    let lastError: String?
    let lastRestoreAt: String?
    let lastRestorePath: String?
    let lastRestoreError: String?
    let lastVerifyAt: String?
    let nextVerifyAt: String?
    let lastVerifyError: String?
    let lastVerifyChecked: Int?
    let lastVerifyOK: Int?
    let lastVerifyMissing: Int?
    let lastVerifyReadErrors: Int?
    let lastVerifyDecryptErrors: Int?
    let lastVerifyChecksumErrors: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case verifyState = "verify_state"
        case lastBackupAt = "last_backup_at"
        case nextScheduledAt = "next_scheduled_at"
        case lastError = "last_error"
        case lastRestoreAt = "last_restore_at"
        case lastRestorePath = "last_restore_path"
        case lastRestoreError = "last_restore_error"
        case lastVerifyAt = "last_verify_at"
        case nextVerifyAt = "next_verify_at"
        case lastVerifyError = "last_verify_error"
        case lastVerifyChecked = "last_verify_checked"
        case lastVerifyOK = "last_verify_ok"
        case lastVerifyMissing = "last_verify_missing"
        case lastVerifyReadErrors = "last_verify_read_errors"
        case lastVerifyDecryptErrors = "last_verify_decrypt_errors"
        case lastVerifyChecksumErrors = "last_verify_checksum_errors"
    }
}

struct RestoreListPayload: Decodable {
    let paths: [String]
}

struct RestoreActionRequest: Encodable {
    let path: String
    let toDir: String?
    let overwrite: Bool
    let verifyOnly: Bool?
    let snapshot: String?

    enum CodingKeys: String, CodingKey {
        case path
        case toDir = "to_dir"
        case overwrite
        case verifyOnly = "verify_only"
        case snapshot
    }

    init(path: String, toDir: String, overwrite: Bool, verifyOnly: Bool? = nil, snapshot: String) {
        self.path = path
        self.toDir = toDir.isEmpty ? nil : toDir
        self.overwrite = overwrite
        self.verifyOnly = verifyOnly
        self.snapshot = snapshot.isEmpty ? nil : snapshot
    }
}

struct RestoreDryRunPayload: Decodable {
    let sourcePath: String
    let targetPath: String
    let overwrite: Bool

    enum CodingKeys: String, CodingKey {
        case sourcePath = "source_path"
        case targetPath = "target_path"
        case overwrite
    }
}

struct RestoreRunPayload: Decodable {
    let sourcePath: String
    let targetPath: String
    let verified: Bool
    let wrote: Bool

    enum CodingKeys: String, CodingKey {
        case sourcePath = "source_path"
        case targetPath = "target_path"
        case verified
        case wrote
    }
}

struct DaemonErrorPayload: Decodable {
    let code: String
    let message: String
}

enum IPCError: Error {
    case badResponse
    case badStatus(Int)
    case server(code: String, message: String, statusCode: Int)
    case reloadUnavailable
}

extension IPCError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Unexpected daemon response."
        case .badStatus(let statusCode):
            return "Daemon returned HTTP \(statusCode)."
        case .server(_, let message, _):
            return message
        case .reloadUnavailable:
            return "Reload endpoint unavailable."
        }
    }
}
