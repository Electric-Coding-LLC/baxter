import AppKit
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
    @Published var lastError: String?
    @Published var isDaemonReachable: Bool = true

    private let baseURL = URL(string: "http://127.0.0.1:41820")!
    private var timer: Timer?
    private let iso8601 = ISO8601DateFormatter()

    init() {
        startPolling()
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
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/status"))
                request.httpMethod = "GET"

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw IPCError.badResponse
                }

                let status = try JSONDecoder().decode(DaemonStatus.self, from: data)
                apply(status)
                isDaemonReachable = true
            } catch {
                state = .failed
                lastError = "IPC unavailable: \(error.localizedDescription)"
                isDaemonReachable = false
            }
        }
    }

    func runBackup() {
        Task {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/backup/run"))
                request.httpMethod = "POST"

                let (_, response) = try await URLSession.shared.data(for: request)
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
                throw IPCError.badStatus(http.statusCode)
            } catch {
                state = .failed
                lastError = "run failed: \(error.localizedDescription)"
            }
        }
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
        }
        lastError = status.lastError
    }
}

private struct DaemonStatus: Decodable {
    let state: String
    let lastBackupAt: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case state
        case lastBackupAt = "last_backup_at"
        case lastError = "last_error"
    }
}

private enum IPCError: Error {
    case badResponse
    case badStatus(Int)
}

@main
struct BaxterMenuBarApp: App {
    @StateObject private var model = BackupStatusModel()
    @StateObject private var settingsModel = BaxterSettingsModel()

    var body: some Scene {
        MenuBarExtra("Baxter", systemImage: iconName) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Status: \(model.state.rawValue)")

                if let lastBackupAt = model.lastBackupAt {
                    Text("Last Backup: \(lastBackupAt.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Last Backup: never")
                }

                if let lastError = model.lastError {
                    Text("Error: \(lastError)")
                        .foregroundStyle(.red)
                }

                if !model.isDaemonReachable {
                    Text("Daemon is not reachable.")
                    Text("Check: launchctl print gui/$(id -u)/com.electriccoding.baxterd")
                        .font(.caption)
                    Text("Install/start: ./scripts/install-launchd.sh")
                        .font(.caption)
                }
            }
            .padding(.bottom, 6)

            Button("Run Backup") {
                model.runBackup()
            }
            .disabled(model.state == .running)

            Divider()

            Button("Refresh") {
                model.refreshStatus()
            }

            Divider()

            SettingsLink {
                Text("Open Settings")
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            BaxterSettingsView(model: settingsModel)
        }
    }

    private var iconName: String {
        model.state == .running ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive"
    }
}
