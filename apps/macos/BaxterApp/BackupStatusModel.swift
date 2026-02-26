import AppKit
import Darwin
import Foundation
import SwiftUI

@MainActor
final class BackupStatusModel: ObservableObject {
    static let latestSnapshotSelection = "latest"

    enum State: String {
        case idle = "Idle"
        case running = "Running"
        case failed = "Failed"
    }

    enum VerifyState: String {
        case idle = "Idle"
        case running = "Running"
        case failed = "Failed"
    }

    enum ConnectionState: Equatable {
        case connected
        case connecting
        case delayed
        case unavailable
        case stopped
        case unknown
    }

    enum LifecycleAction {
        case none
        case starting
        case stopping
        case applyingConfig
    }

    @Published var state: State = .idle
    @Published var verifyState: VerifyState = .idle
    @Published var lastBackupAt: Date?
    @Published var nextScheduledAt: Date?
    @Published var lastError: String?
    @Published var lastVerifyAt: Date?
    @Published var nextVerifyAt: Date?
    @Published var lastVerifyError: String?
    @Published var lastVerifyChecked: Int = 0
    @Published var lastVerifyOK: Int = 0
    @Published var lastVerifyMissing: Int = 0
    @Published var lastVerifyReadErrors: Int = 0
    @Published var lastVerifyDecryptErrors: Int = 0
    @Published var lastVerifyChecksumErrors: Int = 0
    @Published var isDaemonReachable: Bool = true
    @Published var daemonServiceState: DaemonServiceState = .unknown
    @Published private(set) var connectionState: ConnectionState = .unknown
    @Published var lifecycleMessage: String?
    @Published var isLifecycleBusy: Bool = false
    @Published private(set) var activeLifecycleAction: LifecycleAction = .none
    @Published private(set) var nextAutomaticRefreshAt: Date?
    @Published var restorePaths: [String] = []
    @Published var restorePreviewMessage: String?
    @Published var isRestoreBusy: Bool = false
    @Published var lastRestoreAt: Date?
    @Published var lastRestorePath: String?
    @Published var lastRestoreError: String?
    @Published var snapshots: [SnapshotSummary] = []
    @Published var selectedSnapshot: String = latestSnapshotSelection
    @Published var isSnapshotsBusy: Bool = false
    @Published var snapshotsMessage: String?
    @Published var notifyOnSuccess: Bool = false {
        didSet {
            notificationSettings.notifyOnSuccess = notifyOnSuccess
        }
    }

