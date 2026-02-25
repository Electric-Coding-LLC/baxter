import AppKit
import Darwin
import Foundation
import SwiftUI

@main
struct BaxterMenuBarApp: App {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = BackupStatusModel(notificationDispatcher: UNUserNotificationDispatcher())
    @StateObject private var settingsModel = BaxterSettingsModel()

    var body: some Scene {
        MenuBarExtra("Baxter", systemImage: iconName) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        statusSummaryLine(
                            title: "Daemon",
                            activity: daemonActivityStatus,
                            activityTint: daemonActivityTint,
                            health: daemonHealthStatus,
                            healthTint: daemonHealthTint
                        )
                        statusSummaryLine(
                            title: "Backup",
                            activity: backupActivityStatus,
                            activityTint: backupActivityTint,
                            health: backupHealthStatus,
                            healthTint: backupHealthTint
                        )
                        statusSummaryLine(
                            title: "Verify",
                            activity: verifyActivityStatus,
                            activityTint: verifyActivityTint,
                            health: verifyHealthStatus,
                            healthTint: verifyHealthTint
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Baxter")
                        .font(.headline.weight(.semibold))
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Last backup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(lastBackupText)
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Next backup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(nextBackupText)
                        .font(.body.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Last verify")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(lastVerifyText)
                        .font(.body.weight(.medium))
                    Text(nextVerifyText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if model.lastVerifyChecked > 0 || model.lastVerifyMissing > 0 || model.lastVerifyReadErrors > 0 || model.lastVerifyDecryptErrors > 0 || model.lastVerifyChecksumErrors > 0 {
                        Text(verifySummaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let lastError = model.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                if let lastVerifyError = model.lastVerifyError, !lastVerifyError.isEmpty {
                    Label(lastVerifyError, systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                if !model.isDaemonReachable {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Daemon is not reachable.")
                        Text("Use Start Daemon to bootstrap launchd, or inspect launchctl output.")
                            .font(.caption)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                if let lifecycleMessage = model.lifecycleMessage {
                    Label(lifecycleMessage, systemImage: "bolt.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                Divider()

                Button {
                    model.runBackup()
                } label: {
                    Label("Run Backup", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state == .running || model.isLifecycleBusy || model.daemonServiceState != .running)

                Button {
                    model.runVerify()
                } label: {
                    Label("Run Verify", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.verifyState == .running || model.isLifecycleBusy || model.daemonServiceState != .running)

                HStack(spacing: 8) {
                    Button {
                        model.startDaemon()
                    } label: {
                        Label("Start Daemon", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(model.isLifecycleBusy || model.daemonServiceState == .running)

                    Button {
                        model.stopDaemon()
                    } label: {
                        Label("Stop Daemon", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(model.isLifecycleBusy || model.daemonServiceState == .stopped)
                }

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            model.refreshStatus()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                    Button {
                        openSettingsWindow()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }

                    HStack(spacing: 8) {
                    Button {
                        openRestoreWindow()
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward.square")
                            .frame(maxWidth: .infinity)
                    }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        Button {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            Label("Quit", systemImage: "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(14)
            .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Settings {
            BaxterSettingsView(model: settingsModel, statusModel: model)
        }

        Window("Restore", id: "restore") {
            BaxterRestoreView(statusModel: model)
        }
    }

    private var iconName: String {
        model.state == .running ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive"
    }

    private func openSettingsWindow() {
        closeMenuBarPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            openSettings()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func openRestoreWindow() {
        closeMenuBarPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            openWindow(id: "restore")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func closeMenuBarPanel() {
        if let keyWindow = NSApplication.shared.keyWindow, isMenuBarPanelWindow(keyWindow) {
            keyWindow.orderOut(nil)
        }
        _ = NSApplication.shared.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
    }

    private func isMenuBarPanelWindow(_ window: NSWindow) -> Bool {
        let className = NSStringFromClass(type(of: window))
        if className.contains("MenuBarExtra") {
            return true
        }
        if window.level == .statusBar || window.level == .popUpMenu {
            return true
        }
        return className.contains("Panel")
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
        model.daemonServiceState == .running && model.isDaemonReachable
    }

    private var daemonActivityStatus: String {
        model.daemonServiceState.rawValue
    }

    private var daemonActivityTint: Color {
        model.daemonServiceState == .running ? .blue : .secondary
    }

    private var daemonHealthStatus: String {
        switch model.daemonServiceState {
        case .running:
            return model.isDaemonReachable ? "Healthy" : "No IPC"
        case .stopped:
            return "Stopped"
        case .unknown:
            return "Unknown"
        }
    }

    private var daemonHealthTint: Color {
        switch model.daemonServiceState {
        case .running:
            return model.isDaemonReachable ? .green : .orange
        case .stopped:
            return .orange
        case .unknown:
            return .secondary
        }
    }

    private var backupActivityStatus: String {
        isDaemonOperational ? model.state.rawValue : "Unavailable"
    }

    private var backupActivityTint: Color {
        guard isDaemonOperational else { return .secondary }
        return model.state == .running ? Color.blue : Color.secondary
    }

    private var backupHealthStatus: String {
        guard isDaemonOperational else { return "Unavailable" }
        if model.state == .failed || !(model.lastError ?? "").isEmpty {
            return "Failed"
        }
        if model.lastBackupAt != nil {
            return "Healthy"
        }
        return "Not run"
    }

    private var backupHealthTint: Color {
        guard isDaemonOperational else { return .orange }
        if model.state == .failed || !(model.lastError ?? "").isEmpty {
            return .red
        }
        if model.lastBackupAt != nil {
            return .green
        }
        return .secondary
    }

    private var verifyActivityStatus: String {
        isDaemonOperational ? model.verifyState.rawValue : "Unavailable"
    }

    private var verifyActivityTint: Color {
        guard isDaemonOperational else { return .secondary }
        return model.verifyState == .running ? Color.blue : Color.secondary
    }

    private var verifyHealthStatus: String {
        guard isDaemonOperational else { return "Unavailable" }
        if model.verifyState == .failed || !(model.lastVerifyError ?? "").isEmpty {
            return "Failed"
        }
        if model.lastVerifyAt != nil {
            return "Healthy"
        }
        return "Not run"
    }

    private var verifyHealthTint: Color {
        guard isDaemonOperational else { return .orange }
        if model.verifyState == .failed || !(model.lastVerifyError ?? "").isEmpty {
            return .red
        }
        if model.lastVerifyAt != nil {
            return .green
        }
        return .secondary
    }

    private var lastVerifyText: String {
        if let lastVerifyAt = model.lastVerifyAt {
            return lastVerifyAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "Never"
    }

    private var verifySummaryText: String {
        "checked \(model.lastVerifyChecked), ok \(model.lastVerifyOK), missing \(model.lastVerifyMissing), read \(model.lastVerifyReadErrors), decrypt \(model.lastVerifyDecryptErrors), checksum \(model.lastVerifyChecksumErrors)"
    }

    private var nextVerifyText: String {
        if let nextVerifyAt = model.nextVerifyAt {
            return "Next verify \(nextVerifyAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Verify schedule manual"
    }

    private func statusSummaryLine(
        title: String,
        activity: String,
        activityTint: Color,
        health: String,
        healthTint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Text("\(title):")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(activity)
                .font(.body.weight(.semibold))
                .foregroundStyle(activityTint)
            Text("•")
                .foregroundStyle(.secondary)
            Text(health)
                .font(.body.weight(.semibold))
                .foregroundStyle(healthTint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
    }
}
