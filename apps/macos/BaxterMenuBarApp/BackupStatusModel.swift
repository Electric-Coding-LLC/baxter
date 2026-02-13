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

    enum VerifyState: String {
        case idle = "Idle"
        case running = "Running"
        case failed = "Failed"
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
    private let ipcToken: String?
    private var timer: Timer?
    private let iso8601 = ISO8601DateFormatter()

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:41820")!,
        urlSession: URLSession = .shared,
        ipcToken: String? = ProcessInfo.processInfo.environment["BAXTER_IPC_TOKEN"],
        autoStartPolling: Bool = true
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.ipcToken = ipcToken?.trimmingCharacters(in: .whitespacesAndNewlines)
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
                applyIPCAuthHeader(to: &request)

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

    private func applyIPCAuthHeader(to request: inout URLRequest) {
        guard let token = ipcToken, !token.isEmpty else {
            return
        }
        request.setValue(token, forHTTPHeaderField: "X-Baxter-Token")
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
    }
}
