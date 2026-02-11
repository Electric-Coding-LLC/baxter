import AppKit
import Darwin
import Foundation
import SwiftUI

@MainActor
final class BackupStatusModel: ObservableObject {
    enum State: String {
        case idle = "Idle"
        case running = "Running"
        case failed = "Failed"
    }

    @Published var state: State = .idle
    @Published var lastBackupAt: Date?
    @Published var nextScheduledAt: Date?
    @Published var lastError: String?
    @Published var isDaemonReachable: Bool = true
    @Published var daemonServiceState: DaemonServiceState = .unknown
    @Published var lifecycleMessage: String?
    @Published var isLifecycleBusy: Bool = false
    @Published var restorePaths: [String] = []
    @Published var restorePreviewMessage: String?
    @Published var isRestoreBusy: Bool = false
    @Published var lastRestoreAt: Date?
    @Published var lastRestorePath: String?
    @Published var lastRestoreError: String?

    private let baseURL: URL
    private let urlSession: URLSession
    private var timer: Timer?
    private let iso8601 = ISO8601DateFormatter()

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:41820")!,
        urlSession: URLSession = .shared,
        autoStartPolling: Bool = true
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        if autoStartPolling {
            startPolling()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func startPolling() {
        refreshStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
    }

    func refreshStatus() {
        Task {
            daemonServiceState = await LaunchdController.queryState()
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/status"))
                request.httpMethod = "GET"

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw IPCError.badResponse
                }

                let status = try JSONDecoder().decode(DaemonStatus.self, from: data)
                apply(status)
                isDaemonReachable = true
            } catch {
                if daemonServiceState == .stopped {
                    state = .idle
                    lastError = nil
                } else {
                    state = .failed
                    lastError = "IPC unavailable: \(error.localizedDescription)"
                }
                isDaemonReachable = false
            }
        }
    }

    func runBackup() {
        Task {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/backup/run"))
                request.httpMethod = "POST"

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                if http.statusCode == 202 {
                    refreshStatus()
                    return
                }
                if http.statusCode == 409 {
                    state = .running
                    lastError = nil
                    return
                }
                throw decodeDaemonError(data: data, statusCode: http.statusCode)
            } catch {
                state = .failed
                lastError = "run failed: \(error.localizedDescription)"
            }
        }
    }

    func startDaemon() {
        Task {
            isLifecycleBusy = true
            defer { isLifecycleBusy = false }
            do {
                lifecycleMessage = try await LaunchdController.start()
                lastError = nil
                refreshStatus()
            } catch {
                lifecycleMessage = "Start failed: \(error.localizedDescription)"
            }
        }
    }

    func stopDaemon() {
        Task {
            isLifecycleBusy = true
            defer { isLifecycleBusy = false }
            do {
                lifecycleMessage = try await LaunchdController.stop()
                lastError = nil
                refreshStatus()
            } catch {
                lifecycleMessage = "Stop failed: \(error.localizedDescription)"
            }
        }
    }

    func applyConfigNow() {
        Task {
            isLifecycleBusy = true
            defer { isLifecycleBusy = false }
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/config/reload"))
                request.httpMethod = "POST"

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                if http.statusCode == 200 {
                    lifecycleMessage = "Config reloaded."
                    lastError = nil
                    refreshStatus()
                    return
                }
                if http.statusCode == 404 || http.statusCode == 405 {
                    throw IPCError.reloadUnavailable
                }
                throw decodeDaemonError(data: data, statusCode: http.statusCode)
            } catch IPCError.reloadUnavailable {
                do {
                    lifecycleMessage = "Reload unavailable; restarting daemon..."
                    lifecycleMessage = try await LaunchdController.start()
                    lastError = nil
                    refreshStatus()
                } catch {
                    lifecycleMessage = "Apply failed: \(error.localizedDescription)"
                }
            } catch {
                lifecycleMessage = "Apply failed: \(error.localizedDescription)"
            }
        }
    }

    func fetchRestoreList(prefix: String, contains: String, snapshot: String) {
        Task {
            isRestoreBusy = true
            defer { isRestoreBusy = false }
            do {
                var components = URLComponents(url: baseURL.appendingPathComponent("v1/restore/list"), resolvingAgainstBaseURL: false)
                var queryItems: [URLQueryItem] = []
                let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPrefix.isEmpty {
                    queryItems.append(URLQueryItem(name: "prefix", value: trimmedPrefix))
                }
                let trimmedContains = contains.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedContains.isEmpty {
                    queryItems.append(URLQueryItem(name: "contains", value: trimmedContains))
                }
                let trimmedSnapshot = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedSnapshot.isEmpty {
                    queryItems.append(URLQueryItem(name: "snapshot", value: trimmedSnapshot))
                }
                components?.queryItems = queryItems.isEmpty ? nil : queryItems

                guard let url = components?.url else {
                    throw IPCError.badResponse
                }
                let (data, response) = try await urlSession.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                guard http.statusCode == 200 else {
                    throw decodeDaemonError(data: data, statusCode: http.statusCode)
                }
                let decoded = try JSONDecoder().decode(RestoreListPayload.self, from: data)
                restorePaths = decoded.paths
                restorePreviewMessage = "Found \(decoded.paths.count) path(s)."
            } catch {
                restorePreviewMessage = "Restore list failed: \(error.localizedDescription)"
            }
        }
    }

    func previewRestore(path: String, toDir: String, overwrite: Bool, snapshot: String) {
        Task {
            isRestoreBusy = true
            defer { isRestoreBusy = false }

            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPath.isEmpty {
                restorePreviewMessage = "Enter a restore path."
                return
            }

            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/restore/dry-run"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let payload = RestoreActionRequest(
                    path: trimmedPath,
                    toDir: toDir.trimmingCharacters(in: .whitespacesAndNewlines),
                    overwrite: overwrite,
                    snapshot: snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                request.httpBody = try JSONEncoder().encode(payload)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                guard http.statusCode == 200 else {
                    throw decodeDaemonError(data: data, statusCode: http.statusCode)
                }
                let decoded = try JSONDecoder().decode(RestoreDryRunPayload.self, from: data)
                restorePreviewMessage = "Dry-run: source=\(decoded.sourcePath) target=\(decoded.targetPath) overwrite=\(decoded.overwrite)"
            } catch {
                restorePreviewMessage = formatRestoreError(prefix: "Restore dry-run", error: error)
            }
        }
    }

    func runRestore(path: String, toDir: String, overwrite: Bool, verifyOnly: Bool, snapshot: String) {
        Task {
            isRestoreBusy = true
            defer { isRestoreBusy = false }

            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPath.isEmpty {
                restorePreviewMessage = "Enter a restore path."
                return
            }

            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/restore/run"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let payload = RestoreActionRequest(
                    path: trimmedPath,
                    toDir: toDir.trimmingCharacters(in: .whitespacesAndNewlines),
                    overwrite: overwrite,
                    verifyOnly: verifyOnly,
                    snapshot: snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                request.httpBody = try JSONEncoder().encode(payload)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                guard http.statusCode == 200 else {
                    throw decodeDaemonError(data: data, statusCode: http.statusCode)
                }
                let decoded = try JSONDecoder().decode(RestoreRunPayload.self, from: data)
                if decoded.wrote {
                    restorePreviewMessage = "Restore complete: source=\(decoded.sourcePath) target=\(decoded.targetPath)"
                } else if decoded.verified {
                    restorePreviewMessage = "Restore verify-only complete: source=\(decoded.sourcePath) target=\(decoded.targetPath)"
                } else {
                    restorePreviewMessage = "Restore response received for source=\(decoded.sourcePath)"
                }
                refreshStatus()
            } catch {
                restorePreviewMessage = formatRestoreError(prefix: "Restore", error: error)
            }
        }
    }

    private func formatRestoreError(prefix: String, error: Error) -> String {
        if case IPCError.server(let code, let message, _) = error {
            return "\(prefix) failed [\(code)]: \(message)"
        }
        return "\(prefix) failed: \(error.localizedDescription)"
    }

    private func decodeDaemonError(data: Data, statusCode: Int) -> IPCError {
        if let payload = try? JSONDecoder().decode(DaemonErrorPayload.self, from: data) {
            return IPCError.server(code: payload.code, message: payload.message, statusCode: statusCode)
        }
        return IPCError.badStatus(statusCode)
    }

    private func apply(_ status: DaemonStatus) {
        switch status.state.lowercased() {
        case "running":
            state = .running
        case "failed":
            state = .failed
        default:
            state = .idle
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
        if let raw = status.lastRestoreAt {
            lastRestoreAt = iso8601.date(from: raw)
        } else {
            lastRestoreAt = nil
        }
        lastRestorePath = status.lastRestorePath
        lastRestoreError = status.lastRestoreError
        lastError = status.lastError
    }
}

