import AppKit
import Foundation

@MainActor
final class BaxterSettingsModel: ObservableObject {
    @Published var backupRoots: [String] = []
    @Published var schedule: BackupSchedule = .daily
    @Published var dailyTime: String = "09:00"
    @Published var weeklyDay: WeekdayOption = .sunday
    @Published var weeklyTime: String = "09:00"
    @Published var s3Endpoint: String = ""
    @Published var s3Region: String = ""
    @Published var s3Bucket: String = ""
    @Published var s3Prefix: String = "baxter/"
    @Published var keychainService: String = "baxter"
    @Published var keychainAccount: String = "default"
    @Published var verifySchedule: BackupSchedule = .manual
    @Published var verifyDailyTime: String = "09:00"
    @Published var verifyWeeklyDay: WeekdayOption = .sunday
    @Published var verifyWeeklyTime: String = "09:00"
    @Published var verifyPrefix: String = ""
    @Published var verifyLimit: String = "0"
    @Published var verifySample: String = "0"
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var validationErrors: [SettingsField: String] = [:]
    @Published private(set) var backupRootWarnings: [String: String] = [:]

    var canSave: Bool {
        validationErrors.isEmpty
    }

    var s3ModeHint: String {
        let config = draftConfig()
        if config.s3Bucket.isEmpty {
            return "Local mode: objects are stored on this Mac. Set bucket and region to use S3."
        }
        return "S3 mode: uploads go to the configured bucket. Endpoint is optional for AWS and required for some S3-compatible providers."
    }

