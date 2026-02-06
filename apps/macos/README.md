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
- The app includes a settings window (via `Open Settings`) that edits `~/Library/Application Support/baxter/config.toml`.

## Next Steps
- Open the project in Xcode:
- `open apps/macos/BaxterMenuBarApp.xcodeproj`
- Build from terminal:
- `xcodebuild -project apps/macos/BaxterMenuBarApp.xcodeproj -scheme BaxterMenuBarApp -configuration Debug build`
- Add daemon lifecycle integration (start/stop) from the app.
- Add folder picker UX for backup roots and validation hints for S3 fields.