private struct DaemonStatus: Decodable {
    let state: String
    let lastBackupAt: String?
    let nextScheduledAt: String?
    let lastError: String?
    let lastRestoreAt: String?
    let lastRestorePath: String?
    let lastRestoreError: String?

    enum CodingKeys: String, CodingKey {
        case state
        case lastBackupAt = "last_backup_at"
        case nextScheduledAt = "next_scheduled_at"
        case lastError = "last_error"
        case lastRestoreAt = "last_restore_at"
        case lastRestorePath = "last_restore_path"
        case lastRestoreError = "last_restore_error"
    }
}

private struct RestoreListPayload: Decodable {
    let paths: [String]
}

private struct RestoreActionRequest: Encodable {
    let path: String
    let toDir: String?
    let overwrite: Bool
    let verifyOnly: Bool?
    let snapshot: String?

    enum CodingKeys: String, CodingKey {
        case path
        case toDir = "to_dir"
        case overwrite
        case verifyOnly = "verify_only"
        case snapshot
    }

    init(path: String, toDir: String, overwrite: Bool, verifyOnly: Bool? = nil, snapshot: String) {
        self.path = path
        self.toDir = toDir.isEmpty ? nil : toDir
        self.overwrite = overwrite
        self.verifyOnly = verifyOnly
        self.snapshot = snapshot.isEmpty ? nil : snapshot
    }
}

