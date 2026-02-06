import AppKit
import Foundation

enum BackupSchedule: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case manual

    var id: String { rawValue }
}

struct BaxterConfig {
    var backupRoots: [String]
    var schedule: BackupSchedule
    var s3Endpoint: String
    var s3Region: String
    var s3Bucket: String
    var s3Prefix: String
    var keychainService: String
    var keychainAccount: String

    static let `default` = BaxterConfig(
        backupRoots: [],
        schedule: .daily,
        s3Endpoint: "",
        s3Region: "",
        s3Bucket: "",
        s3Prefix: "baxter/",
        keychainService: "baxter",
        keychainAccount: "default"
    )
}

enum SettingsField: Hashable {
    case s3Endpoint
    case s3Region
    case s3Bucket
    case s3Prefix
    case keychainService
    case keychainAccount
}

@MainActor
final class BaxterSettingsModel: ObservableObject {
    @Published var backupRoots: [String] = []
    @Published var schedule: BackupSchedule = .daily
    @Published var s3Endpoint: String = ""
    @Published var s3Region: String = ""
    @Published var s3Bucket: String = ""
    @Published var s3Prefix: String = "baxter/"
    @Published var keychainService: String = "baxter"
    @Published var keychainAccount: String = "default"
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var validationErrors: [SettingsField: String] = [:]

    var canSave: Bool {
        validationErrors.isEmpty
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

    func load() {
        do {
            let config: BaxterConfig
            if FileManager.default.fileExists(atPath: configURL.path) {
                let text = try String(contentsOf: configURL, encoding: .utf8)
                config = decodeConfig(from: text)
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
            let text = encodeConfig(config)

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
        validationErrors = validationIssues(for: draftConfig())
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
        s3Endpoint = config.s3Endpoint
        s3Region = config.s3Region
        s3Bucket = config.s3Bucket
        s3Prefix = config.s3Prefix
        keychainService = config.keychainService
        keychainAccount = config.keychainAccount
    }

    private func buildConfigForSave() throws -> BaxterConfig {
        let config = draftConfig()
        let errors = validationIssues(for: config)
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
            s3Endpoint: s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            s3Region: s3Region.trimmingCharacters(in: .whitespacesAndNewlines),
            s3Bucket: s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            s3Prefix: s3Prefix.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainService: keychainService.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainAccount: keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if config.s3Prefix.isEmpty {
            config.s3Prefix = "baxter/"
        }
        if !config.s3Prefix.hasSuffix("/") {
            config.s3Prefix += "/"
        }

        return config
    }

    private func validationIssues(for config: BaxterConfig) -> [SettingsField: String] {
        var errors: [SettingsField: String] = [:]

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

    private func decodeConfig(from text: String) -> BaxterConfig {
        var config = BaxterConfig.default
        var section = ""
        var collectingBackupRoots = false
        var backupRootsBuffer = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if collectingBackupRoots {
                backupRootsBuffer += "\n" + rawLine
                if trimmed.contains("]") {
                    config.backupRoots = parseQuotedArray(from: backupRootsBuffer)
                    collectingBackupRoots = false
                }
                continue
            }

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast())
                continue
            }

            if section.isEmpty, trimmed.hasPrefix("backup_roots") {
                guard let equalsIndex = rawLine.firstIndex(of: "=") else { continue }
                let rhs = String(rawLine[rawLine.index(after: equalsIndex)...])
                backupRootsBuffer = rhs
                if rhs.contains("]") {
                    config.backupRoots = parseQuotedArray(from: backupRootsBuffer)
                } else {
                    collectingBackupRoots = true
                }
                continue
            }

            guard let (key, value) = parseQuotedAssignment(from: trimmed) else {
                continue
            }

            switch (section, key) {
            case ("", "schedule"):
                config.schedule = BackupSchedule(rawValue: value) ?? .daily
            case ("s3", "endpoint"):
                config.s3Endpoint = value
            case ("s3", "region"):
                config.s3Region = value
            case ("s3", "bucket"):
                config.s3Bucket = value
            case ("s3", "prefix"):
                config.s3Prefix = value
            case ("encryption", "keychain_service"):
                config.keychainService = value
            case ("encryption", "keychain_account"):
                config.keychainAccount = value
            default:
                break
            }
        }

        if config.s3Prefix.isEmpty {
            config.s3Prefix = "baxter/"
        }
        if !config.s3Prefix.hasSuffix("/") {
            config.s3Prefix += "/"
        }

        return config
    }

    private func encodeConfig(_ config: BaxterConfig) -> String {
        var lines: [String] = []
        lines.append("backup_roots = [")
        for root in config.backupRoots {
            lines.append("  \"\(escapeTomlString(root))\",")
        }
        lines.append("]")
        lines.append("")
        lines.append("schedule = \"\(config.schedule.rawValue)\"")
        lines.append("")
        lines.append("[s3]")
        lines.append("endpoint = \"\(escapeTomlString(config.s3Endpoint))\"")
        lines.append("region = \"\(escapeTomlString(config.s3Region))\"")
        lines.append("bucket = \"\(escapeTomlString(config.s3Bucket))\"")
        lines.append("prefix = \"\(escapeTomlString(config.s3Prefix))\"")
        lines.append("")
        lines.append("[encryption]")
        lines.append("keychain_service = \"\(escapeTomlString(config.keychainService))\"")
        lines.append("keychain_account = \"\(escapeTomlString(config.keychainAccount))\"")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func parseQuotedArray(from text: String) -> [String] {
        var values: [String] = []
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            guard character == "\"" else { continue }
            var value = ""
            var escaped = false

            while let next = iterator.next() {
                if escaped {
                    value.append(unescapeTomlCharacter(next))
                    escaped = false
                    continue
                }
                if next == "\\" {
                    escaped = true
                    continue
                }
                if next == "\"" {
                    break
                }
                value.append(next)
            }
            values.append(value)
        }

        return values
    }

    private func parseQuotedAssignment(from line: String) -> (String, String)? {
        guard let equalsIndex = line.firstIndex(of: "=") else { return nil }

        let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let valuePart = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

        guard valuePart.first == "\"" else { return nil }

        var value = ""
        var escaped = false
        var index = valuePart.index(after: valuePart.startIndex)

        while index < valuePart.endIndex {
            let character = valuePart[index]
            if escaped {
                value.append(unescapeTomlCharacter(character))
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return (key, value)
            } else {
                value.append(character)
            }
            index = valuePart.index(after: index)
        }

        return nil
    }

    private func unescapeTomlCharacter(_ character: Character) -> Character {
        switch character {
        case "n":
            return "\n"
        case "t":
            return "\t"
        case "r":
            return "\r"
        case "\"":
            return "\""
        case "\\":
            return "\\"
        default:
            return character
        }
    }

    private func escapeTomlString(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        return escaped
    }
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
