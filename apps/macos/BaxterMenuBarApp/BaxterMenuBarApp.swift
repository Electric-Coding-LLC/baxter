import AppKit
import SwiftUI

final class BackupStatusModel: ObservableObject {
    enum State: String {
        case idle = "Idle"
        case running = "Running"
        case failed = "Failed"
    }

    @Published var state: State = .idle
    @Published var lastBackupAt: Date?
    @Published var lastError: String?

    func runBackup() {
        state = .running
        lastError = nil

        // Temporary simulation until daemon IPC is wired.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.state = .idle
            self.lastBackupAt = Date()
        }
    }
}

@main
struct BaxterMenuBarApp: App {
    @StateObject private var model = BackupStatusModel()

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
            }
            .padding(.bottom, 6)

            Button("Run Backup") {
                model.runBackup()
            }
            .disabled(model.state == .running)

            Divider()

            Button("Open Settings") {
                // TODO: open settings window.
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        model.state == .running ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive"
    }
}
