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
                .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Window(BaxterRuntime.applicationName, id: "workspace") {
            BaxterWorkspaceView(
                statusModel: model,
                settingsModel: settingsModel,
                router: workspaceRouter,
                windowCoordinator: workspaceWindowCoordinator
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
        closeMenuBarPanel()
        openWindow(id: "workspace")
        workspaceWindowCoordinator.requestPresentation()
    }

    private func closeMenuBarPanel() {
        if let keyWindow = NSApplication.shared.keyWindow, isMenuBarPanelWindow(keyWindow) {
            keyWindow.orderOut(nil)
        }
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
}