    var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("baxter")
            .appendingPathComponent("config.toml")
    }

    init() {
        load()
    }

    func validationMessage(for field: SettingsField) -> String? {
        validationErrors[field]
    }

    func backupRootWarning(for root: String) -> String? {
        backupRootWarnings[root]
    }

    func shouldOfferApplyNow(daemonState: DaemonServiceState) -> Bool {
        errorMessage == nil && daemonState == .running
    }

    func load() {
        do {
            let config: BaxterConfig
            if FileManager.default.fileExists(atPath: configURL.path) {
                let text = try String(contentsOf: configURL, encoding: .utf8)
                config = decodeBaxterConfig(from: text)
                statusMessage = "Loaded settings from config.toml"
            } else {
                config = .default
                statusMessage = "Config not found. Showing defaults."
            }
            apply(config)
            validateDraft()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load config: \(error.localizedDescription)"
        }
    }

    func save() {
        do {
            validateDraft()
            guard canSave else {
                errorMessage = "Fix highlighted fields before saving."
                return
            }

            let config = try buildConfigForSave()
            let text = encodeBaxterConfig(config)

            let directory = configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try text.write(to: configURL, atomically: true, encoding: .utf8)

            statusMessage = "Saved settings to \(configURL.path)"
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save config: \(error.localizedDescription)"
        }
    }

    func validateDraft() {
        let config = draftConfig()
        backupRootWarnings = backupRootIssues(for: config.backupRoots)
        validationErrors = validationIssues(for: config, backupRootWarnings: backupRootWarnings)
    }

    func chooseBackupRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "Add"
        panel.message = "Select one or more folders to back up."

        let response = panel.runModal()
        guard response == .OK else {
            return
        }

        addBackupRoots(panel.urls.map(\.path))
    }

    func removeBackupRoots(at offsets: IndexSet) {
        for offset in offsets.sorted(by: >) {
            backupRoots.remove(at: offset)
        }
        statusMessage = nil
        errorMessage = nil
        validateDraft()
    }

    func removeBackupRoot(_ root: String) {
        backupRoots.removeAll { $0 == root }
        statusMessage = nil
        errorMessage = nil
        validateDraft()
    }

    func clearBackupRoots() {
        backupRoots = []
        statusMessage = nil
        errorMessage = nil
        validateDraft()
    }

    private func apply(_ config: BaxterConfig) {
        backupRoots = config.backupRoots
        schedule = config.schedule
        dailyTime = config.dailyTime
        weeklyDay = config.weeklyDay
        weeklyTime = config.weeklyTime
        s3Endpoint = config.s3Endpoint
        s3Region = config.s3Region
        s3Bucket = config.s3Bucket
        s3Prefix = config.s3Prefix
        keychainService = config.keychainService
        keychainAccount = config.keychainAccount
        verifySchedule = config.verifySchedule
        verifyDailyTime = config.verifyDailyTime
        verifyWeeklyDay = config.verifyWeeklyDay
        verifyWeeklyTime = config.verifyWeeklyTime
        verifyPrefix = config.verifyPrefix
        verifyLimit = String(config.verifyLimit)
        verifySample = String(config.verifySample)
    }

    private func buildConfigForSave() throws -> BaxterConfig {
        let config = draftConfig()
        let warnings = backupRootIssues(for: config.backupRoots)
        backupRootWarnings = warnings
        let errors = validationIssues(for: config, backupRootWarnings: warnings)
        validationErrors = errors
        if let message = firstValidationMessage(from: errors) {
            throw SettingsError.validation(message)
        }
        return config
    }

    private func addBackupRoots(_ paths: [String]) {
        let merged = backupRoots + paths
        backupRoots = normalizedBackupRoots(merged)
        statusMessage = nil
        errorMessage = nil
        validateDraft()
    }

    private func normalizedBackupRoots(_ roots: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for root in roots {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            guard !seen.contains(trimmed) else {
                continue
            }
            seen.insert(trimmed)
            result.append(trimmed)
        }

        return result
    }

    private func draftConfig() -> BaxterConfig {
        let backupRoots = normalizedBackupRoots(backupRoots)

        var config = BaxterConfig(
            backupRoots: backupRoots,
            schedule: schedule,
            dailyTime: dailyTime.trimmingCharacters(in: .whitespacesAndNewlines),
            weeklyDay: weeklyDay,
            weeklyTime: weeklyTime.trimmingCharacters(in: .whitespacesAndNewlines),
            s3Endpoint: s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            s3Region: s3Region.trimmingCharacters(in: .whitespacesAndNewlines),
            s3Bucket: s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            s3Prefix: s3Prefix.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainService: keychainService.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainAccount: keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines),
            verifySchedule: verifySchedule,
            verifyDailyTime: verifyDailyTime.trimmingCharacters(in: .whitespacesAndNewlines),
            verifyWeeklyDay: verifyWeeklyDay,
            verifyWeeklyTime: verifyWeeklyTime.trimmingCharacters(in: .whitespacesAndNewlines),
            verifyPrefix: verifyPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            verifyLimit: nonNegativeInt(from: verifyLimit.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            verifySample: nonNegativeInt(from: verifySample.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        )

        if config.s3Prefix.isEmpty {
            config.s3Prefix = "baxter/"
        }
        if !config.s3Prefix.hasSuffix("/") {
            config.s3Prefix += "/"
        }
        if config.dailyTime.isEmpty {
            config.dailyTime = "09:00"
        }
        if config.weeklyTime.isEmpty {
            config.weeklyTime = "09:00"
        }
        if config.verifyDailyTime.isEmpty {
            config.verifyDailyTime = "09:00"
        }
        if config.verifyWeeklyTime.isEmpty {
            config.verifyWeeklyTime = "09:00"
        }

        return config
    }

    private func validationIssues(for config: BaxterConfig, backupRootWarnings: [String: String]) -> [SettingsField: String] {
        var errors: [SettingsField: String] = [:]

        if !backupRootWarnings.isEmpty {
            errors[.backupRoots] = "Fix invalid backup folders before saving."
        }
        switch config.schedule {
        case .daily:
            if !isValidTime(config.dailyTime) {
                errors[.dailyTime] = "Daily time must be HH:MM (24-hour)."
            }
        case .weekly:
            if !isValidTime(config.weeklyTime) {
                errors[.weeklyTime] = "Weekly time must be HH:MM (24-hour)."
            }
        case .manual:
            break
        }
        switch config.verifySchedule {
        case .daily:
            if !isValidTime(config.verifyDailyTime) {
                errors[.verifyDailyTime] = "Verify daily time must be HH:MM (24-hour)."
            }
        case .weekly:
            if !isValidTime(config.verifyWeeklyTime) {
                errors[.verifyWeeklyTime] = "Verify weekly time must be HH:MM (24-hour)."
            }
        case .manual:
            break
        }

        if nonNegativeInt(from: verifyLimit.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            errors[.verifyLimit] = "Verify limit must be a non-negative integer."
        }
        if nonNegativeInt(from: verifySample.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            errors[.verifySample] = "Verify sample must be a non-negative integer."
        }

        if config.s3Bucket.isEmpty {
            if !config.s3Region.isEmpty || !config.s3Endpoint.isEmpty {
                errors[.s3Bucket] = "Bucket is required when region or endpoint is set."
            }
        } else {
            if config.s3Region.isEmpty {
                errors[.s3Region] = "Region is required when bucket is set."
            }
            if config.s3Bucket.contains("/") {
                errors[.s3Bucket] = "Bucket must not contain '/'."
            }
        }
        if !config.s3Endpoint.isEmpty {
            let url = URL(string: config.s3Endpoint)
            let scheme = url?.scheme?.lowercased()
            if (scheme != "http" && scheme != "https") || url?.host == nil {
                errors[.s3Endpoint] = "Endpoint must be a valid http(s) URL."
            }
        }

        if config.s3Prefix.isEmpty {
            errors[.s3Prefix] = "Prefix must not be empty."
        }
        if config.keychainService.isEmpty {
            errors[.keychainService] = "Keychain service must not be empty."
        }
        if config.keychainAccount.isEmpty {
            errors[.keychainAccount] = "Keychain account must not be empty."
        }

        return errors
    }

    private func firstValidationMessage(from errors: [SettingsField: String]) -> String? {
        let orderedFields: [SettingsField] = [
            .backupRoots,
            .dailyTime,
            .weeklyDay,
            .weeklyTime,
            .verifyDailyTime,
            .verifyWeeklyDay,
            .verifyWeeklyTime,
            .verifyLimit,
            .verifySample,
            .s3Bucket,
            .s3Region,
            .s3Prefix,
            .keychainService,
            .keychainAccount,
            .s3Endpoint,
        ]
        for field in orderedFields {
            if let message = errors[field] {
                return message
            }
        }
        return nil
    }

    private func backupRootIssues(for roots: [String]) -> [String: String] {
        var issues: [String: String] = [:]
        for root in roots {
            if !root.hasPrefix("/") {
                issues[root] = "Folder path must be absolute."
                continue
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory)
            if !exists {
                issues[root] = "Folder does not exist."
                continue
            }
            if !isDirectory.boolValue {
                issues[root] = "Path is not a folder."
                continue
            }
            if !FileManager.default.isReadableFile(atPath: root) {
                issues[root] = "Folder is not readable."
            }
        }
        return issues
    }

    private func isValidTime(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        guard parts[0].count == 2, parts[1].count == 2 else { return false }
        guard let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }

    private func nonNegativeInt(from value: String) -> Int? {
        guard let parsed = Int(value), parsed >= 0 else {
            return nil
        }
        return parsed
    }

}