    private let baseURL: URL
    private let urlSession: URLSession
    private let ipcToken: String?
    private let queryLaunchdState: () async -> DaemonServiceState
    private let startLaunchd: () async throws -> String
    private let stopLaunchd: () async throws -> String
    private let hasConfigFile: () -> Bool
    private let nowProvider: () -> Date
    private let notificationSettings: NotificationSettingsStore
    private let notificationDispatcher: NotificationDispatching
    private var timer: Timer?
    private let iso8601 = ISO8601DateFormatter()
    private var shouldAutoBootstrapDaemon: Bool
    private var hasAttemptedAutoBootstrapDaemon: Bool = false
    private var suppressAutoRecoveryUntilManualStart: Bool = false
    private var lastAutoRecoveryAttemptAt: Date?
    private let autoRecoveryCooldown: TimeInterval = 15
    private let pollingInterval: TimeInterval = 5
    private let ipcConnectingGracePeriod: TimeInterval = 12
    private let ipcUnavailableEscalationPeriod: TimeInterval = 30
    private var ipcUnavailableSince: Date?

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:41820")!,
        urlSession: URLSession = .shared,
        ipcToken: String? = ProcessInfo.processInfo.environment["BAXTER_IPC_TOKEN"],
        queryLaunchdState: @escaping () async -> DaemonServiceState = { await LaunchdController.queryState() },
        startLaunchd: @escaping () async throws -> String = { try await LaunchdController.start() },
        stopLaunchd: @escaping () async throws -> String = { try await LaunchdController.stop() },
        hasConfigFile: @escaping () -> Bool = { LaunchdController.hasConfigFile() },
        nowProvider: @escaping () -> Date = Date.init,
        notificationSettings: NotificationSettingsStore = .shared,
        notificationDispatcher: NotificationDispatching = NoopNotificationDispatcher(),
        autoStartPolling: Bool = true
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.ipcToken = ipcToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.queryLaunchdState = queryLaunchdState
        self.startLaunchd = startLaunchd
        self.stopLaunchd = stopLaunchd
        self.hasConfigFile = hasConfigFile
        self.nowProvider = nowProvider
        self.notificationSettings = notificationSettings
        self.notificationDispatcher = notificationDispatcher
        self.notifyOnSuccess = notificationSettings.notifyOnSuccess
        self.shouldAutoBootstrapDaemon = autoStartPolling
        self.notificationDispatcher.requestAuthorizationIfNeeded()
        if autoStartPolling {
            startPolling()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func startPolling() {
        shouldAutoBootstrapDaemon = true
        scheduleNextAutomaticRefresh()
        refreshStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleNextAutomaticRefresh()
                self?.refreshStatus()
            }
        }
    }

    func refreshStatus() {
        if timer != nil {
            scheduleNextAutomaticRefresh()
        }
        Task {
            var launchdState = await queryLaunchdState()
            var attemptedStartThisRefresh = false
            if shouldAutoBootstrapDaemon &&
                !hasAttemptedAutoBootstrapDaemon &&
                launchdState != .running &&
                hasConfigFile()
            {
                attemptedStartThisRefresh = true
                hasAttemptedAutoBootstrapDaemon = true
                do {
                    lifecycleMessage = try await startLaunchd()
                    launchdState = await queryLaunchdState()
                    suppressAutoRecoveryUntilManualStart = false
                } catch {
                    lifecycleMessage = "Auto-start failed: \(error.localizedDescription)"
                }
            }

            if shouldAutoBootstrapDaemon &&
                !attemptedStartThisRefresh &&
                !suppressAutoRecoveryUntilManualStart &&
                launchdState == .stopped &&
                hasConfigFile() &&
                shouldAttemptAutoRecovery()
            {
                attemptedStartThisRefresh = true
                lastAutoRecoveryAttemptAt = Date()
                do {
                    lifecycleMessage = "Daemon stopped; attempting restart..."
                    lifecycleMessage = try await startLaunchd()
                    launchdState = await queryLaunchdState()
                    suppressAutoRecoveryUntilManualStart = false
                } catch {
                    lifecycleMessage = "Auto-restart failed: \(error.localizedDescription)"
                }
            }

            daemonServiceState = launchdState
            clearStaleLifecycleMessageIfNeeded(for: launchdState)
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/status"))
                request.httpMethod = "GET"
                applyIPCAuthHeader(to: &request)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw IPCError.badResponse
                }

                let status = try JSONDecoder().decode(DaemonStatus.self, from: data)
                apply(status)
                isDaemonReachable = true
                ipcUnavailableSince = nil
                connectionState = .connected
            } catch {
                let now = nowProvider()
                if launchdState == .stopped {
                    state = .idle
                    lastError = nil
                    connectionState = .stopped
                    ipcUnavailableSince = nil
                } else if launchdState == .unknown {
                    state = .idle
                    lastError = nil
                    connectionState = .unknown
                    ipcUnavailableSince = nil
                } else {
                    state = .idle
                    lastError = nil
                    updateConnectionStateForIPCFailure(now: now)
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
                applyIPCAuthHeader(to: &request)

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

    func runVerify() {
        Task {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/verify/run"))
                request.httpMethod = "POST"
                applyIPCAuthHeader(to: &request)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                if http.statusCode == 202 {
                    refreshStatus()
                    return
                }
                if http.statusCode == 409 {
                    verifyState = .running
                    lastVerifyError = nil
                    return
                }
                throw decodeDaemonError(data: data, statusCode: http.statusCode)
            } catch {
                verifyState = .failed
                lastVerifyError = "verify failed: \(error.localizedDescription)"
            }
        }
    }

    func startDaemon() {
        Task {
            activeLifecycleAction = .starting
            isLifecycleBusy = true
            defer {
                isLifecycleBusy = false
                activeLifecycleAction = .none
            }
            do {
                lifecycleMessage = try await startLaunchd()
                suppressAutoRecoveryUntilManualStart = false
                lastError = nil
                connectionState = .connecting
                ipcUnavailableSince = nowProvider()
                refreshStatus()
            } catch {
                lifecycleMessage = "Start failed: \(error.localizedDescription)"
            }
        }
    }

    func stopDaemon() {
        Task {
            activeLifecycleAction = .stopping
            isLifecycleBusy = true
            defer {
                isLifecycleBusy = false
                activeLifecycleAction = .none
            }
            do {
                lifecycleMessage = try await stopLaunchd()
                suppressAutoRecoveryUntilManualStart = true
                lastError = nil
                connectionState = .stopped
                ipcUnavailableSince = nil
                refreshStatus()
            } catch {
                lifecycleMessage = "Stop failed: \(error.localizedDescription)"
            }
        }
    }

    func applyConfigNow() {
        Task {
            activeLifecycleAction = .applyingConfig
            isLifecycleBusy = true
            defer {
                isLifecycleBusy = false
                activeLifecycleAction = .none
            }
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/config/reload"))
                request.httpMethod = "POST"
                applyIPCAuthHeader(to: &request)

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
                    lifecycleMessage = try await startLaunchd()
                    lastError = nil
                    connectionState = .connecting
                    ipcUnavailableSince = nowProvider()
                    refreshStatus()
                } catch {
                    lifecycleMessage = "Apply failed: \(error.localizedDescription)"
                }
            } catch {
                lifecycleMessage = "Apply failed: \(error.localizedDescription)"
            }
        }
    }

    func secondsUntilNextAutoRefresh(now: Date = Date()) -> Int? {
        guard let nextAutomaticRefreshAt else {
            return nil
        }
        let remaining = nextAutomaticRefreshAt.timeIntervalSince(now)
        return max(0, Int(ceil(remaining)))
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
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                applyIPCAuthHeader(to: &request)
                let (data, response) = try await urlSession.data(for: request)
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

    func fetchSnapshots(limit: Int = 50) {
        Task {
            isSnapshotsBusy = true
            defer { isSnapshotsBusy = false }

            do {
                var components = URLComponents(url: baseURL.appendingPathComponent("v1/snapshots"), resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "limit", value: String(max(limit, 0)))]
                guard let url = components?.url else {
                    throw IPCError.badResponse
                }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                applyIPCAuthHeader(to: &request)

                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw IPCError.badResponse
                }
                guard http.statusCode == 200 else {
                    throw decodeDaemonError(data: data, statusCode: http.statusCode)
                }

                let decoded = try JSONDecoder().decode(SnapshotsPayload.self, from: data)
                snapshots = decoded.snapshots
                if selectedSnapshot != Self.latestSnapshotSelection &&
                    !decoded.snapshots.contains(where: { $0.id == selectedSnapshot }) {
                    selectedSnapshot = Self.latestSnapshotSelection
                }
                snapshotsMessage = decoded.snapshots.isEmpty
                    ? "No snapshots found. Use latest."
                    : "Loaded \(decoded.snapshots.count) snapshot(s)."
            } catch {
                snapshotsMessage = "Snapshot load failed: \(error.localizedDescription)"
            }
        }
    }

    var selectedSnapshotRequestValue: String {
        selectedSnapshot == Self.latestSnapshotSelection ? "" : selectedSnapshot
    }

    var selectedSnapshotSummary: SnapshotSummary? {
        snapshots.first(where: { $0.id == selectedSnapshot })
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
                applyIPCAuthHeader(to: &request)
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
                applyIPCAuthHeader(to: &request)
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
            let guidance = restoreErrorGuidance(for: code)
            if let guidance {
                return "\(prefix) failed [\(code)]: \(guidance)"
            }
            return "\(prefix) failed [\(code)]: \(message)"
        }
        return "\(prefix) failed: \(error.localizedDescription)"
    }

    private func restoreErrorGuidance(for code: String) -> String? {
        switch code {
        case "manifest_load_failed":
            return "Could not load the selected snapshot. Refresh snapshots and try again."
        case "path_lookup_failed":
            return "The requested path was not found in the selected snapshot."
        case "invalid_restore_target":
            return "The destination path is invalid or escapes the selected destination root."
        case "target_exists":
            return "The destination file already exists. Enable overwrite or choose a different destination."
        case "restore_object_missing":
            return "Backup data for this path is missing. Try another snapshot or run a new backup."
        case "restore_storage_transient":
            return "Temporary storage error while reading backup data. Retry in a moment."
        case "restore_key_unavailable":
            return "Restore key is unavailable. Check BAXTER_PASSPHRASE or keychain settings."
        case "decrypt_failed":
            return "Could not decrypt backup data. Verify the configured encryption key."
        case "integrity_check_failed":
            return "Integrity verification failed for restored content. Retry from another snapshot."
        default:
            return nil
        }
    }

    private func decodeDaemonError(data: Data, statusCode: Int) -> IPCError {
        if let payload = try? JSONDecoder().decode(DaemonErrorPayload.self, from: data) {
            return IPCError.server(code: payload.code, message: payload.message, statusCode: statusCode)
        }
        return IPCError.badStatus(statusCode)
    }

    private func applyIPCAuthHeader(to request: inout URLRequest) {
        guard let token = ipcToken, !token.isEmpty else {
            return
        }
        request.setValue(token, forHTTPHeaderField: "X-Baxter-Token")
    }

    private func apply(_ status: DaemonStatus) {
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

    private func shouldAttemptAutoRecovery(now: Date = Date()) -> Bool {
        guard let lastAutoRecoveryAttemptAt else {
            return true
        }
        return now.timeIntervalSince(lastAutoRecoveryAttemptAt) >= autoRecoveryCooldown
    }

    private func scheduleNextAutomaticRefresh(now: Date = Date()) {
        nextAutomaticRefreshAt = now.addingTimeInterval(pollingInterval)
    }

    private func updateConnectionStateForIPCFailure(now: Date) {
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

    private func clearStaleLifecycleMessageIfNeeded(for launchdState: DaemonServiceState) {
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

    private func dispatchStatusTransitionNotifications(
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
