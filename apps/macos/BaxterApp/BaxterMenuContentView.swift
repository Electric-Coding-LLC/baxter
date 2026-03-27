import AppKit
import SwiftUI

struct BaxterMenuContentView: View {
    @ObservedObject var model: BackupStatusModel
    let openWorkspace: (BaxterWorkspaceSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                statusDotLine(daemonStatusHeadline, tint: daemonStatusTint)
                statusDotLine(backupStatusHeadline, tint: backupStatusTint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                inlineMetricLine(label: "Last Backup", value: lastBackupText)
                inlineMetricLine(label: "Next Backup", value: nextBackupText)
                if let backupFailureMessage {
                    Label(backupFailureMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                menuActionButton(
                    "Run Backup",
                    systemImage: "play.fill",
                    isEnabled: !(model.state == .running || model.isLifecycleBusy || !isDaemonOperational)
                ) {
                    model.runBackup()
                }
                if let runBackupDisabledReason {
                    Text(runBackupDisabledReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, menuRowLeadingInset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                menuActionButton("Restore...") {
                    openWorkspace(.restore)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                menuActionButton("Settings...") {
                    openWorkspace(.settings)
                }
                menuActionButton("Diagnostics...") {
                    openWorkspace(.diagnostics)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if shouldShowStatusCard {
                VStack(alignment: .leading, spacing: 6) {
                    Label(statusCardTitle, systemImage: statusCardSystemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusCardForegroundColor)
                    Text(statusCardDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(connectionDiagnosticsLine)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if shouldShowRetryNow {
                            Button("Retry now") {
                                model.refreshStatus()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                        }
                        if shouldShowRestartService {
                            Button("Restart service") {
                                model.startDaemon()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                        }
                        if shouldShowRetryCountdown {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                if let seconds = model.secondsUntilNextAutoRefresh(now: context.date) {
                                    Text("Retrying in \(seconds)s")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusCardBackgroundColor, in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            VStack(spacing: 2) {
                menuActionButton(
                    startButtonTitle,
                    systemImage: "play.circle",
                    isEnabled: !(model.isLifecycleBusy || model.daemonServiceState == .running)
                ) {
                    model.startDaemon()
                }

                menuActionButton(
                    stopButtonTitle,
                    systemImage: "stop.circle",
                    isEnabled: !(model.isLifecycleBusy || model.daemonServiceState == .stopped)
                ) {
                    model.stopDaemon()
                }

                menuActionButton("Refresh", systemImage: "arrow.clockwise") {
                    model.refreshStatus()
                }

                menuActionButton("Quit", systemImage: "xmark") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
    }

    private var lastBackupText: String {
        if let lastBackupAt = model.lastBackupAt {
            return lastBackupAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "Never"
    }

    private var nextBackupText: String {
        if let nextScheduledAt = model.nextScheduledAt {
            return nextScheduledAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "Manual"
    }

    private var isDaemonOperational: Bool {
        model.connectionState == .connected && model.daemonServiceState == .running && model.isDaemonReachable
    }

    private var hasSavedConfig: Bool {
        model.hasConfigFile()
    }

    private var needsInitialSetup: Bool {
        !hasSavedConfig && model.connectionState == .stopped
    }

    private var daemonStatusHeadline: String {
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

    private var daemonStatusTint: Color {
        switch model.connectionState {
        case .connected:
            return .green
        case .connecting, .delayed:
            return .yellow
        case .unavailable:
            return .orange
        case .stopped:
            return .secondary
        case .unknown:
            return .secondary
        }
    }

    private var backupStatusHeadline: String {
        if let progressHeadline {
            return progressHeadline
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
        if model.state == .running {
            return "running"
        }
        if model.state == .failed {
            return "failed"
        }
        return "idle"
    }

    private var backupStatusTint: Color {
        switch model.connectionState {
        case .connected:
            break
        case .connecting, .delayed:
            return .yellow
        case .unavailable:
            return .orange
        case .stopped:
            return .secondary
        case .unknown:
            return .secondary
        }
        if model.state == .running {
            return .blue
        }
        if model.state == .failed {
            return .red
        }
        return .secondary
    }

    private var menuIndicatorSize: CGFloat { 9 }
    private var menuRowSpacing: CGFloat { 8 }
    private var menuRowLeadingInset: CGFloat { 8 }
    private var metricLabelColumnWidth: CGFloat { 86 }

    private var runBackupDisabledReason: String? {
        if model.state == .running {
            if let progressDetail {
                return progressDetail
            }
            return "A backup is already running."
        }
        if model.isLifecycleBusy {
            if model.activeLifecycleAction == .starting {
                return "Backup is unavailable while Baxter is starting."
            }
            return "Backup is temporarily unavailable."
        }
        if needsInitialSetup {
            return "Save settings first to create a backup config."
        }
        switch model.connectionState {
        case .connected:
            return nil
        case .connecting:
            return "Backup is unavailable while Baxter is starting."
        case .delayed:
            return "Baxter is still connecting. Backup will unlock automatically."
        case .unavailable:
            return "Local IPC is unavailable. Retry connection or restart Baxter."
        case .stopped:
            return "Start Baxter to run backups."
        case .unknown:
            return "Waiting for daemon status."
        }
    }

    private var backupFailureMessage: String? {
        guard model.connectionState == .connected, model.state == .failed else {
            return nil
        }
        if let lastError = model.lastError, !lastError.isEmpty {
            return lastError
        }
        return "The last backup failed. Open Diagnostics for details."
    }

    private var progressHeadline: String? {
        guard model.connectionState == .connected, model.state == .running, model.backupTotal > 0 else {
            return nil
        }
        return "Backup is running (\(model.backupUploaded.formatted())/\(model.backupTotal.formatted()))"
    }

    private var progressDetail: String? {
        guard model.connectionState == .connected, model.state == .running else {
            return nil
        }
        guard model.backupTotal > 0 else {
            return "Scanning files for changes."
        }
        if let currentPath = model.backupCurrentPath, !currentPath.isEmpty {
            let fileName = URL(fileURLWithPath: currentPath).lastPathComponent
            if !fileName.isEmpty {
                return "Uploading \(model.backupUploaded.formatted()) of \(model.backupTotal.formatted()): \(fileName)"
            }
        }
        return "Uploading \(model.backupUploaded.formatted()) of \(model.backupTotal.formatted()) changed files."
    }

    private var shouldShowStatusCard: Bool {
        model.connectionState != .connected || model.isLifecycleBusy || hasLifecycleMessage
    }

    private var hasLifecycleMessage: Bool {
        guard let lifecycleMessage = model.lifecycleMessage else {
            return false
        }
        if lifecycleMessage.hasPrefix("Daemon ") || lifecycleMessage == "Config reloaded." {
            return false
        }
        return !lifecycleMessage.isEmpty
    }

    private var statusCardTitle: String {
        if model.isLifecycleBusy {
            switch model.activeLifecycleAction {
            case .starting:
                return "Starting Baxter"
            case .stopping:
                return "Stopping Baxter"
            case .applyingConfig:
                return "Applying Configuration"
            case .none:
                return "Working"
            }
        }
        if hasLifecycleFailure {
            return lifecycleFailureTitle
        }
        if needsInitialSetup {
            return "Setup required"
        }
        switch model.connectionState {
        case .connected:
            return "Baxter is ready"
        case .connecting:
            return "Connecting to Baxter"
        case .delayed:
            return "Still connecting"
        case .unavailable:
            return "Connection failed"
        case .stopped:
            return "Baxter is stopped"
        case .unknown:
            return "Checking Baxter service"
        }
    }

    private var statusCardDetail: String {
        if model.isLifecycleBusy {
            return "Finishing launchd setup and reconnecting to local IPC."
        }
        if hasLifecycleMessage {
            return model.lifecycleMessage ?? ""
        }
        if needsInitialSetup {
            return "Save settings to create the dev config, then start Baxter."
        }
        switch model.connectionState {
        case .connected:
            return "All systems are connected."
        case .connecting:
            return "Local service is initializing (usually under 10 seconds)."
        case .delayed:
            return "Startup is taking longer than usual. Retrying automatically."
        case .unavailable:
            return "Could not connect to local IPC after repeated retries."
        case .stopped:
            return "Use Start Baxter to bootstrap launchd."
        case .unknown:
            return "Reading launchd and IPC status."
        }
    }

    private var statusCardSystemImage: String {
        if hasLifecycleFailure {
            return "exclamationmark.triangle.fill"
        }
        if needsInitialSetup {
            return "slider.horizontal.3"
        }
        switch model.connectionState {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting, .delayed:
            return "arrow.triangle.2.circlepath.circle"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        case .stopped:
            return "pause.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    private var statusCardForegroundColor: Color {
        if hasLifecycleFailure {
            return .red
        }
        if needsInitialSetup {
            return .secondary
        }
        switch model.connectionState {
        case .unavailable:
            return .red
        case .delayed:
            return .orange
        case .stopped:
            return .secondary
        case .connecting:
            return .yellow
        case .connected, .unknown:
            return .secondary
        }
    }

    private var statusCardBackgroundColor: Color {
        if hasLifecycleFailure {
            return Color.red.opacity(0.10)
        }
        if needsInitialSetup {
            return Color.secondary.opacity(0.08)
        }
        switch model.connectionState {
        case .unavailable:
            return Color.red.opacity(0.10)
        case .delayed:
            return Color.orange.opacity(0.10)
        case .stopped:
            return Color.secondary.opacity(0.08)
        case .connecting:
            return Color.yellow.opacity(0.10)
        case .connected, .unknown:
            return Color.secondary.opacity(0.08)
        }
    }

    private var shouldShowRetryNow: Bool {
        if model.isLifecycleBusy {
            return false
        }
        if needsInitialSetup {
            return false
        }
        switch model.connectionState {
        case .delayed, .unavailable, .unknown:
            return true
        case .connecting, .stopped, .connected:
            return false
        }
    }

    private var shouldShowRestartService: Bool {
        !model.isLifecycleBusy && model.connectionState == .unavailable && model.daemonServiceState == .running
    }

    private var shouldShowRetryCountdown: Bool {
        if needsInitialSetup {
            return false
        }
        switch model.connectionState {
        case .connecting, .delayed, .unavailable, .unknown:
            return true
        case .connected, .stopped:
            return false
        }
    }

    private var startButtonTitle: String {
        model.activeLifecycleAction == .starting ? "Starting Baxter..." : "Start Baxter"
    }

    private var stopButtonTitle: String {
        model.activeLifecycleAction == .stopping ? "Stopping Baxter..." : "Stop Baxter"
    }

    private var connectionDiagnosticsLine: String {
        "launchd: \(launchdDiagnosticsWord) | IPC: \(ipcDiagnosticsWord)"
    }

    private var hasLifecycleFailure: Bool {
        guard let lifecycleMessage = model.lifecycleMessage?.lowercased() else {
            return false
        }
        return lifecycleMessage.hasPrefix("start failed:")
            || lifecycleMessage.hasPrefix("stop failed:")
            || lifecycleMessage.hasPrefix("apply failed:")
            || lifecycleMessage.hasPrefix("auto-start failed:")
            || lifecycleMessage.hasPrefix("auto-restart failed:")
    }

    private var lifecycleFailureTitle: String {
        guard let lifecycleMessage = model.lifecycleMessage?.lowercased() else {
            return "Action failed"
        }
        if lifecycleMessage.hasPrefix("start failed:") || lifecycleMessage.hasPrefix("auto-start failed:") || lifecycleMessage.hasPrefix("auto-restart failed:") {
            return "Start failed"
        }
        if lifecycleMessage.hasPrefix("stop failed:") {
            return "Stop failed"
        }
        if lifecycleMessage.hasPrefix("apply failed:") {
            return "Apply failed"
        }
        return "Action failed"
    }

    private var launchdDiagnosticsWord: String {
        switch model.daemonServiceState {
        case .running:
            return "running"
        case .stopped:
            return "stopped"
        case .unknown:
            return "unknown"
        }
    }

    private var ipcDiagnosticsWord: String {
        switch model.connectionState {
        case .connected:
            return "connected"
        case .connecting:
            return "starting"
        case .delayed:
            return "slow"
        case .unavailable:
            return "failed"
        case .stopped:
            return "offline"
        case .unknown:
            return "checking"
        }
    }

    private func statusDotLine(_ text: String, tint: Color) -> some View {
        HStack(spacing: menuRowSpacing) {
            Circle()
                .fill(tint)
                .frame(width: menuIndicatorSize, height: menuIndicatorSize)
            Text(text)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, menuRowLeadingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
    }

    private func inlineMetricLine(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: metricLabelColumnWidth, alignment: .leading)
            Text(value)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, menuRowLeadingInset)
        .font(.body.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func menuActionButton(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: menuRowSpacing) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline)
                }
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.leading, menuRowLeadingInset)
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuLinkButtonStyle())
        .disabled(!isEnabled)
    }
}
