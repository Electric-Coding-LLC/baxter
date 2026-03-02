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
- If `BAXTER_IPC_TOKEN` is set in the app environment, requests include `X-Baxter-Token` (required when daemon IPC token auth is enabled; use one currently accepted token during rotation windows).
- The menu includes daemon lifecycle controls (`Start Daemon`, `Stop Daemon`) using launchd (`com.electriccoding.baxterd`).
- `Start Daemon` now auto-installs the LaunchAgent/binary when missing (requires an existing config file and local repo build context).
- On startup, the menu app auto-starts the daemon once when config exists and launchd reports the service is not running.
- Recommended local daemon setup uses launchd via:
- `./scripts/install-launchd.sh`
- Optional: set `BAXTER_IPC_TOKEN` before install to start the daemon with IPC token auth.
- Operational smoke check:
- `./scripts/smoke-launchd-ipc.sh`
- If IPC token auth is enabled, set `BAXTER_IPC_TOKEN` before running the smoke check.
- The app includes a workspace window with dedicated `Restore`, `Settings`, and `Diagnostics` sections.
- Menu actions (`Restore...`, `Settings...`, `Diagnostics...`) deep-link into the matching workspace section.
- The Settings section edits `~/Library/Application Support/baxter/config.toml` and includes a first-run setup card with backup root selection, schedule, storage mode validation, and a `Run First Backup Now` entry point.

## Next Steps
- Open the project in Xcode:
- `open apps/macos/BaxterApp.xcodeproj`
- Build from terminal:
- `xcodebuild -project apps/macos/BaxterApp.xcodeproj -scheme BaxterApp -configuration Debug build`
- Run tests from terminal:
- `xcodebuild -project apps/macos/BaxterApp.xcodeproj -scheme BaxterApp -destination 'platform=macOS' test`
- Swift style tooling:
- `brew bundle --file Brewfile --no-upgrade`
- Optional refresh to latest versions:
- `brew bundle --file Brewfile --upgrade`
- `./scripts/swift-style.sh lint-check`
- `./scripts/swift-style.sh format-check`
- `./scripts/swift-style.sh format-apply`
- Fast local checks (changed files only):
- `./scripts/swift-style.sh lint-check --changed`
- `./scripts/swift-style.sh format-check --changed`
- `./scripts/swift-style.sh format-apply --changed`
- Validate Settings flow:
- verify folder picker for backup roots
- verify schedule fields (`daily_time`, `weekly_day`, `weekly_time`) save to config
- verify `[verify]` fields (`schedule`, `daily_time`, `weekly_day`, `weekly_time`, `prefix`, `limit`, `sample`) save to config
- verify inline validation prevents invalid time formats
- Validate Restore workspace flow:
- verify snapshot selector + searchable tree can pick a source path without manual typing
- verify dry-run/run actions preserve daemon error codes in inline messaging