private struct RestoreDryRunPayload: Decodable {
    let sourcePath: String
    let targetPath: String
    let overwrite: Bool

    enum CodingKeys: String, CodingKey {
        case sourcePath = "source_path"
        case targetPath = "target_path"
        case overwrite
    }
}

private struct RestoreRunPayload: Decodable {
    let sourcePath: String
    let targetPath: String
    let verified: Bool
    let wrote: Bool

    enum CodingKeys: String, CodingKey {
        case sourcePath = "source_path"
        case targetPath = "target_path"
        case verified
        case wrote
    }
}

private struct DaemonErrorPayload: Decodable {
    let code: String
    let message: String
}

private enum IPCError: Error {
	case badResponse
	case badStatus(Int)
	case server(code: String, message: String, statusCode: Int)
	case reloadUnavailable
}

extension IPCError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Unexpected daemon response."
        case .badStatus(let statusCode):
            return "Daemon returned HTTP \(statusCode)."
        case .server(_, let message, _):
            return message
        case .reloadUnavailable:
            return "Reload endpoint unavailable."
        }
    }
}

enum DaemonServiceState: String {
    case running = "Running"
    case stopped = "Stopped"
    case unknown = "Unknown"
}

private enum LaunchdController {
    private static let label = "com.electriccoding.baxterd"

    private static var uid: UInt32 { getuid() }

    private static var domainTarget: String { "gui/\(uid)" }

    private static var serviceTarget: String { "\(domainTarget)/\(label)" }

    private static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(label).plist")
            .path
    }

    static func queryState() async -> DaemonServiceState {
        do {
            let result = try await runLaunchctlAllowFailure(["print", serviceTarget])
            return result.status == 0 ? .running : .stopped
        } catch {
            return .unknown
        }
    }

    static func start() async throws -> String {
        guard FileManager.default.fileExists(atPath: plistPath) else {
            throw LaunchdError.missingPlist(plistPath)
        }

        let state = await queryState()
        if state == .running {
            _ = try await runLaunchctl(["kickstart", "-k", serviceTarget])
            return "Daemon restarted."
        }

        _ = try await runLaunchctl(["bootstrap", domainTarget, plistPath])
        _ = try await runLaunchctl(["enable", serviceTarget])
        _ = try await runLaunchctl(["kickstart", "-k", serviceTarget])
        return "Daemon started."
    }

    static func stop() async throws -> String {
        do {
            _ = try await runLaunchctl(["bootout", serviceTarget])
            return "Daemon stopped."
        } catch {
            let state = await queryState()
            if state == .stopped {
                return "Daemon already stopped."
            }
            throw error
        }
    }

    private static func runLaunchctl(_ arguments: [String]) async throws -> CommandResult {
        try await runProcess(executable: "/bin/launchctl", arguments: arguments)
    }

    private static func runLaunchctlAllowFailure(_ arguments: [String]) async throws -> CommandResult {
        try await runProcessAllowFailure(executable: "/bin/launchctl", arguments: arguments)
    }

    private static func runProcess(executable: String, arguments: [String]) async throws -> CommandResult {
        let result = try await runProcessAllowFailure(executable: executable, arguments: arguments)
        if result.status != 0 {
            throw LaunchdError.commandFailed(command: executable, arguments: arguments, stderr: result.stderr)
        }
        return result
    }

    private static func runProcessAllowFailure(executable: String, arguments: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw LaunchdError.executionFailed(error.localizedDescription)
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outputData, encoding: .utf8) ?? ""
            let stderr = String(data: errorData, encoding: .utf8) ?? ""
            let status = process.terminationStatus
            return CommandResult(status: status, stdout: stdout, stderr: stderr)
        }.value
    }
}

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private enum LaunchdError: LocalizedError {
    case missingPlist(String)
    case executionFailed(String)
    case commandFailed(command: String, arguments: [String], stderr: String)

    var errorDescription: String? {
        switch self {
        case .missingPlist(let path):
            return "LaunchAgent plist not found at \(path). Run scripts/install-launchd.sh once."
        case .executionFailed(let reason):
            return "Failed to execute launchctl: \(reason)"
        case .commandFailed(_, let arguments, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "launchctl \(arguments.joined(separator: " ")) failed."
            }
            return detail
        }
    }
}

@main
struct BaxterMenuBarApp: App {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = BackupStatusModel()
    @StateObject private var settingsModel = BaxterSettingsModel()

    var body: some Scene {
        MenuBarExtra("Baxter", systemImage: iconName) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(model.state.rawValue, systemImage: statusSymbol)
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(statusTint.opacity(0.18), in: Capsule())
                    Label("Daemon \(model.daemonServiceState.rawValue)", systemImage: daemonStateSymbol)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(daemonStateTint.opacity(0.18), in: Capsule())
                    Spacer()
                    Text("Baxter")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
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

                if let lastError = model.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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
}
