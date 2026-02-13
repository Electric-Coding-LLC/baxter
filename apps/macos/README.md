# macOS App

Menu bar UI for Baxter. Target: macOS Tahoe 26.2+.

## Notes
- The UI communicates with the daemon over local HTTP IPC at `http://127.0.0.1:41820`.
- Implemented endpoints:
- `GET /v1/status`
- `POST /v1/backup/run`
- `POST /v1/verify/run`
- `GET /v1/snapshots`
- `GET /v1/restore/list`
- `POST /v1/restore/dry-run`
- If `BAXTER_IPC_TOKEN` is set in the app environment, requests include `X-Baxter-Token`.
- The menu includes daemon lifecycle controls (`Start Daemon`, `Stop Daemon`) using launchd (`com.electriccoding.baxterd`).
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
- Run tests from terminal:
- `xcodebuild -project apps/macos/BaxterMenuBarApp.xcodeproj -scheme BaxterMenuBarApp -destination 'platform=macOS' test`
- Validate Settings flow:
- verify folder picker for backup roots
- verify schedule fields (`daily_time`, `weekly_day`, `weekly_time`) save to config
- verify `[verify]` fields (`schedule`, `daily_time`, `weekly_day`, `weekly_time`, `prefix`, `limit`, `sample`) save to config
- verify inline validation prevents invalid time formats
