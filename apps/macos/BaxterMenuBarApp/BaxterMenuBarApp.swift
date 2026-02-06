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
    @Published var nextScheduledAt: Date?
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
        } else {
            lastBackupAt = nil
        }
        if let raw = status.nextScheduledAt {
            nextScheduledAt = iso8601.date(from: raw)
        } else {
            nextScheduledAt = nil
        }
        lastError = status.lastError
    }
}

private struct DaemonStatus: Decodable {
    let state: String
    let lastBackupAt: String?
    let nextScheduledAt: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case state
        case lastBackupAt = "last_backup_at"
        case nextScheduledAt = "next_scheduled_at"
        case lastError = "last_error"
    }
}

private enum IPCError: Error {
    case badResponse
    case badStatus(Int)
}

@main
struct BaxterMenuBarApp: App {
    @Environment(\.openSettings) private var openSettings
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
                        Text("Check: launchctl print gui/$(id -u)/com.electriccoding.baxterd")
                            .font(.caption)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                Divider()

                Button {
                    model.runBackup()
                } label: {
                    Label("Run Backup", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.state == .running)

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
                        openSettings()
                        DispatchQueue.main.async {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                    } label: {
                        Label("Settings", systemImage: "gearshape")
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
            .padding(14)
            .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Settings {
            BaxterSettingsView(model: settingsModel)
        }
    }

    private var iconName: String {
        model.state == .running ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive"
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
}
