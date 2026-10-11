import AppKit
import Foundation
import SwiftUI

enum BaxterWorkspaceSection: String, CaseIterable, Hashable, Identifiable {
    case restore
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restore:
            return "Restore"
        case .diagnostics:
            return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .restore:
            return "externaldrive.badge.timemachine"
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
    @ObservedObject var windowCoordinator: BaxterWorkspaceWindowCoordinator

    var body: some View {
        NavigationSplitView {
            List(selection: sectionSelection) {
                ForEach(BaxterWorkspaceSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch router.selectedSection {
                case .restore:
                    BaxterRestoreView(statusModel: statusModel, settingsModel: settingsModel)
                case .diagnostics:
                    BaxterDiagnosticsView(statusModel: statusModel, settingsModel: settingsModel)
                }
            }
            .navigationTitle(router.selectedSection.title)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background {
            WorkspaceWindowRegistration(windowCoordinator: windowCoordinator)
                .frame(width: 0, height: 0)
        }
    }

    private var sectionSelection: Binding<BaxterWorkspaceSection?> {
        Binding(
            get: { router.selectedSection },
            set: { section in
                if let section {
                    router.selectedSection = section
                }
            }
        )
    }
}

struct BaxterDiagnosticsView: View {
    @ObservedObject var statusModel: BackupStatusModel
    @ObservedObject var settingsModel: BaxterSettingsModel
    @State private var diagnosticsMessage: String?

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Background Service", value: statusModel.daemonServiceState.rawValue)
                LabeledContent("Connection", value: statusModel.isDaemonReachable ? "Reachable" : "Not Reachable")
                LabeledContent("Backup", value: statusModel.state.rawValue)
                LabeledContent("Verify", value: statusModel.verifyState.rawValue)
            }

            Section("Errors") {
                if errors.isEmpty {
                    Text("No Errors")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(errors, id: \.label) { error in
                        LabeledContent(error.label) {
                            Text(error.message)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                pathRow("Config", path: settingsModel.configURL.path)
                pathRow("Service Log", path: daemonOutLogPath)
                pathRow("Service Error Log", path: daemonErrLogPath)
            } header: {
                Text("Files")
            } footer: {
                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                Button("Run Verify", systemImage: "checkmark.shield") {
                    statusModel.runVerify()
                }
                .disabled(statusModel.verifyState == .running || statusModel.isLifecycleBusy || statusModel.daemonServiceState != .running)
                .help("Check stored backups against their checksums")

                Button("Copy Summary", systemImage: "doc.on.doc") {
                    copyDiagnosticsSummary()
                }
                .help("Copy a diagnostics summary to the clipboard")

                Button("Export Bundle", systemImage: "square.and.arrow.up") {
                    exportDiagnosticsBundle()
                }
                .help("Save a diagnostics bundle with redacted config and recent logs")
            }
        }
    }

    private var errors: [(label: String, message: String)] {
        [
            ("Last Backup", statusModel.lastError),
            ("Last Verify", statusModel.lastVerifyError),
            ("Last Restore", statusModel.lastRestoreError),
        ].compactMap { label, message in
            guard let message, !message.isEmpty else {
                return nil
            }
            return (label, message)
        }
    }

    private func pathRow(_ label: String, path: String) -> some View {
        LabeledContent(label) {
            Text(path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
        }
    }

    private var daemonOutLogPath: String {
        BaxterRuntime.daemonOutLogURL.path
    }

    private var daemonErrLogPath: String {
        BaxterRuntime.daemonErrLogURL.path
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

        let outputDir = BaxterRuntime.diagnosticsURL

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
