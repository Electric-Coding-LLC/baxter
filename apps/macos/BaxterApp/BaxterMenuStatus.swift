import Foundation

@MainActor
struct BaxterMenuStatus {
    let model: BackupStatusModel
    private let needsInitialSetup: Bool
    private let maxWarningLength = 90

    init(model: BackupStatusModel) {
        self.model = model
        needsInitialSetup = model.connectionState == .stopped && !model.hasConfigFile()
    }

    var statusLines: [String] {
        var lines = [daemonHeadline, backupHeadline]
        if let progressDetail {
            lines.append(progressDetail)
        }
        lines.append("Last Backup: \(lastBackupText)")
        lines.append("Next Backup: \(nextBackupText)")
        return lines
    }

    var warnings: [String] {
        var messages: [String] = []
        if let lifecycleFailureMessage {
            messages.append(lifecycleFailureMessage)
        }
        return (messages + backupWarnings).map(shortened)
    }

    private var backupWarnings: [String] {
        var messages: [String] = []
        guard model.connectionState == .connected else {
            return messages
        }
        if model.state == .failed {
            if let lastError = model.lastError, !lastError.isEmpty {
                messages.append("Backup failed: \(lastError)")
            } else {
                messages.append("The last backup failed. Open Diagnostics for details.")
            }
        }
        if model.backupOverdue {
            messages.append("No successful backup in \(model.daysSinceLastBackup.formatted()) days.")
        }
        if model.lastBackupSkippedCount == 1 {
            messages.append("The last backup skipped 1 file it could not read.")
        } else if model.lastBackupSkippedCount > 1 {
            messages.append("The last backup skipped \(model.lastBackupSkippedCount.formatted()) files it could not read.")
        }
        return messages
    }

    var canRunBackup: Bool {
        model.state != .running && !model.isLifecycleBusy && isDaemonOperational
    }

    var runBackupDisabledReason: String? {
        if model.state == .running {
            return nil
        }
        if model.isLifecycleBusy {
            return nil
        }
        if needsInitialSetup {
            return "Open Settings to set up your first backup."
        }
        switch model.connectionState {
        case .connected, .connecting, .delayed, .unknown:
            return nil
        case .unavailable:
            return "Baxter can't reach its background service. Try Background Service > Restart Baxter."
        case .stopped:
            return "Start Baxter to run backups."
        }
    }

    var canStartDaemon: Bool {
        !model.isLifecycleBusy && model.daemonServiceState != .running
    }

    var canStopDaemon: Bool {
        !model.isLifecycleBusy && model.daemonServiceState != .stopped
    }

    var canRestartDaemon: Bool {
        !model.isLifecycleBusy && model.daemonServiceState == .running
    }

    var startTitle: String {
        model.activeLifecycleAction == .starting ? "Starting Baxter…" : "Start Baxter"
    }

    var stopTitle: String {
        model.activeLifecycleAction == .stopping ? "Stopping Baxter…" : "Stop Baxter"
    }

    private func shortened(_ message: String) -> String {
        let singleLine = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard singleLine.count > maxWarningLength else {
            return singleLine
        }
        return String(singleLine.prefix(maxWarningLength - 1)) + "…"
    }

    private var isDaemonOperational: Bool {
        model.connectionState == .connected && model.daemonServiceState == .running && model.isDaemonReachable
    }

    private var daemonHeadline: String {
        if model.isLifecycleBusy {
            switch model.activeLifecycleAction {
            case .starting:
                return "Baxter is starting"
            case .stopping:
                return "Baxter is stopping"
            case .applyingConfig:
                return "Baxter is applying settings"
            case .none:
                break
            }
        }
        switch model.connectionState {
        case .connected:
            return "Baxter is running"
        case .connecting:
            return "Baxter is starting"
        case .delayed:
            return "Baxter is starting (slower than usual)"
        case .unavailable:
            return "Baxter is running (connection failed)"
        case .stopped:
            return needsInitialSetup ? "Baxter is not set up" : "Baxter is stopped"
        case .unknown:
            return "Checking Baxter status"
        }
    }

    private var backupHeadline: String {
        if model.connectionState == .connected, model.state == .running, model.backupTotal > 0 {
            return "Backup is running (\(model.backupUploaded.formatted())/\(model.backupTotal.formatted()))"
        }
        return "Backup is \(backupStatusWord)"
    }

    private var backupStatusWord: String {
        if needsInitialSetup {
            return "not set up"
        }
        switch model.connectionState {
        case .connecting, .delayed:
            return "waiting for connection"
        case .unavailable, .stopped, .unknown:
            return "unavailable"
        case .connected:
            break
        }
        switch model.state {
        case .running:
            return "running"
        case .failed:
            return "failed"
        case .idle:
            return "idle"
        }
    }

    private var progressDetail: String? {
        guard model.connectionState == .connected, model.state == .running else {
            return nil
        }
        return model.backupTotal > 0 ? "Uploading changed files" : "Scanning files for changes"
    }

    private var lastBackupText: String {
        model.lastBackupAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }

    private var nextBackupText: String {
        model.nextScheduledAt?.formatted(date: .abbreviated, time: .shortened) ?? "Manual"
    }

    private var lifecycleFailureMessage: String? {
        guard let message = model.lifecycleMessage else {
            return nil
        }
        let lowered = message.lowercased()
        let failurePrefixes = ["start failed:", "stop failed:", "apply failed:", "auto-start failed:", "auto-restart failed:"]
        return failurePrefixes.contains(where: lowered.hasPrefix) ? message : nil
    }
}
