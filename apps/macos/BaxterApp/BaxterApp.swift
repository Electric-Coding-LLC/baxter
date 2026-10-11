import AppKit
import SwiftUI

@main
struct BaxterApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = BackupStatusModel(notificationDispatcher: UNUserNotificationDispatcher())
    @StateObject private var settingsModel = BaxterSettingsModel()
    @StateObject private var workspaceRouter = BaxterWorkspaceRouter()
    @StateObject private var workspaceWindowCoordinator = BaxterWorkspaceWindowCoordinator()

    var body: some Scene {
        MenuBarExtra(BaxterRuntime.applicationName, systemImage: iconName) {
            BaxterMenuContentView(model: model, openWorkspace: openWorkspace)
        }
        .menuBarExtraStyle(.menu)

        Window(BaxterRuntime.applicationName, id: "workspace") {
            BaxterWorkspaceView(
                statusModel: model,
                settingsModel: settingsModel,
                router: workspaceRouter,
                windowCoordinator: workspaceWindowCoordinator
            )
        }

        Settings {
            BaxterSettingsView(
                model: settingsModel,
                statusModel: model,
                onRecoveryConnected: { openWorkspace(section: .restore) }
            )
        }
    }

    private var iconName: String {
        if model.state == .running {
            return "arrow.triangle.2.circlepath.circle.fill"
        }
        if model.state == .failed || model.backupOverdue {
            return "exclamationmark.triangle.fill"
        }
        return "externaldrive"
    }

    private func openWorkspace(section: BaxterWorkspaceSection) {
        workspaceRouter.selectedSection = section
        openWindow(id: "workspace")
        workspaceWindowCoordinator.requestPresentation()
    }
}
