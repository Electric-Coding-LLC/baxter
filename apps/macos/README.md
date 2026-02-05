# macOS App

Menu bar UI for Baxter. Target: macOS Tahoe 26.2+.

## Notes
- The UI will communicate with the daemon via a local IPC channel (TBD).
- The current app shows a backup status view and a stubbed "Run Backup" action.
- A small settings window will manage backup roots, schedule, and S3 settings.

## Next Steps
- Create an Xcode project targeting macOS 26.2 and add `BaxterMenuBarApp.swift`.
- Replace the simulated run flow with daemon IPC calls.
- Add a settings window and connect UI actions to the daemon.
