import Foundation

extension BaxterSettingsModel {
    func existingBackupValidationMessage(passphrase: String) -> String? {
        let trimmedPassphrase = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPassphrase.isEmpty {
            return "Enter the encryption passphrase."
        }

        let orderedFields: [SettingsField] = [
            .excludePaths,
            .excludeGlobs,
            .dailyTime,
            .weeklyTime,
            .verifyDailyTime,
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
            if let message = validationErrors[field] {
                return message
            }
        }
        return nil
    }
}
