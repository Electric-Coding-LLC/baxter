import Foundation

extension BackupStatusModel {
    func decodeDaemonError(data: Data, statusCode: Int) -> IPCError {
        if let payload = try? JSONDecoder().decode(DaemonErrorPayload.self, from: data) {
            return IPCError.server(code: payload.code, message: payload.message, statusCode: statusCode)
        }
        return IPCError.badStatus(statusCode)
    }

    func applyIPCAuthHeader(to request: inout URLRequest) {
        guard let token = ipcToken, !token.isEmpty else {
            return
        }
        request.setValue(token, forHTTPHeaderField: "X-Baxter-Token")
    }

    func apply(_ status: DaemonStatus) {
        let previousState = state
        let previousVerifyState = verifyState
        let previousLastBackupAt = lastBackupAt
        let previousLastVerifyAt = lastVerifyAt

        switch status.state.lowercased() {
        case "running":
            state = .running
        case "failed":
            state = .failed
        default:
            state = .idle
        }
        switch (status.verifyState ?? "idle").lowercased() {
        case "running":
            verifyState = .running
        case "failed":
            verifyState = .failed
        default:
            verifyState = .idle
        }

        if let raw = status.lastBackupAt {
            lastBackupAt = iso8601.date(from: raw)
        } else {
            lastBackupAt = nil
        }
        if let raw = status.nextScheduledAt {
            nextScheduledAt = iso8601.date(from: raw)
        } else {
            nextScheduledAt = nil
        }
        backupUploaded = status.backupUploaded ?? 0
        backupTotal = status.backupTotal ?? 0
        backupCurrentPath = status.backupCurrentPath
        if let raw = status.lastRestoreAt {
            lastRestoreAt = iso8601.date(from: raw)
        } else {
            lastRestoreAt = nil
        }
        if let raw = status.lastVerifyAt {
            lastVerifyAt = iso8601.date(from: raw)
        } else {
            lastVerifyAt = nil
        }
        if let raw = status.nextVerifyAt {
            nextVerifyAt = iso8601.date(from: raw)
        } else {
            nextVerifyAt = nil
        }
        lastRestorePath = status.lastRestorePath
        lastRestoreError = status.lastRestoreError
        lastVerifyError = status.lastVerifyError
        lastVerifyChecked = status.lastVerifyChecked ?? 0
        lastVerifyOK = status.lastVerifyOK ?? 0
        lastVerifyMissing = status.lastVerifyMissing ?? 0
        lastVerifyReadErrors = status.lastVerifyReadErrors ?? 0
        lastVerifyDecryptErrors = status.lastVerifyDecryptErrors ?? 0
        lastVerifyChecksumErrors = status.lastVerifyChecksumErrors ?? 0
        lastError = status.lastError

        dispatchStatusTransitionNotifications(
            previousState: previousState,
            previousVerifyState: previousVerifyState,
            previousLastBackupAt: previousLastBackupAt,
            previousLastVerifyAt: previousLastVerifyAt
        )
    }

    func shouldAttemptAutoRecovery(now: Date = Date()) -> Bool {
        guard let lastAutoRecoveryAttemptAt else {
            return true
        }
        return now.timeIntervalSince(lastAutoRecoveryAttemptAt) >= autoRecoveryCooldown
    }

    func scheduleNextAutomaticRefresh(now: Date = Date()) {
        nextAutomaticRefreshAt = now.addingTimeInterval(pollingInterval)
    }

    func updateConnectionStateForIPCFailure(now: Date) {
        if ipcUnavailableSince == nil {
            ipcUnavailableSince = now
        }
        let elapsed = now.timeIntervalSince(ipcUnavailableSince ?? now)
        if elapsed < ipcConnectingGracePeriod {
            connectionState = .connecting
            return
        }
        if elapsed < ipcUnavailableEscalationPeriod {
            connectionState = .delayed
            return
        }
        connectionState = .unavailable
    }

    func clearStaleLifecycleMessageIfNeeded(for launchdState: DaemonServiceState) {
        guard launchdState == .stopped, !isLifecycleBusy else {
            return
        }
        guard let lifecycleMessage else {
            return
        }
        if lifecycleMessage.hasPrefix("Daemon ") {
            self.lifecycleMessage = nil
        }
    }

    func dispatchStatusTransitionNotifications(
        previousState: State,
        previousVerifyState: VerifyState,
        previousLastBackupAt: Date?,
        previousLastVerifyAt: Date?
    ) {
        if state == .failed && previousState != .failed {
            notificationDispatcher.sendNotification(
                title: "Baxter backup failed",
                body: lastError ?? "A backup run failed. Open Baxter for details."
            )
        }
        if verifyState == .failed && previousVerifyState != .failed {
            notificationDispatcher.sendNotification(
                title: "Baxter verify failed",
                body: lastVerifyError ?? "A verify run failed. Open Baxter for details."
            )
        }
        guard notifyOnSuccess else {
            return
        }
        if previousState == .running,
            state == .idle,
            let backupAt = lastBackupAt,
            backupAt != previousLastBackupAt {
            notificationDispatcher.sendNotification(
                title: "Baxter backup completed",
                body: "Backup finished successfully at \(backupAt.formatted(date: .abbreviated, time: .shortened))."
            )
        }
        if previousVerifyState == .running,
            verifyState == .idle,
            let verifyAt = lastVerifyAt,
            verifyAt != previousLastVerifyAt {
            notificationDispatcher.sendNotification(
                title: "Baxter verify completed",
                body: "Verify finished successfully at \(verifyAt.formatted(date: .abbreviated, time: .shortened))."
            )
        }
    }
}
