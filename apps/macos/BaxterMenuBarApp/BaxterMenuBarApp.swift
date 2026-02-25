import AppKit
import Darwin
import Foundation
import SwiftUI

@main
struct BaxterMenuBarApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = BackupStatusModel(notificationDispatcher: UNUserNotificationDispatcher())
    @StateObject private var settingsModel = BaxterSettingsModel()
    @StateObject private var workspaceRouter = BaxterWorkspaceRouter()

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
                        openWorkspace(section: .restore)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    menuActionButton("Settings...") {
                        openWorkspace(section: .settings)
                    }
                    menuActionButton("Diagnostics...") {
                        openWorkspace(section: .diagnostics)
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

        Window("Baxter", id: "workspace") {
            BaxterWorkspaceView(
                statusModel: model,
                settingsModel: settingsModel,
                router: workspaceRouter
            )
        }
    }

    private var iconName: String {
        model.state == .running ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive"
    }

    private func openWorkspace(section: BaxterWorkspaceSection) {
        workspaceRouter.selectedSection = section
        closeMenuBarPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            openWindow(id: "workspace")
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

enum BaxterWorkspaceSection: String, CaseIterable, Hashable, Identifiable {
    case restore
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restore:
            return "Restore"
        case .settings:
            return "Settings"
        case .diagnostics:
            return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .restore:
            return "Browse snapshots and restore files with confidence."
        case .settings:
            return "Tune backup, verify, storage, and encryption behavior."
        case .diagnostics:
            return "Inspect runtime state and export support bundles."
        }
    }

    var systemImage: String {
        switch self {
        case .restore:
            return "externaldrive.badge.timemachine"
        case .settings:
            return "slider.horizontal.3"
        case .diagnostics:
            return "stethoscope"
        }
    }
}

@MainActor
final class BaxterWorkspaceRouter: ObservableObject {
    @Published var selectedSection: BaxterWorkspaceSection = .restore
}

