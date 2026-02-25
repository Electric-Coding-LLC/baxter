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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Baxter")
                        .font(.headline.weight(.semibold))

                    VStack(spacing: 6) {
                        headerStatusRow(title: "Backup", value: backupStatusValue, systemImage: backupChipSymbol, tint: backupChipTint)
                        headerStatusRow(title: "Verify", value: verifyStatusValue, systemImage: verifyChipSymbol, tint: verifyChipTint)
                        headerStatusRow(title: "Daemon", value: daemonStatusValue, systemImage: daemonStateSymbol, tint: daemonStateTint)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .fixedSize(horizontal: true, vertical: false)
                }

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

    private var backupStatusValue: String {
        isDaemonOperational ? model.state.rawValue : "Unavailable"
    }

    private var backupChipSymbol: String {
        isDaemonOperational ? statusSymbol : "xmark.circle.fill"
    }

    private var backupChipTint: Color {
        isDaemonOperational ? statusTint : .orange
    }

    private var statusSymbol: String {
        switch model.state {
        case .idle:
            return "pause.circle.fill"
        case .running:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var verifyStateSymbol: String {
        switch model.verifyState {
        case .idle:
            return "checkmark.shield"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.shield"
        }
    }

    private var verifyStateTint: Color {
        switch model.verifyState {
        case .idle:
            return .green
        case .running:
            return .blue
        case .failed:
            return .orange
        }
    }

    private var verifyStatusValue: String {
        isDaemonOperational ? model.verifyState.rawValue : "Unavailable"
    }

    private var verifyChipSymbol: String {
        isDaemonOperational ? verifyStateSymbol : "exclamationmark.shield"
    }

    private var verifyChipTint: Color {
        isDaemonOperational ? verifyStateTint : .orange
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

    private var statusTint: Color {
        switch model.state {
        case .idle:
            return .secondary
        case .running:
            return .blue
        case .failed:
            return .red
        }
    }

    private var daemonStateSymbol: String {
        switch model.daemonServiceState {
        case .running:
            return "dot.circle.fill"
        case .stopped:
            return "pause.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var daemonStateTint: Color {
        switch model.daemonServiceState {
        case .running:
            return .green
        case .stopped:
            return .orange
        case .unknown:
            return .secondary
        }
    }

    private var daemonStatusValue: String {
        if model.daemonServiceState == .running && !model.isDaemonReachable {
            return "Running (No IPC)"
        }
        return model.daemonServiceState.rawValue
    }

    private func headerStatusRow(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Label(value, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(tint)
        }
        .lineLimit(1)
    }
}
