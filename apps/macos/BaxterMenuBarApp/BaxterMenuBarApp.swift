import SwiftUI

@main
struct BaxterMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("Baxter", systemImage: "externaldrive") {
            Button("Run Backup") {
                // TODO: trigger daemon backup.
            }

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
}
