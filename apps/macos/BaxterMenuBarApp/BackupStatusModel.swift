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
