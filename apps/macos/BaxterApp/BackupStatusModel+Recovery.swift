import Foundation

extension BackupStatusModel {
    func recoverExistingBackup(
        passphrase: String,
        keychainService: String,
        keychainAccount: String
    ) async -> Bool {
        let trimmedPassphrase = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedService = keychainService.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccount = keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPassphrase.isEmpty else {
            recoveryMessage = "Enter the encryption passphrase."
            return false
        }

        isRecoveryBusy = true
        recoveryMessage = nil
        defer { isRecoveryBusy = false }

        do {
            try await storePassphraseInKeychain(trimmedPassphrase, trimmedService, trimmedAccount)
            let bootstrapOutput = try await runRecoveryBootstrap(trimmedPassphrase)
            lifecycleMessage = try await startLaunchd()
            suppressAutoRecoveryUntilManualStart = false
            connectionState = .connecting
            ipcUnavailableSince = nowProvider()

            guard await waitForDaemonConnection(timeout: 8) else {
                recoveryMessage = "Recovery cache is ready, but Baxter did not reconnect in time. Open Diagnostics and retry start."
                return false
            }

            recoveryMessage = recoverySuccessMessage(from: bootstrapOutput)
            return true
        } catch {
            recoveryMessage = "Connect existing backup failed: \(error.localizedDescription)"
            return false
        }
    }

    private func waitForDaemonConnection(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await refreshStatusForRecovery() {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func refreshStatusForRecovery() async -> Bool {
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/status"))
            request.httpMethod = "GET"
            applyIPCAuthHeader(to: &request)

            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }

            let status = try JSONDecoder().decode(DaemonStatus.self, from: data)
            apply(status)
            isDaemonReachable = true
            daemonServiceState = .running
            connectionState = .connected
            ipcUnavailableSince = nil
            return true
        } catch {
            return false
        }
    }

    private func recoverySuccessMessage(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Existing backup connected. Restore is ready."
        }
        return "Existing backup connected. \(trimmed)"
    }
}
