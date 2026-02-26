import AppKit
import SwiftUI

@main
struct BaxterApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = BackupStatusModel(notificationDispatcher: UNUserNotificationDispatcher())
    @StateObject private var settingsModel = BaxterSettingsModel()
    @StateObject private var workspaceRouter = BaxterWorkspaceRouter()

    var body: some Scene {
        MenuBarExtra("Baxter", systemImage: iconName) {
            BaxterMenuContentView(model: model, openWorkspace: openWorkspace)
                .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Window("Baxter", id: "workspace") {
            BaxterWorkspaceView(
                statusModel: model,
                settingsModel: settingsModel,
                router: workspaceRouter
            )
        }
    }

    private var iconName: String {
        model.state == .running ? "arrow.triangle.2.circlepath.circle.fill" : "externaldrive"
    }

    private func openWorkspace(section: BaxterWorkspaceSection) {
        workspaceRouter.selectedSection = section
        closeMenuBarPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            openWindow(id: "workspace")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func closeMenuBarPanel() {
        if let keyWindow = NSApplication.shared.keyWindow, isMenuBarPanelWindow(keyWindow) {
            keyWindow.orderOut(nil)
        }
        _ = NSApplication.shared.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
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
