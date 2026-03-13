import Foundation
import Security

enum KeychainPassphraseStore {
    static func store(passphrase: String, service: String, account: String) async throws {
        let trimmedPassphrase = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedService = service.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPassphrase.isEmpty else {
            throw KeychainPassphraseStoreError.missingPassphrase
        }
        guard !trimmedService.isEmpty else {
            throw KeychainPassphraseStoreError.missingService
        }
        guard !trimmedAccount.isEmpty else {
            throw KeychainPassphraseStoreError.missingAccount
        }

        try await Task.detached(priority: .userInitiated) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: trimmedService,
                kSecAttrAccount as String: trimmedAccount,
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: Data(trimmedPassphrase.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]

            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess {
                return
            }
            if updateStatus != errSecItemNotFound {
                throw KeychainPassphraseStoreError.osStatus(updateStatus)
            }

            var createItem = query
            for (key, value) in attributes {
                createItem[key] = value
            }
            let createStatus = SecItemAdd(createItem as CFDictionary, nil)
            guard createStatus == errSecSuccess else {
                throw KeychainPassphraseStoreError.osStatus(createStatus)
            }
        }.value
    }
}

private enum KeychainPassphraseStoreError: LocalizedError {
    case missingPassphrase
    case missingService
    case missingAccount
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingPassphrase:
            return "Passphrase is required."
        case .missingService:
            return "Keychain service is required."
        case .missingAccount:
            return "Keychain account is required."
        case .osStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain update failed: \(message)"
            }
            return "Keychain update failed with status \(status)."
        }
    }
}
