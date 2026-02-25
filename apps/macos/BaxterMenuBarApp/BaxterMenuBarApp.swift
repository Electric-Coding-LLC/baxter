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
                VStack(alignment: .leading, spacing: 6) {
                    statusDotLine(daemonStatusHeadline, tint: daemonStatusTint)
                    statusDotLine(backupStatusHeadline, tint: backupStatusTint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    inlineMetricLine(label: "Last Backup", value: lastBackupText)
                    inlineMetricLine(label: "Next Backup", value: nextBackupText)
                    if let lastError = model.lastError, !lastError.isEmpty {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                    menuActionButton(
                        "Run Backup",
                        systemImage: "play.fill",
                        isEnabled: !(model.state == .running || model.isLifecycleBusy || model.daemonServiceState != .running)
                    ) {
                        model.runBackup()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    menuActionButton("Restore...") {
                        openRestoreWindow()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    menuActionButton("Settings...") {
                        openSettingsWindow()
                    }
                    menuActionButton("Diagnostics...") {
                        openDiagnosticsWindow()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !model.isDaemonReachable {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Baxter is not reachable.")
                        Text("Use Start Baxter to bootstrap launchd, or inspect launchctl output.")
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

                VStack(spacing: 2) {
                    menuActionButton(
                        "Start Baxter",
                        systemImage: "play.circle",
                        isEnabled: !(model.isLifecycleBusy || model.daemonServiceState == .running)
                    ) {
                        model.startDaemon()
                    }

                    menuActionButton(
                        "Stop Baxter",
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
            .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Settings {
            BaxterSettingsView(model: settingsModel, statusModel: model)
        }

        Window("Restore", id: "restore") {
            BaxterRestoreView(statusModel: model)
        }

        Window("Diagnostics", id: "diagnostics") {
            BaxterDiagnosticsView(statusModel: model, settingsModel: settingsModel)
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

    private func openDiagnosticsWindow() {
        closeMenuBarPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            openWindow(id: "diagnostics")
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

    private var daemonStatusHeadline: String {
        switch model.daemonServiceState {
        case .running:
            return model.isDaemonReachable ? "Baxter is running" : "Baxter is running (no IPC)"
        case .stopped:
            return "Baxter is stopped"
        case .unknown:
            return "Baxter status unknown"
        }
    }

    private var daemonStatusTint: Color {
        switch model.daemonServiceState {
        case .running:
            return model.isDaemonReachable ? .green : .orange
        case .stopped:
            return .orange
        case .unknown:
            return .secondary
        }
    }

    private var backupStatusHeadline: String {
        "Backup is \(backupStatusWord)"
    }

    private var backupStatusWord: String {
        guard isDaemonOperational else { return "unavailable" }
        if model.state == .running {
            return "running"
        }
        if model.state == .failed {
            return "failed"
        }
        return "idle"
    }

    private var backupStatusTint: Color {
        guard isDaemonOperational else { return .orange }
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

    private func metricRow(label: String, value: String, valueFont: Font = .body.weight(.medium)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(valueFont)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private struct MenuLinkButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            MenuLinkButtonBody(configuration: configuration)
        }
    }

    private struct MenuLinkButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hovering in
                    isHovered = isEnabled ? hovering : false
                }
                .foregroundStyle(foregroundColor)
                .animation(.easeOut(duration: 0.10), value: isHovered)
        }

        private var isActive: Bool {
            guard isEnabled else { return false }
            return configuration.isPressed || isHovered
        }

        private var backgroundColor: Color {
            isActive ? Color.accentColor : .clear
        }

        private var foregroundColor: Color {
            if !isEnabled {
                return .secondary
            }
            return isActive ? .white : .primary
        }
    }
}

struct BaxterDiagnosticsView: View {
    @ObservedObject var statusModel: BackupStatusModel
    @ObservedObject var settingsModel: BaxterSettingsModel
    @State private var diagnosticsMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Diagnostics")
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Config path: \(settingsModel.configURL.path)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Baxter state: \(statusModel.daemonServiceState.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("IPC reachable: \(statusModel.isDaemonReachable ? "yes" : "no")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Backup state: \(statusModel.state.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Verify state: \(statusModel.verifyState.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let lastError = statusModel.lastError, !lastError.isEmpty {
                        Text("Last backup error: \(lastError)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    if let lastVerifyError = statusModel.lastVerifyError, !lastVerifyError.isEmpty {
                        Text("Last verify error: \(lastVerifyError)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    if let lastRestoreError = statusModel.lastRestoreError, !lastRestoreError.isEmpty {
                        Text("Last restore error: \(lastRestoreError)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    Text("Daemon logs:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("  \(daemonOutLogPath)")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    Text("  \(daemonErrLogPath)")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button("Run Verify") {
                    statusModel.runVerify()
                }
                .disabled(statusModel.verifyState == .running || statusModel.isLifecycleBusy || statusModel.daemonServiceState != .running)

                Button("Copy Diagnostics Summary") {
                    copyDiagnosticsSummary()
                }
                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 680, minHeight: 460)
    }

    private var daemonOutLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("baxterd.out.log")
            .path
    }

    private var daemonErrLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("baxterd.err.log")
            .path
    }

    private func copyDiagnosticsSummary() {
        let summary = [
            "config_path=\(settingsModel.configURL.path)",
            "daemon_state=\(statusModel.daemonServiceState.rawValue)",
            "ipc_reachable=\(statusModel.isDaemonReachable ? "yes" : "no")",
            "backup_state=\(statusModel.state.rawValue)",
            "verify_state=\(statusModel.verifyState.rawValue)",
            "last_backup_error=\(statusModel.lastError ?? "")",
            "last_verify_error=\(statusModel.lastVerifyError ?? "")",
            "last_restore_error=\(statusModel.lastRestoreError ?? "")",
            "daemon_out_log=\(daemonOutLogPath)",
            "daemon_err_log=\(daemonErrLogPath)",
        ].joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        diagnosticsMessage = "Copied."
    }
}
