# macOS App

Menu bar UI for Baxter. Target: macOS Tahoe 26.2+.

## Notes
- The UI will communicate with the daemon via a local IPC channel (TBD).
- A small settings window will manage backup roots, schedule, and S3 settings.

## Next Steps
- Create an Xcode project targeting macOS 26.2 and add `BaxterMenuBarApp.swift`.
- Add a settings window and connect UI actions to the daemon.
