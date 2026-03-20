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
    @Published var connectionState: ConnectionState = .unknown
    @Published var lifecycleMessage: String?
    @Published var isLifecycleBusy: Bool = false
    @Published var activeLifecycleAction: LifecycleAction = .none
    @Published var nextAutomaticRefreshAt: Date?
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
    @Published var recoveryMessage: String?
    @Published var isRecoveryBusy: Bool = false
    @Published var notifyOnSuccess: Bool = false {
        didSet {
            notificationSettings.notifyOnSuccess = notifyOnSuccess
        }
    }

    let baseURL: URL
    let urlSession: URLSession
    let ipcToken: String?
    let queryLaunchdState: () async -> DaemonServiceState
    let startLaunchd: () async throws -> String
    let stopLaunchd: () async throws -> String
    let storePassphraseInKeychain: (String, String, String) async throws -> Void
    let runRecoveryBootstrap: (String) async throws -> String
    let hasConfigFile: () -> Bool
    let nowProvider: () -> Date
    let notificationSettings: NotificationSettingsStore
    let notificationDispatcher: NotificationDispatching
    var timer: Timer?
    let iso8601 = ISO8601DateFormatter()
    var shouldAutoBootstrapDaemon: Bool
    var hasAttemptedAutoBootstrapDaemon: Bool = false
    var suppressAutoRecoveryUntilManualStart: Bool = false
    var lastAutoRecoveryAttemptAt: Date?
    let autoRecoveryCooldown: TimeInterval = 15
    let pollingInterval: TimeInterval = 5
    let ipcConnectingGracePeriod: TimeInterval = 12
    let ipcUnavailableEscalationPeriod: TimeInterval = 30
    var ipcUnavailableSince: Date?

    init(
        baseURL: URL = BaxterRuntime.daemonBaseURL,
        urlSession: URLSession = .shared,
        ipcToken: String? = ProcessInfo.processInfo.environment["BAXTER_IPC_TOKEN"],
        queryLaunchdState: @escaping () async -> DaemonServiceState = { await LaunchdController.queryState() },
        startLaunchd: @escaping () async throws -> String = { try await LaunchdController.start() },
        stopLaunchd: @escaping () async throws -> String = { try await LaunchdController.stop() },
        storePassphraseInKeychain: @escaping (String, String, String) async throws -> Void = { passphrase, service, account in
            try await KeychainPassphraseStore.store(passphrase: passphrase, service: service, account: account)
        },
        runRecoveryBootstrap: @escaping (String) async throws -> String = { passphrase in
            try await LaunchdController.runRecoveryBootstrap(passphrase: passphrase)
        },
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
        self.storePassphraseInKeychain = storePassphraseInKeychain
        self.runRecoveryBootstrap = runRecoveryBootstrap
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
                !suppressAutoRecoveryUntilManualStart &&
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
            if launchdState == .stopped {
                state = .idle
                lastError = nil
                connectionState = .stopped
                ipcUnavailableSince = nil
                isDaemonReachable = false
                return
            }
            if launchdState == .unknown {
                state = .idle
                lastError = nil
                connectionState = .unknown
                ipcUnavailableSince = nil
                isDaemonReachable = false
                return
            }
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
                state = .idle
                lastError = nil
                updateConnectionStateForIPCFailure(now: now)
                isDaemonReachable = false
            }
        }
    }
}
