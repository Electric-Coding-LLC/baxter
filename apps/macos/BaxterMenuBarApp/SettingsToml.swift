import Foundation

func decodeBaxterConfig(from text: String) -> BaxterConfig {
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
        case ("", "daily_time"):
            config.dailyTime = value
        case ("", "weekly_day"):
            config.weeklyDay = WeekdayOption(rawValue: value.lowercased()) ?? .sunday
        case ("", "weekly_time"):
            config.weeklyTime = value
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
    if config.dailyTime.isEmpty {
        config.dailyTime = "09:00"
    }
    if config.weeklyTime.isEmpty {
        config.weeklyTime = "09:00"
    }

    return config
}

func encodeBaxterConfig(_ config: BaxterConfig) -> String {
    var lines: [String] = []
    lines.append("backup_roots = [")
    for root in config.backupRoots {
        lines.append("  \"\(escapeTomlString(root))\",")
    }
    lines.append("]")
    lines.append("")
    lines.append("schedule = \"\(config.schedule.rawValue)\"")
    lines.append("daily_time = \"\(escapeTomlString(config.dailyTime))\"")
    lines.append("weekly_day = \"\(config.weeklyDay.rawValue)\"")
    lines.append("weekly_time = \"\(escapeTomlString(config.weeklyTime))\"")
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
