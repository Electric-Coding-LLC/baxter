import AppKit
import SwiftUI

struct BaxterMenuContentView: View {
    @ObservedObject var model: BackupStatusModel
    let openWorkspace: (BaxterWorkspaceSection) -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let status = BaxterMenuStatus(model: model)

        ForEach(status.statusLines, id: \.self) { line in
            Text(line)
        }

        if !status.warnings.isEmpty {
            Divider()
            ForEach(status.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
            }
        }

        Divider()

        Button("Back Up Now") {
            model.runBackup()
        }
        .disabled(!status.canRunBackup)

        if let reason = status.runBackupDisabledReason {
            Text(reason)
        }

        Button("Restore Files…") {
            openWorkspace(.restore)
        }

        Divider()

        Button("Settings…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                openSettings()
            }
        }
        .keyboardShortcut(",", modifiers: [.command])

        Button("Diagnostics…") {
            openWorkspace(.diagnostics)
        }

        Menu("Background Service") {
            Button(status.startTitle) {
                model.startDaemon()
            }
            .disabled(!status.canStartDaemon)

            Button(status.stopTitle) {
                model.stopDaemon()
            }
            .disabled(!status.canStopDaemon)

            Button("Restart Baxter") {
                model.startDaemon()
            }
            .disabled(!status.canRestartDaemon)

            Divider()

            Button("Refresh Status") {
                model.refreshStatus()
            }
        }

        Divider()

        Button("Quit \(BaxterRuntime.applicationName)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
