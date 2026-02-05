# macOS App

Menu bar UI for Baxter. Target: macOS Tahoe 26.2+.

## Notes
- The UI communicates with the daemon over local HTTP IPC at `http://127.0.0.1:41820`.
- Implemented endpoints:
- `GET /v1/status`
- `POST /v1/backup/run`
- Recommended local daemon setup uses launchd via:
- `./scripts/install-launchd.sh`
- Operational smoke check:
- `./scripts/smoke-launchd-ipc.sh`
- A small settings window will manage backup roots, schedule, and S3 settings.

## Next Steps
- Create an Xcode project targeting macOS 26.2 and add `BaxterMenuBarApp.swift`.
- Add daemon lifecycle integration (start/stop) from the app.
- Add a settings window and connect UI actions to the daemon.