struct BaxterWorkspaceView: View {
    @ObservedObject var statusModel: BackupStatusModel
    @ObservedObject var settingsModel: BaxterSettingsModel
    @ObservedObject var router: BaxterWorkspaceRouter

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Baxter")
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                    Text("Workspace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

                List(BaxterWorkspaceSection.allCases, selection: $router.selectedSection) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(router.selectedSection.title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(router.selectedSection.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Group {
                    switch router.selectedSection {
                    case .restore:
                        BaxterRestoreView(statusModel: statusModel, embedded: true)
                    case .settings:
                        BaxterSettingsView(model: settingsModel, statusModel: statusModel, embedded: true)
                    case .diagnostics:
                        BaxterDiagnosticsView(statusModel: statusModel, settingsModel: settingsModel, embedded: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1120, minHeight: 720)
    }
}

struct BaxterDiagnosticsView: View {
    @ObservedObject var statusModel: BackupStatusModel
    @ObservedObject var settingsModel: BaxterSettingsModel
    var embedded: Bool = false
    @State private var diagnosticsMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded {
                Text("Diagnostics")
                    .font(.title2.weight(.semibold))
            }

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
                Button("Export Diagnostics Bundle") {
                    exportDiagnosticsBundle()
                }
                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(embedded ? 12 : 16)
        .frame(minWidth: embedded ? nil : 680, minHeight: embedded ? nil : 460)
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

    private func exportDiagnosticsBundle() {
        let bundle = DiagnosticsBundleBuilder.makeBundle(
            configPath: settingsModel.configURL.path,
            daemonState: statusModel.daemonServiceState.rawValue,
            ipcReachable: statusModel.isDaemonReachable,
            backupState: statusModel.state.rawValue,
            verifyState: statusModel.verifyState.rawValue,
            lastBackupError: statusModel.lastError,
            lastVerifyError: statusModel.lastVerifyError,
            lastRestoreError: statusModel.lastRestoreError,
            daemonOutLogPath: daemonOutLogPath,
            daemonErrLogPath: daemonErrLogPath
        )

        let outputDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("baxter")
            .appendingPathComponent("diagnostics")

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let outputPath = outputDir.appendingPathComponent(bundle.fileName)
            try bundle.contents.write(to: outputPath, atomically: true, encoding: .utf8)
            diagnosticsMessage = "Saved bundle: \(outputPath.path)"
        } catch {
            diagnosticsMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

struct DiagnosticsBundle {
    let fileName: String
    let contents: String
}

enum DiagnosticsBundleBuilder {
    static func makeBundle(
        configPath: String,
        daemonState: String,
        ipcReachable: Bool,
        backupState: String,
        verifyState: String,
        lastBackupError: String?,
        lastVerifyError: String?,
        lastRestoreError: String?,
        daemonOutLogPath: String,
        daemonErrLogPath: String,
        now: Date = Date()
    ) -> DiagnosticsBundle {
        let timestamp = iso8601Timestamp(for: now)
        let fileName = "baxter-diagnostics-\(safeTimestamp(for: now)).txt"
        let sanitizedConfig = sanitizeConfig(atPath: configPath)
        let outLogTail = redactSensitiveContent(readLogTail(path: daemonOutLogPath))
        let errLogTail = redactSensitiveContent(readLogTail(path: daemonErrLogPath))

        let content = [
            "# Baxter Diagnostics Bundle",
            "generated_at=\(timestamp)",
            "",
            "[status]",
            "config_path=\(configPath)",
            "daemon_state=\(daemonState)",
            "ipc_reachable=\(ipcReachable ? "yes" : "no")",
            "backup_state=\(backupState)",
            "verify_state=\(verifyState)",
            "last_backup_error=\(redactSensitiveContent(lastBackupError ?? ""))",
            "last_verify_error=\(redactSensitiveContent(lastVerifyError ?? ""))",
            "last_restore_error=\(redactSensitiveContent(lastRestoreError ?? ""))",
            "",
            "[config_sanitized]",
            sanitizedConfig,
            "",
            "[daemon_out_log_tail]",
            outLogTail,
            "",
            "[daemon_err_log_tail]",
            errLogTail,
        ].joined(separator: "\n")

        return DiagnosticsBundle(fileName: fileName, contents: content)
    }

    static func redactSensitiveContent(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { redactSensitiveLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func sanitizeConfig(atPath path: String) -> String {
        guard let configText = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "<config unavailable>"
        }
        return configText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { sanitizeConfigLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func sanitizeConfigLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") || trimmed.isEmpty {
            return line
        }
        guard let separatorIndex = line.firstIndex(of: "=") else {
            return redactSensitiveLine(line)
        }

        let keyPart = String(line[..<separatorIndex])
        let key = keyPart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isSensitiveKey(key) {
            return "\(keyPart)= \"[REDACTED]\""
        }
        return redactSensitiveLine(line)
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        key.contains("passphrase") ||
            key.contains("token") ||
            key.contains("secret") ||
            key.contains("access_key")
    }

    private static func redactSensitiveLine(_ line: String) -> String {
        let lower = line.lowercased()
        let markers = [
            "baxter_passphrase",
            "x-baxter-token",
            "authorization",
            "ipc_token",
            "api_token",
            "access_token",
            "aws_secret_access_key",
            "aws_access_key_id",
        ]
        for marker in markers {
            guard let markerRange = lower.range(of: marker) else {
                continue
            }
            let suffix = line[markerRange.upperBound...]
            guard let separator = suffix.firstIndex(where: { $0 == "=" || $0 == ":" }) else {
                continue
            }
            let tokenStart = line.index(after: separator)
            let leadingWhitespace = line[tokenStart...].prefix { $0 == " " || $0 == "\t" }
            let prefix = line[..<tokenStart]
            return "\(prefix)\(leadingWhitespace)[REDACTED]"
        }
        return line
    }

    private static func readLogTail(path: String, maxBytes: Int = 16 * 1024, maxLines: Int = 120) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "<log unavailable>"
        }
        if data.isEmpty {
            return "<log empty>"
        }

        let tailBytes = data.count > maxBytes ? Data(data.suffix(maxBytes)) : data
        let decoded = String(decoding: tailBytes, as: UTF8.self)
        let lines = decoded.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines {
            return lines.suffix(maxLines).joined(separator: "\n")
        }
        return decoded
    }

    private static func safeTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func iso8601Timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
